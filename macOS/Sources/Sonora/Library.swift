import Foundation
import AppKit

@MainActor
final class Library: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""

    private var tracks: [String: Track] = [:]
    private var folders: [String] = []
    private var artwork: [String: String] = [:]          // albumKey -> archivo en caché
    private let imageCache = NSCache<NSString, NSImage>()

    private struct Store: Codable {
        var folders: [String]
        var tracks: [Track]
        var artwork: [String: String]
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
        tracks = tracks.filter { FileManager.default.fileExists(atPath: $0.key) }
        rebuild()
        scan(folders.map { URL(fileURLWithPath: $0) })
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
        tracks = Dictionary(store.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rebuild()
    }

    private func save() {
        let store = Store(folders: folders, tracks: Array(tracks.values), artwork: artwork)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
