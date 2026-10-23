import Foundation
import AVFoundation

struct Scanned {
    var track: Track
    var artwork: Data?
    var folderCover: URL?
}

struct Tags {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var track: Int?
    var disc: Int?
    var year: String?
    var artwork: Data?
}

enum Scanner {
    static let extensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "alac", "mp3", "aac", "caf", "mp4"]

    static func audioFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if extensions.contains(f.pathExtension.lowercased()) { out.append(f) }
                }
            } else if extensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    static func readBatch(_ urls: [URL]) async -> [Scanned] {
        await withTaskGroup(of: Scanned?.self) { group in
            for u in urls { group.addTask { await readOne(u) } }
            var out: [Scanned] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    static func readOne(_ url: URL) async -> Scanned? {
        let ext = url.pathExtension.lowercased()
        var tags = Tags()
        var sampleRate = 0.0, bits = 0, channels = 0, duration = 0.0

        if ext == "flac", let info = FLACReader.read(url) {
            tags = info.tags
            sampleRate = info.sampleRate
            bits = info.bitsPerSample
            channels = info.channels
            if info.sampleRate > 0 { duration = Double(info.totalSamples) / info.sampleRate }
        } else {
            tags = await AVTags.read(url)
        }

        if sampleRate == 0 || duration == 0, let f = try? AVAudioFile(forReading: url) {
            sampleRate = f.fileFormat.sampleRate
            channels = Int(f.fileFormat.channelCount)
            duration = Double(f.length) / sampleRate
            if bits == 0 { bits = bitDepth(of: f.fileFormat) }
        }
        guard sampleRate > 0 else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        let track = Track(
            path: url.path,
            title: tags.title ?? fileName,
            artist: tags.artist ?? "Artista desconocido",
            album: tags.album ?? folder.lastPathComponent,
            albumArtist: tags.albumArtist,
            trackNumber: tags.track ?? leadingNumber(fileName) ?? 0,
            discNumber: tags.disc ?? 1,
            year: tags.year,
            duration: duration,
            sampleRate: sampleRate,
            bitDepth: bits,
            channels: channels,
            format: ext == "m4a" && bits > 0 ? "alac" : ext
        )
        return Scanned(track: track, artwork: tags.artwork, folderCover: tags.artwork == nil ? findCover(in: folder) : nil)
    }

    static func bitDepth(of format: AVAudioFormat) -> Int {
        if let b = format.settings[AVLinearPCMBitDepthKey] as? Int, b > 0 { return b }
        let asbd = format.streamDescription.pointee
        if asbd.mFormatID == kAudioFormatAppleLossless {
            switch asbd.mFormatFlags { case 1: return 16; case 2: return 20; case 3: return 24; case 4: return 32; default: return 0 }
        }
        return Int(asbd.mBitsPerChannel)
    }

    static func findCover(in folder: URL) -> URL? {
        let names = ["cover", "folder", "front", "album", "artwork"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let images = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        return images.first { names.contains($0.deletingPathExtension().lastPathComponent.lowercased()) } ?? images.first
    }

    static func leadingNumber(_ s: String) -> Int? {
        Int(s.prefix(while: { $0.isNumber }))
    }

    static func parseNumber(_ s: String?) -> Int? {
        guard let s else { return nil }
        return Int(s.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "")
    }
}

// MARK: - FLAC (lectura directa de STREAMINFO, VORBIS_COMMENT y PICTURE)

struct FLACInfo {
    var sampleRate = 0.0
    var channels = 0
    var bitsPerSample = 0
    var totalSamples: UInt64 = 0
    var tags = Tags()
}

enum FLACReader {
    static func read(_ url: URL) -> FLACInfo? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard var magic = try? fh.read(upToCount: 4), magic.count == 4 else { return nil }

        // Saltar ID3v2 si existe
        if magic.starts(with: [0x49, 0x44, 0x33]) {
            guard let rest = try? fh.read(upToCount: 6), rest.count == 6 else { return nil }
            let b = [UInt8](rest)
            let size = (Int(b[2]) << 21) | (Int(b[3]) << 14) | (Int(b[4]) << 7) | Int(b[5])
            try? fh.seek(toOffset: UInt64(10 + size))
            guard let m = try? fh.read(upToCount: 4) else { return nil }
            magic = m
        }
        guard [UInt8](magic) == [0x66, 0x4C, 0x61, 0x43] else { return nil }

        var info = FLACInfo()
        var pictures: [(type: UInt32, data: Data)] = []
        var last = false
        while !last {
            guard let h = try? fh.read(upToCount: 4), h.count == 4 else { break }
            let hb = [UInt8](h)
            last = hb[0] & 0x80 != 0
            let type = hb[0] & 0x7F
            let length = (Int(hb[1]) << 16) | (Int(hb[2]) << 8) | Int(hb[3])
            switch type {
            case 0, 4, 6:
                guard let d = try? fh.read(upToCount: length), d.count == length else { last = true; break }
                let bytes = [UInt8](d)
                if type == 0 { parseStreamInfo(bytes, into: &info) }
                else if type == 4 { parseVorbis(bytes, into: &info.tags) }
                else if let p = parsePicture(bytes) { pictures.append(p) }
            default:
                guard let off = try? fh.offset() else { last = true; break }
                try? fh.seek(toOffset: off + UInt64(length))
            }
        }
        info.tags.artwork = (pictures.first { $0.type == 3 } ?? pictures.first)?.data
        return info
    }

    private static func parseStreamInfo(_ b: [UInt8], into info: inout FLACInfo) {
        guard b.count >= 18 else { return }
        let sr = (Int(b[10]) << 12) | (Int(b[11]) << 4) | (Int(b[12]) >> 4)
        info.sampleRate = Double(sr)
        info.channels = Int((b[12] >> 1) & 0x07) + 1
        info.bitsPerSample = Int(((b[12] & 0x01) << 4) | (b[13] >> 4)) + 1
        info.totalSamples = (UInt64(b[13] & 0x0F) << 32) | (UInt64(b[14]) << 24) | (UInt64(b[15]) << 16) | (UInt64(b[16]) << 8) | UInt64(b[17])
    }

    private static func parseVorbis(_ b: [UInt8], into tags: inout Tags) {
        var r = ByteReader(bytes: b)
        guard let vendorLen = r.u32le(), r.skip(Int(vendorLen)), let count = r.u32le() else { return }
        for _ in 0..<count {
            guard let len = r.u32le(), let raw = r.take(Int(len)),
                  let s = String(bytes: raw, encoding: .utf8), let eq = s.firstIndex(of: "=") else { break }
            let key = s[..<eq].uppercased()
            let value = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = tags.albumArtist ?? value
            case "TRACKNUMBER": tags.track = Scanner.parseNumber(value)
            case "DISCNUMBER": tags.disc = Scanner.parseNumber(value)
            case "DATE", "YEAR": tags.year = tags.year ?? String(value.prefix(4))
            default: break
            }
        }
    }

    private static func parsePicture(_ b: [UInt8]) -> (type: UInt32, data: Data)? {
        var r = ByteReader(bytes: b)
        guard let type = r.u32be(),
              let mimeLen = r.u32be(), r.skip(Int(mimeLen)),
              let descLen = r.u32be(), r.skip(Int(descLen)),
              r.skip(16),
              let dataLen = r.u32be(), let data = r.take(Int(dataLen)) else { return nil }
        return (type, Data(data))
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0

    mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, pos + n <= bytes.count else { return nil }
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }
    mutating func skip(_ n: Int) -> Bool { take(n) != nil }
    mutating func u32le() -> UInt32? {
        guard let s = take(4) else { return nil }
        return s.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
    mutating func u32be() -> UInt32? {
        guard let s = take(4) else { return nil }
        return s.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - Otros formatos (AVFoundation)

enum AVTags {
    static func read(_ url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = meta + common

        func string(_ ids: [AVMetadataIdentifier]) async -> String? {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { return s }
                }
            }
            return nil
        }
        func data(_ ids: [AVMetadataIdentifier]) async -> Data? {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
                }
            }
            return nil
        }
        func pairNumber(_ id: AVMetadataIdentifier) async -> Int? {
            guard let d = await data([id]), d.count >= 4 else { return nil }
            let b = [UInt8](d)
            let n = (Int(b[2]) << 8) | Int(b[3])
            return n > 0 ? n : nil
        }

        var t = Tags()
        t.title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        t.artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        t.album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        t.albumArtist = await string([.iTunesMetadataAlbumArtist, .id3MetadataBand])
        t.year = await string([.commonIdentifierCreationDate, .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate]).map { String($0.prefix(4)) }
        if let n = Scanner.parseNumber(await string([.id3MetadataTrackNumber])) { t.track = n }
        else { t.track = await pairNumber(.iTunesMetadataTrackNumber) }
        if let n = Scanner.parseNumber(await string([.id3MetadataPartOfASet])) { t.disc = n }
        else { t.disc = await pairNumber(.iTunesMetadataDiscNumber) }
        t.artwork = await data([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt])
        return t
    }
}
