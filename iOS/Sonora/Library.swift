import Foundation
import UIKit

struct LinkedFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bookmark: Data
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var folders: [LinkedFolder] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var oneDriveFolder: OneDriveFolder?
    @Published var lastError: String?

    private var tracks: [String: Track] = [:]
    private var artwork: [String: String] = [:]          // albumKey -> archivo en caché
    private var accessing: [String: URL] = [:]
    private let imageCache = NSCache<NSString, UIImage>()

    private struct Store: Codable {
        var tracks: [Track]
        var artwork: [String: String]
        var folders: [LinkedFolder]?
        var oneDriveFolder: OneDriveFolder?
    }

    private static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        return base
    }()
    private static var storeURL: URL { supportDir.appendingPathComponent("library.json") }
    private static var artworkDir: URL { supportDir.appendingPathComponent("Artwork", isDirectory: true) }

    init() {
        load()
        refresh()
    }

    // MARK: Carpetas en la nube (vinculadas, sin copiar)

    /// Vincula carpetas de OneDrive, iCloud Drive, etc. Solo se lee la lista de archivos.
    func link(_ urls: [URL]) {
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            let f = LinkedFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmark: data)
            folders.append(f)
            accessing[f.id] = url
            SourceRegistry.shared.set(url, for: f.id)
        }
        save()
        refresh()
    }

    func unlink(_ folder: LinkedFolder) {
        folders.removeAll { $0.id == folder.id }
        tracks = tracks.filter { $0.value.source != folder.id }
        accessing[folder.id]?.stopAccessingSecurityScopedResource()
        accessing[folder.id] = nil
        SourceRegistry.shared.set(nil, for: folder.id)
        rebuild()
        save()
    }

    private func openFolders() {
        for (i, f) in folders.enumerated() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: f.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                folders[i].bookmark = fresh
            }
            accessing[f.id] = url
            SourceRegistry.shared.set(url, for: f.id)
        }
    }

    /// Al reproducir por primera vez una canción de la nube: lee sus etiquetas (título, calidad, carátula).
    func readTags(_ t: Track) async -> Track? {
        guard t.isCloud, !t.tagsRead else { return nil }
        guard let r = await Scanner.readOne(t.url, relativePath: t.path) else { return nil }
        var updated = r.track
        updated.source = t.source
        updated.groupKey = t.groupKey
        updated.format = t.format
        // Si el archivo no trae etiquetas, conserva lo que ya sabíamos (carpetas / OneDrive)
        if r.track.title == t.url.deletingPathExtension().lastPathComponent { updated.title = t.title }
        if r.track.artist == "Artista desconocido" { updated.artist = t.artist }
        if r.track.album == t.url.deletingLastPathComponent().lastPathComponent { updated.album = t.album }
        if r.track.trackNumber == 0 { updated.trackNumber = t.trackNumber }
        if r.track.year == nil { updated.year = t.year }
        tracks[updated.id] = updated
        if artwork[updated.albumKey] == nil, let data = r.artwork { storeArtwork(data, key: updated.albumKey) }
        rebuild()
        save()
        return updated
    }

    // MARK: OneDrive (streaming)

    func useOneDrive(_ folder: OneDriveFolder) {
        oneDriveFolder = folder
        tracks = tracks.filter { !$0.value.isOneDrive }
        rebuild()
        save()
        refreshOneDrive()
    }

    func removeOneDrive() {
        oneDriveFolder = nil
        tracks = tracks.filter { !$0.value.isOneDrive }
        OneDriveCache.clear()
        rebuild()
        save()
    }

    /// Recorre la carpeta de música de OneDrive (solo la lista, no descarga canciones).
    func refreshOneDrive() {
        guard let root = oneDriveFolder, OneDrive.shared.isSignedIn, !isBusy else { return }
        isBusy = true
        status = "Leyendo OneDrive…"
        Task {
            var found: [String: Track] = [:]
            var covers: [String: URL] = [:]
            var pending: [(id: String, path: [String])] = [(root.id, [])]
            var foldersRead = 0
            do {
                while !pending.isEmpty {
                    let (folderID, path) = pending.removeFirst()
                    let items = try await OneDrive.shared.children(of: folderID)
                    foldersRead += 1
                    status = "Leyendo OneDrive… \(foldersRead) carpetas, \(found.count) canciones"
                    let groupKey = "od:" + folderID
                    var folderCover: URL?
                    var trackThumb: URL?

                    for item in items {
                        if item.folder != nil { pending.append((item.id, path + [item.name])); continue }
                        let ext = (item.name as NSString).pathExtension.lowercased()
                        if ["jpg", "jpeg", "png"].contains(ext) {
                            let base = (item.name as NSString).deletingPathExtension.lowercased()
                            if folderCover == nil || ["cover", "folder", "front"].contains(base) {
                                folderCover = item.downloadURL.flatMap(URL.init(string:))
                            }
                            continue
                        }
                        guard Scanner.extensions.contains(ext) else { continue }
                        let t = Self.track(from: item, ext: ext, path: path, groupKey: groupKey)
                        found[t.id] = tracks[t.id]?.tagsRead == true ? tracks[t.id]! : t
                        if trackThumb == nil { trackThumb = item.thumbnailURL }
                    }
                    if let c = folderCover ?? trackThumb, artwork[groupKey] == nil { covers[groupKey] = c }
                }
                tracks = tracks.filter { !$0.value.isOneDrive }.merging(found) { _, new in new }
                rebuild()

                var i = 0
                for (key, url) in covers {
                    i += 1
                    status = "Carátulas \(i) de \(covers.count)…"
                    if let (data, _) = try? await URLSession.shared.data(from: url) {
                        storeArtwork(data, key: key)
                        if i % 10 == 0 { rebuild() }
                    }
                }
                rebuild()
                save()
            } catch {
                lastError = error.localizedDescription
            }
            isBusy = false
            status = ""
        }
    }

    private static func track(from item: DriveItem, ext: String, path: [String], groupKey: String) -> Track {
        let base = (item.name as NSString).deletingPathExtension
        var title = String(base.drop(while: { $0.isNumber })).trimmingCharacters(in: CharacterSet(charactersIn: " .-_)"))
        if title.isEmpty { title = base }
        var album = path.last ?? "OneDrive"
        var artist = path.count >= 2 ? path[path.count - 2] : "Artista desconocido"
        if path.count < 2, let r = album.range(of: " - ") {
            artist = String(album[..<r.lowerBound])
            album = String(album[r.upperBound...])
        }
        let a = item.audio
        return Track(
            path: item.id,
            title: a?.title ?? title,
            artist: a?.artist ?? a?.albumArtist ?? artist,
            album: a?.album ?? album,
            albumArtist: a?.albumArtist,
            trackNumber: a?.track ?? Scanner.leadingNumber(base) ?? 0,
            discNumber: a?.disc ?? 1,
            year: a?.year.map { String($0) },
            duration: Double(a?.duration ?? 0) / 1000,
            sampleRate: 0, bitDepth: 0, channels: 0,
            format: ext,
            source: Track.oneDrive,
            groupKey: groupKey
        )
    }

    // MARK: Copiar al iPhone (opcional)

    func importFrom(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        isBusy = true
        status = "Preparando…"
        Task {
            await Task.detached {
                Importer.copy(urls) { done, total in
                    Task { @MainActor in self.status = "Copiando \(done) de \(total)…" }
                }
            }.value
            isBusy = false
            refresh()
        }
    }

    // MARK: Actualizar

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        status = "Actualizando biblioteca…"
        Task {
            // 1. Carpeta local de la app
            let files = await Task.detached { Scanner.audioFiles(in: [MusicFolder.url]) }.value
            let localIDs = Set(files.map { MusicFolder.relativePath(of: $0) })
            tracks = tracks.filter { $0.value.isCloud || localIDs.contains($0.key) }

            // 2. Carpetas en la nube: solo la lista (rápido, sin descargar)
            var coversToFetch: [(String, URL)] = []
            for f in folders {
                guard let root = accessing[f.id] else { continue }
                let id = f.id
                let listing = await Task.detached { Scanner.listCloud(root: root, sourceID: id) }.value
                let present = Set(listing.tracks.map(\.id))
                tracks = tracks.filter { $0.value.source != id || present.contains($0.key) }
                for t in listing.tracks where tracks[t.id] == nil { tracks[t.id] = t }
                for (key, url) in listing.covers where artwork[key] == nil { coversToFetch.append((key, url)) }
            }
            rebuild()

            // 3. Leer etiquetas de archivos locales nuevos
            let newFiles = files.filter { tracks[MusicFolder.relativePath(of: $0)] == nil }
            var done = 0
            for start in stride(from: 0, to: newFiles.count, by: 8) {
                let batch = Array(newFiles[start..<min(start + 8, newFiles.count)])
                merge(await Scanner.readBatch(batch))
                done += batch.count
                status = "Leyendo \(done) de \(newFiles.count)…"
            }

            // 4. Carátulas de la nube (imágenes pequeñas)
            for (i, (key, url)) in coversToFetch.enumerated() {
                status = "Carátulas \(i + 1) de \(coversToFetch.count)…"
                if await CloudFiles.ensureLocal(url), let data = try? Data(contentsOf: url) {
                    storeArtwork(data, key: key)
                    if i % 10 == 9 { rebuild() }
                }
            }
            rebuild()
            save()
            isBusy = false
            status = ""
            if oneDriveFolder != nil && !tracks.values.contains(where: \.isOneDrive) { refreshOneDrive() }
        }
    }

    /// Elimina del iPhone los archivos de un álbum local (no toca la nube).
    func delete(_ album: Album) {
        guard !album.isCloud else { return }
        for t in album.tracks {
            try? FileManager.default.removeItem(at: t.url)
            tracks[t.id] = nil
        }
        if let folder = album.tracks.first?.url.deletingLastPathComponent(),
           folder.standardizedFileURL != MusicFolder.url.standardizedFileURL,
           let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           !rest.contains(where: { Scanner.extensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            try? FileManager.default.removeItem(at: folder)
        }
        rebuild()
        save()
    }

    func artworkImage(forKey key: String) -> UIImage? {
        guard let name = artwork[key] else { return nil }
        if let img = imageCache.object(forKey: name as NSString) { return img }
        guard let img = UIImage(contentsOfFile: Self.artworkDir.appendingPathComponent(name).path) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
        return img
    }

    // MARK: Interno

    private func storeArtwork(_ data: Data, key: String) {
        guard UIImage(data: data) != nil else { return }
        let name = stableHash(key) + ".img"
        try? data.write(to: Self.artworkDir.appendingPathComponent(name))
        imageCache.removeObject(forKey: name as NSString)
        artwork[key] = name
    }

    private func merge(_ results: [Scanned]) {
        for r in results {
            tracks[r.track.id] = r.track
            let key = r.track.albumKey
            guard artwork[key] == nil else { continue }
            if let data = r.artwork ?? r.folderCover.flatMap({ try? Data(contentsOf: $0) }) {
                storeArtwork(data, key: key)
            }
        }
        rebuild()
    }

    private func rebuild() {
        albums = Dictionary(grouping: tracks.values, by: \.albumKey)
            .map { key, ts in
                Album(id: key, tracks: ts.sorted {
                    ($0.discNumber, $0.trackNumber, $0.path) < ($1.discNumber, $1.trackNumber, $1.path)
                })
            }
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        artwork = store.artwork
        folders = store.folders ?? []
        oneDriveFolder = store.oneDriveFolder
        openFolders()
        tracks = Dictionary(store.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rebuild()
    }

    private func save() {
        let store = Store(tracks: Array(tracks.values), artwork: artwork, folders: folders, oneDriveFolder: oneDriveFolder)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}

// MARK: - Copia desde la app Archivos (descarga los archivos de iCloud/OneDrive si hace falta)

enum Importer {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func copy(_ roots: [URL], progress: @escaping (Int, Int) -> Void) {
        let fm = FileManager.default
        var jobs: [(source: URL, dest: URL)] = []
        var scoped: [URL] = []

        for root in roots {
            if root.startAccessingSecurityScopedResource() { scoped.append(root) }
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: root.path, isDirectory: &isDir)
            if isDir.boolValue {
                let destRoot = MusicFolder.url.appendingPathComponent(root.lastPathComponent, isDirectory: true)
                let rootComps = root.standardizedFileURL.pathComponents
                let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [])
                while let f = e?.nextObject() as? URL {
                    guard let real = realName(f), wanted(real) else { continue }
                    var rel = Array(real.standardizedFileURL.pathComponents.dropFirst(rootComps.count))
                    if rel.isEmpty { rel = [real.lastPathComponent] }
                    jobs.append((real, destRoot.appendingPathComponent(rel.joined(separator: "/"))))
                }
            } else if let real = realName(root), wanted(real) {
                jobs.append((real, MusicFolder.url.appendingPathComponent(real.lastPathComponent)))
            }
        }

        let coordinator = NSFileCoordinator()
        for (i, job) in jobs.enumerated() {
            progress(i + 1, jobs.count)
            guard !fm.fileExists(atPath: job.dest.path) else { continue }
            try? fm.createDirectory(at: job.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            var err: NSError?
            coordinator.coordinate(readingItemAt: job.source, options: [], error: &err) { readURL in
                try? fm.copyItem(at: readURL, to: job.dest)
            }
        }
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// Convierte ".cancion.flac.icloud" (archivo aún no descargado) en "cancion.flac".
    private static func realName(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let clean = String(name.dropFirst().dropLast(".icloud".count))
            return url.deletingLastPathComponent().appendingPathComponent(clean)
        }
        return name.hasPrefix(".") ? nil : url
    }

    private static func wanted(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Scanner.extensions.contains(ext) || imageExtensions.contains(ext)
    }
}
