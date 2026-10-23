import Foundation
import AppKit

@MainActor
final class Library: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published private(set) var oneDriveFolder: OneDriveFolder?
    @Published var lastError: String?
    /// Canciones de OneDrive descargadas al Mac.
    @Published private(set) var offline: Set<String> = []
    /// Progreso de descarga por álbum.
    @Published private(set) var downloads: [String: DownloadProgress] = [:]

    struct DownloadProgress: Equatable { var done: Int; var total: Int }

    private var tracks: [String: Track] = [:]
    private var folders: [String] = []
    private var artwork: [String: String] = [:]          // albumKey -> archivo en caché
    private let imageCache = NSCache<NSString, NSImage>()

    private struct Store: Codable {
        var folders: [String]
        var tracks: [Track]
        var artwork: [String: String]
        var oneDriveFolder: OneDriveFolder?
    }

    private static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sonora", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        return base
    }()
    private static var storeURL: URL { supportDir.appendingPathComponent("library.json") }
    private static var artworkDir: URL { supportDir.appendingPathComponent("Artwork", isDirectory: true) }

    init() { load() }

    // MARK: Acciones

    func add(urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
               !folders.contains(u.path) {
                folders.append(u.path)
            }
        }
        scan(urls)
    }

    func rescan() {
        tracks = tracks.filter { $0.value.isOneDrive || FileManager.default.fileExists(atPath: $0.value.path) }
        rebuild()
        scan(folders.map { URL(fileURLWithPath: $0) })
        if oneDriveFolder != nil { refreshOneDrive() }
    }

    func remove(_ album: Album) {
        for t in album.tracks { tracks[t.id] = nil }
        rebuild()
        save()
    }

    func artworkImage(forKey key: String) -> NSImage? {
        guard let name = artwork[key] else { return nil }
        if let img = imageCache.object(forKey: name as NSString) { return img }
        guard let img = NSImage(contentsOf: Self.artworkDir.appendingPathComponent(name)) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
        return img
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
        OneDriveCache.clearOffline()
        rebuild()
        save()
    }

    /// Recorre la carpeta de música de OneDrive (solo la lista; las canciones se descargan al escucharlas).
    func refreshOneDrive() {
        guard let root = oneDriveFolder, OneDrive.shared.isSignedIn, !isScanning else { return }
        isScanning = true
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
                    status = "OneDrive: \(foldersRead) carpetas, \(found.count) canciones"
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
                        let t = Self.track(from: item, ext: ext, path: path, groupKey: groupKey, root: root.name)
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
            isScanning = false
            status = ""
        }
    }

    private static func track(from item: DriveItem, ext: String, path: [String], groupKey: String, root: String) -> Track {
        let base = (item.name as NSString).deletingPathExtension
        var title = String(base.drop(while: { $0.isNumber })).trimmingCharacters(in: CharacterSet(charactersIn: " .-_)"))
        if title.isEmpty { title = base }
        var album = path.last ?? root
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

    /// Al terminar de bajar una canción de OneDrive: lee sus etiquetas (título, calidad, carátula).
    func readTags(_ t: Track) async -> Track? {
        guard t.isOneDrive, !t.tagsRead, let r = await Scanner.readOne(t.url) else { return nil }
        var u = r.track
        u.path = t.path
        u.source = t.source
        u.groupKey = t.groupKey
        u.format = t.format
        if r.track.title == t.url.deletingPathExtension().lastPathComponent { u.title = t.title }
        if r.track.artist == "Artista desconocido" { u.artist = t.artist }
        if r.track.album == t.url.deletingLastPathComponent().lastPathComponent { u.album = t.album }
        if r.track.trackNumber == 0 { u.trackNumber = t.trackNumber }
        if r.track.year == nil { u.year = t.year }
        tracks[u.id] = u
        if artwork[u.albumKey] == nil, let data = r.artwork { storeArtwork(data, key: u.albumKey) }
        rebuild()
        save()
        return u
    }

    // MARK: Descargar para escuchar sin internet

    func download(_ album: Album) {
        guard downloads[album.id] == nil else { return }
        let todo = album.tracks.filter { $0.isOneDrive && !offline.contains($0.id) }
        guard !todo.isEmpty else { return }
        downloads[album.id] = DownloadProgress(done: 0, total: todo.count)
        Task {
            var failed = 0
            for (i, t) in todo.enumerated() {
                if await OneDriveCache.makeOffline(t) { offline.insert(t.id) } else { failed += 1 }
                downloads[album.id] = DownloadProgress(done: i + 1, total: todo.count)
            }
            downloads[album.id] = nil
            if failed > 0 { lastError = "No se pudieron descargar \(failed) canciones. Revisa la conexión e inténtalo de nuevo." }
        }
    }

    func removeDownload(_ album: Album) {
        for t in album.tracks where t.isOneDrive {
            OneDriveCache.removeOffline(t)
            offline.remove(t.id)
        }
    }

    private func storeArtwork(_ data: Data, key: String) {
        guard NSImage(data: data) != nil else { return }
        let name = stableHash(key) + ".img"
        try? data.write(to: Self.artworkDir.appendingPathComponent(name))
        imageCache.removeObject(forKey: name as NSString)
        artwork[key] = name
    }

    // MARK: Escaneo

    private func scan(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isScanning = true
        status = "Buscando archivos…"
        Task {
            let files = await Task.detached { Scanner.audioFiles(in: urls) }.value
            let batchSize = 8
            var done = 0
            for start in stride(from: 0, to: files.count, by: batchSize) {
                let batch = Array(files[start..<min(start + batchSize, files.count)])
                let results = await Scanner.readBatch(batch)
                merge(results)
                done += batch.count
                status = "Leyendo \(done) de \(files.count)…"
            }
            save()
            isScanning = false
            status = ""
        }
    }

    private func merge(_ results: [Scanned]) {
        for r in results {
            tracks[r.track.id] = r.track
            let key = r.track.albumKey
            guard artwork[key] == nil else { continue }
            let data = r.artwork ?? r.folderCover.flatMap { try? Data(contentsOf: $0) }
            if let data, NSImage(data: data) != nil {
                let name = stableHash(key) + ".img"
                try? data.write(to: Self.artworkDir.appendingPathComponent(name))
                artwork[key] = name
            }
        }
        rebuild()
    }

    private func rebuild() {
        offline = Set(tracks.values.filter { $0.isOneDrive && OneDriveCache.isOffline($0) }.map(\.id))
        albums = Dictionary(grouping: tracks.values, by: \.albumKey)
            .map { key, ts in
                Album(id: key, tracks: ts.sorted {
                    ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title)
                })
            }
            .sorted { ($0.artist.lowercased(), $0.year ?? "", $0.title.lowercased()) < ($1.artist.lowercased(), $1.year ?? "", $1.title.lowercased()) }
    }

    // MARK: Persistencia

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        folders = store.folders
        artwork = store.artwork
        oneDriveFolder = store.oneDriveFolder
        tracks = Dictionary(store.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rebuild()
    }

    private func save() {
        let store = Store(folders: folders, tracks: Array(tracks.values), artwork: artwork, oneDriveFolder: oneDriveFolder)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
