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
    var source: String? = nil      // nil = archivo del Mac; "onedrive" = OneDrive (path = id del archivo)
    var groupKey: String? = nil    // en OneDrive el álbum se agrupa por carpeta

    var id: String { (source.map { $0 + ":" } ?? "") + path }
    var url: URL { isOneDrive ? OneDriveCache.url(itemID: path, ext: format) : URL(fileURLWithPath: path) }
    var albumKey: String { groupKey ?? ((albumArtist ?? artist) + "|" + album).lowercased() }
    var isOneDrive: Bool { source == Track.oneDrive }
    var tagsRead: Bool { sampleRate > 0 }
    static let oneDrive = "onedrive"
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
    var isOneDrive: Bool { tracks.first?.isOneDrive ?? false }
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
