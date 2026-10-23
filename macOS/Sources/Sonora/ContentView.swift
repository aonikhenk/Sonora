import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Theme {
    static let bg = Color(red: 0.075, green: 0.082, blue: 0.125)
    static let bar = Color(red: 0.058, green: 0.064, blue: 0.10)
    static let accent = Color(red: 0.49, green: 0.54, blue: 0.88)
    static let dim = Color.white.opacity(0.5)
    static let line = Color.white.opacity(0.07)
    static let width: CGFloat = 420
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ArtworkPanel()
            NowBar()
            if ui.showLibrary {
                LibraryView()
                    .frame(height: 380)
                    .transition(.opacity)
            }
        }
        .frame(width: Theme.width)
        .background(Theme.bg)
        .background(WindowAccessor { ui.window = $0 })
        .preferredColorScheme(.dark)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.black.opacity(0.55))
                    .overlay(Text("Suelta para agregar a la biblioteca").font(.system(size: 14, weight: .medium)))
                    .padding(6)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            let lib = library, state = ui
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        lib.add(urls: [url])
                        state.showLibrary = true
                    }
                }
            }
            return true
        }
        .onAppear {
            let lib = library
            player.artworkFor = { lib.artworkImage(forKey: $0.albumKey) }
        }
    }
}

// MARK: - Barra superior

struct HeaderBar: View {
    @EnvironmentObject var ui: UIState

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            Text("Sonora")
                .font(.custom("Snell Roundhand", size: 30).weight(.bold))
                .foregroundColor(.white)
                .padding(.trailing, 12)
            Button { ui.floating.toggle() } label: {
                Image(systemName: ui.floating ? "pin.fill" : "square.on.square")
                    .font(.system(size: 15))
                    .foregroundColor(ui.floating ? Theme.accent : .white.opacity(0.85))
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.07))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ui.floating ? "Dejar de mantener encima" : "Mantener siempre encima")
        }
        .frame(height: 52)
        .padding(.leading, 80)
    }
}

// MARK: - Carátula con controles al pasar el mouse

struct ArtworkPanel: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let t = player.current, let img = library.artworkImage(forKey: t.albumKey) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Placeholder()
            }
            if hovering && player.current != nil {
                ControlsOverlay().transition(.opacity)
            }
        }
        .frame(width: Theme.width, height: Theme.width)
        .clipped()
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovering = h } }
    }
}

struct Placeholder: View {
    @EnvironmentObject var library: Library

    var body: some View {
        ZStack {
            Theme.bar
            VStack(spacing: 14) {
                Image(systemName: "music.note").font(.system(size: 56, weight: .ultraLight))
                Text(library.albums.isEmpty ? "Arrastra aquí tu carpeta de música" : "Elige un álbum en la biblioteca")
                    .font(.system(size: 13))
            }
            .foregroundColor(Theme.dim)
        }
    }
}

struct ControlsOverlay: View {
    @EnvironmentObject var player: Player
    @State private var dragFraction: Double?

    var body: some View {
        VStack {
            HStack {
                if let t = player.current {
                    Text(t.qualityLabel + (player.nativeRate && player.outputRate > 0 ? "  →  DAC \(kHz(player.outputRate))" : ""))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
            }
            .padding(12)
            Spacer()
            VStack(spacing: 12) {
                progress
                HStack {
                    Text(formatTime(shownTime)).monospacedDigit()
                    Spacer()
                    HStack(spacing: 28) {
                        control("backward.fill", 18) { player.previous() }
                        control(player.isPlaying ? "pause.fill" : "play.fill", 26) { player.togglePlay() }
                        control("forward.fill", 18) { player.next() }
                    }
                    Spacer()
                    Text("-" + formatTime(player.duration - shownTime)).monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var fraction: Double {
        if let d = dragFraction { return d }
        return player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
    }
    private var shownTime: Double { fraction * player.duration }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 3)
                Capsule().fill(Color.white).frame(width: geo.size.width * fraction, height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragFraction = min(1, max(0, $0.location.x / geo.size.width)) }
                .onEnded { _ in
                    if let f = dragFraction { player.seek(to: f * player.duration) }
                    dragFraction = nil
                })
        }
        .frame(height: 14)
    }

    private func control(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundColor(.white)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kHz(_ r: Double) -> String {
        let k = r / 1000
        return (k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)) + " kHz"
    }
}

// MARK: - Barra inferior (símbolo musical abre la biblioteca)

struct NowBar: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState

    var body: some View {
        HStack(spacing: 10) {
            Button { ui.toggleLibrary() } label: {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(ui.showLibrary ? Theme.accent : .white)
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Biblioteca")

            Text(player.current?.displayTitle ?? "—")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.line).frame(width: 1, height: 24)
            Text("Siguiente:").italic().foregroundColor(Theme.accent)
            Text(player.nextTrack?.displayTitle ?? "—")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Theme.bar)
    }
}

// MARK: - Biblioteca

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            if let id = ui.selectedAlbumID, let album = library.albums.first(where: { $0.id == id }) {
                AlbumDetail(album: album)
            } else {
                AlbumList()
            }
        }
        .background(Theme.bg)
    }
}

struct AlbumList: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState
    @State private var search = ""

    private var filtered: [Album] {
        guard !search.isEmpty else { return library.albums }
        return library.albums.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.dim)
                TextField("Buscar álbum o artista", text: $search).textFieldStyle(.plain)
                if library.isScanning {
                    ProgressView().controlSize(.small)
                    Text(library.status).font(.system(size: 10)).foregroundColor(Theme.dim).lineLimit(1)
                }
                iconButton("plus", "Agregar carpeta") { ui.chooseFolders(into: library) }
                iconButton("arrow.clockwise", "Volver a escanear") { library.rescan() }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).frame(height: 40)

            if library.albums.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 30, weight: .light))
                    Text("Arrastra una carpeta con música sobre la ventana").font(.system(size: 12))
                }
                .foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { album in
                            AlbumRow(album: album, isCurrent: album.id == player.current?.albumKey)
                                .onTapGesture { ui.selectedAlbumID = album.id }
                                .contextMenu {
                                    Button("Reproducir") { player.play(album.tracks, startAt: 0) }
                                    Button("Mostrar en Finder") {
                                        if let t = album.tracks.first { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }
                                    }
                                    Divider()
                                    Button("Quitar de la biblioteca") { library.remove(album) }
                                }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundColor(.white.opacity(0.8)).help(help)
    }
}

struct AlbumRow: View {
    @EnvironmentObject var library: Library
    let album: Album
    let isCurrent: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Thumb(key: album.id, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundColor(isCurrent ? Theme.accent : .white)
                Text([album.artist, album.year].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            QualityBadge(label: album.qualityLabel, hiRes: album.isHiRes)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hover ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct AlbumDetail: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var ui: UIState
    let album: Album

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { ui.selectedAlbumID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium))
                        .frame(width: 24, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Thumb(key: album.id, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(album.artist).font(.system(size: 12)).foregroundColor(Theme.dim).lineLimit(1)
                    Text([album.year, "\(album.tracks.count) canciones", formatTime(album.totalDuration), album.qualityLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundColor(Theme.dim).lineLimit(1)
                }
                Spacer()
                Button { player.play(album.tracks, startAt: 0) } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, showDisc: album.hasMultipleDiscs, isCurrent: player.current?.id == t.id)
                            .onTapGesture { player.play(album.tracks, startAt: i) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct TrackRow: View {
    @EnvironmentObject var player: Player
    let track: Track
    let showDisc: Bool
    let isCurrent: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10)).foregroundColor(Theme.accent)
                } else if hover {
                    Image(systemName: "play.fill").font(.system(size: 10))
                } else {
                    Text(showDisc ? "\(track.discNumber)-\(String(format: "%02d", track.trackNumber))" : String(format: "%02d", track.trackNumber))
                        .foregroundColor(Theme.dim).monospacedDigit()
                }
            }
            .frame(width: 34, alignment: .trailing)
            Text(track.title).lineLimit(1)
                .foregroundColor(isCurrent ? Theme.accent : .white)
            Spacer()
            Text(formatTime(track.duration)).foregroundColor(Theme.dim).monospacedDigit()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).frame(height: 30)
        .background(hover ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct Thumb: View {
    @EnvironmentObject var library: Library
    let key: String
    let size: CGFloat

    var body: some View {
        Group {
            if let img = library.artworkImage(forKey: key) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.bar
                    Image(systemName: "music.note").foregroundColor(Theme.dim)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct QualityBadge: View {
    let label: String
    let hiRes: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(hiRes ? Theme.accent : Theme.dim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(hiRes ? Theme.accent : Theme.dim.opacity(0.5), lineWidth: 1))
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.backgroundColor = NSColor(Theme.bg)
                w.titlebarAppearsTransparent = true
                onWindow(w)
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
