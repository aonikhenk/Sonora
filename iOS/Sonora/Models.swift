import Foundation

struct Track: Codable, Identifiable, Hashable {
    var path: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var trackNumber: Int
    var discNumber: Int
    var year: String?
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var channels: Int
    var format: String
    var source: String? = nil      // nil = carpeta local de la app; si no, id de la carpeta vinculada (nube)
    var groupKey: String? = nil    // en la nube, el álbum se agrupa por carpeta

    var id: String { (source.map { $0 + ":" } ?? "") + path }
    var url: URL {
        if source == Track.oneDrive { return OneDriveCache.url(itemID: path, ext: format) }
        if let source, let base = SourceRegistry.shared.url(for: source) { return base.appendingPathComponent(path) }
        return MusicFolder.url.appendingPathComponent(path)
    }
    var albumKey: String { groupKey ?? ((albumArtist ?? artist) + "|" + album).lowercased() }
    var isCloud: Bool { source != nil }
    var isOneDrive: Bool { source == Track.oneDrive }
    static let oneDrive = "onedrive"
    var tagsRead: Bool { sampleRate > 0 }
    var isHiRes: Bool { bitDepth > 16 || sampleRate > 48000 }

    var displayTitle: String {
        trackNumber > 0 ? String(format: "%02d - %@", trackNumber, title) : title
    }

    var qualityLabel: String {
        guard sampleRate > 0 else { return format.uppercased() }
        let khz = sampleRate / 1000
        let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
        return bitDepth > 0 ? "\(format.uppercased()) \(bitDepth)/\(rate)" : "\(format.uppercased()) \(rate) kHz"
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let tracks: [Track]

    var title: String { tracks.first?.album ?? "" }
    var artist: String { tracks.first.map { $0.albumArtist ?? $0.artist } ?? "" }
    var year: String? { tracks.first(where: { $0.year != nil })?.year }
    var qualityLabel: String { (tracks.first(where: \.tagsRead) ?? tracks.first)?.qualityLabel ?? "" }
    var isHiRes: Bool { tracks.contains { $0.isHiRes } }
    var isCloud: Bool { tracks.first?.isCloud ?? false }
    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var hasMultipleDiscs: Bool { Set(tracks.map(\.discNumber)).count > 1 }
}

func formatTime(_ seconds: Double) -> String {
    let t = Int(max(0, seconds.isFinite ? seconds : 0))
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
        : String(format: "%d:%02d", t / 60, t % 60)
}

func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// Carpeta de música de la app (visible en la app Archivos como "Sonora").
enum MusicFolder {
    static var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func relativePath(of file: URL) -> String {
        let base = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let comps = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return comps.dropFirst(base.count).joined(separator: "/")
    }
}

/// Carpetas vinculadas (OneDrive, iCloud Drive…) por id. Seguro entre hilos.
final class SourceRegistry {
    static let shared = SourceRegistry()
    private var map: [String: URL] = [:]
    private let lock = NSLock()

    func url(for id: String) -> URL? { lock.lock(); defer { lock.unlock() }; return map[id] }
    func set(_ url: URL?, for id: String) { lock.lock(); map[id] = url; lock.unlock() }
}

/// Descarga (si hace falta) un archivo de la nube y espera a que esté disponible.
enum CloudFiles {
    static func ensureLocal(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                var err: NSError?
                var ok = false
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                    ok = FileManager.default.fileExists(atPath: u.path)
                }
                cont.resume(returning: ok)
            }
        }
    }
}
