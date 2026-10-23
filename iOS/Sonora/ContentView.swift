import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let bg = Color(red: 0.075, green: 0.082, blue: 0.125)
    static let bar = Color(red: 0.058, green: 0.064, blue: 0.10)
    static let accent = Color(red: 0.49, green: 0.54, blue: 0.88)
    static let dim = Color.white.opacity(0.5)
}

// MARK: - Pantalla principal

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLibrary = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if let track = player.current {
                    Spacer(minLength: 0)
                    ArtworkView(track: track)
                    Spacer(minLength: 0)
                    NowPlayingControls(track: track)
                } else {
                    Spacer()
                    LogoView()
                    Spacer()
                }
                MusicButton(active: showLibrary) { showLibrary = true }
            }
        }
        .sheet(isPresented: $showLibrary) {
            LibrarySheet { showLibrary = false }
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            let lib = library, pl = player
            pl.artworkFor = { lib.artworkImage(forKey: $0.albumKey) }
            pl.onTrackReady = { t in
                Task { if let updated = await lib.readTags(t) { pl.replace(updated) } }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
    }
}

struct LogoView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 190, height: 190)
            Text("Sonora")
                .font(.custom("SnellRoundhand-Bold", size: 34))
                .foregroundColor(.white.opacity(0.9))
        }
    }
}

struct ArtworkView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    let track: Track

    var body: some View {
        Group {
            if let img = library.artworkImage(forKey: track.albumKey) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.bar
                    Image("Logo").resizable().scaledToFit().padding(90).opacity(0.5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay {
            if player.isLoading {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 10) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        Text("Cargando…").font(.system(size: 13)).foregroundColor(.white.opacity(0.85))
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }
}

struct NowPlayingControls: View {
    @EnvironmentObject var player: Player
    let track: Track
    @State private var dragFraction: Double?

    private var fraction: Double {
        if let d = dragFraction { return d }
        return player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
    }

    var body: some View {
        VStack(spacing: 18) {
            // Barra de avance (delgada, se puede arrastrar)
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(height: 3)
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: geo.size.width * fraction, height: 3)
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
                .frame(height: 20)
                HStack {
                    Text(formatTime(fraction * player.duration))
                    Spacer()
                    Text(track.qualityLabel).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(track.isHiRes ? Theme.accent : Theme.dim)
                    Spacer()
                    Text("-" + formatTime(player.duration * (1 - fraction)))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.dim)
            }

            VStack(spacing: 4) {
                Text(track.title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist + " · " + track.album)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)
            }
            .foregroundColor(.white)

            HStack(spacing: 56) {
                control("backward.fill", 30) { player.previous() }
                control(player.isPlaying ? "pause.fill" : "play.fill", 46) { player.togglePlay() }
                control("forward.fill", 30) { player.next() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private func control(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MusicButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(active ? Theme.accent : .white.opacity(0.85))
                .frame(width: 70, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

// MARK: - Biblioteca (álbumes → canciones)

struct LibrarySheet: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var oneDrive = OneDrive.shared
    @State private var linking = false
    @State private var importing = false
    @State private var choosingOneDrive = false
    @State private var search = ""
    let onPlay: () -> Void

    private var filtered: [Album] {
        guard !search.isEmpty else { return library.albums }
        return library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    private func connectOneDrive() {
        Task {
            do {
                try await oneDrive.signIn()
                choosingOneDrive = true
            } catch OneDriveError.cancelled {
            } catch {
                library.lastError = error.localizedDescription
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.albums.isEmpty && !library.isBusy {
                    EmptyLibrary(oneDrive: { connectOneDrive() }, link: { linking = true })
                } else {
                    List {
                        if library.isBusy {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(library.status).font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(filtered) { album in
                            NavigationLink(value: album.id) { AlbumRow(album: album) }
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: "Buscar álbum o artista")
                }
            }
            .background(Theme.bg)
            .navigationTitle("Biblioteca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("OneDrive") {
                            if oneDrive.isSignedIn {
                                Button(library.oneDriveFolder.map { "Carpeta: \($0.name)" } ?? "Elegir carpeta de música", systemImage: "folder") {
                                    choosingOneDrive = true
                                }
                                Button("Cerrar sesión (\(oneDrive.accountName ?? "OneDrive"))", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    library.removeOneDrive()
                                    oneDrive.signOut()
                                }
                            } else {
                                Button("Conectar OneDrive", systemImage: "cloud") { connectOneDrive() }
                            }
                        }
                        Button("Vincular carpeta (iCloud Drive)", systemImage: "icloud") { linking = true }
                        Button("Copiar al iPhone", systemImage: "square.and.arrow.down") { importing = true }
                        if !library.folders.isEmpty {
                            Section("Carpetas vinculadas") {
                                ForEach(library.folders) { f in
                                    Menu(f.name) {
                                        Button("Quitar de la biblioteca", systemImage: "minus.circle", role: .destructive) {
                                            library.unlink(f)
                                        }
                                    }
                                }
                            }
                        }
                        Button("Actualizar", systemImage: "arrow.clockwise") {
                            library.refresh()
                            if library.oneDriveFolder != nil { library.refreshOneDrive() }
                        }
                    } label: { Image(systemName: "plus") }
                    .disabled(library.isBusy)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let album = library.albums.first(where: { $0.id == id }) {
                    TrackList(album: album, onPlay: onPlay)
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $choosingOneDrive) {
            OneDriveFolderPicker { folder in
                choosingOneDrive = false
                library.useOneDrive(folder)
            }
        }
        .alert("OneDrive", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.lastError ?? "") }
        .fileImporter(isPresented: $linking, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.link(urls) }
        }
        .background(
            Color.clear.fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFrom(urls) }
            }
        )
    }
}

struct EmptyLibrary: View {
    let oneDrive: () -> Void
    let link: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list").font(.system(size: 40, weight: .light))
            Text("Conecta tu música de OneDrive\no vincula una carpeta de iCloud Drive")
                .multilineTextAlignment(.center)
                .font(.system(size: 14))
            Button("Conectar OneDrive", action: oneDrive)
                .buttonStyle(.borderedProminent)
            Button("Vincular carpeta de iCloud", action: link)
                .buttonStyle(.bordered)
        }
        .foregroundColor(Theme.dim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Elegir carpeta de música en OneDrive

struct OneDriveFolderPicker: View {
    let onChoose: (OneDriveFolder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OneDriveFolderList(folder: nil, name: "OneDrive", onChoose: onChoose)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

struct OneDriveFolderList: View {
    let folder: String?
    let name: String
    let onChoose: (OneDriveFolder) -> Void
    @State private var items: [DriveItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundColor(.red).listRowBackground(Color.clear)
            } else {
                let folders = items.filter { $0.folder != nil }
                let audio = items.filter { Scanner.extensions.contains(($0.name as NSString).pathExtension.lowercased()) }.count
                if folders.isEmpty {
                    Text(audio > 0 ? "\(audio) canciones en esta carpeta" : "Sin subcarpetas")
                        .font(.system(size: 13)).foregroundColor(Theme.dim).listRowBackground(Color.clear)
                }
                ForEach(folders, id: \.id) { f in
                    NavigationLink {
                        OneDriveFolderList(folder: f.id, name: f.name, onChoose: onChoose)
                    } label: {
                        Label(f.name, systemImage: "folder")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let folder {
                Button {
                    onChoose(OneDriveFolder(id: folder, name: name))
                } label: {
                    Text("Usar \"\(name)\" como biblioteca")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .task {
            do { items = try await OneDrive.shared.children(of: folder).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct AlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            Thumb(key: album.id, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text([album.artist, album.year].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundColor(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            QualityBadge(label: album.qualityLabel, hiRes: album.isHiRes)
        }
        .padding(.vertical, 2)
    }
}

struct TrackList: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    let album: Album
    let onPlay: () -> Void

    var body: some View {
        List {
            VStack(spacing: 10) {
                Thumb(key: album.id, size: 200)
                Text(album.title).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                Text(album.artist).font(.system(size: 14)).foregroundColor(Theme.dim)
                Text([album.year, "\(album.tracks.count) canciones",
                      album.totalDuration > 0 && album.tracks.allSatisfy(\.tagsRead) ? formatTime(album.totalDuration) : nil,
                      album.qualityLabel, album.isCloud ? (album.tracks.first?.isOneDrive == true ? "OneDrive" : "en la nube") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
                HStack(spacing: 14) {
                    Button {
                        player.play(album.tracks, startAt: 0)
                        onPlay()
                    } label: {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                            .foregroundColor(Theme.bg)
                    }
                    .buttonStyle(.plain)
                    if album.tracks.first?.isOneDrive == true {
                        DownloadButton(album: album)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                Button {
                    player.play(album.tracks, startAt: i)
                    onPlay()
                } label: {
                    HStack(spacing: 14) {
                        Group {
                            if player.current?.id == t.id {
                                Image(systemName: "speaker.wave.2.fill").foregroundColor(Theme.accent)
                            } else {
                                Text(album.hasMultipleDiscs ? "\(t.discNumber)-\(String(format: "%02d", t.trackNumber))" : String(format: "%02d", t.trackNumber))
                                    .foregroundColor(Theme.dim)
                            }
                        }
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                        Text(t.title).lineLimit(1)
                            .foregroundColor(player.current?.id == t.id ? Theme.accent : .white)
                        Spacer()
                        Text(t.duration > 0 ? formatTime(t.duration) : "").font(.system(size: 13).monospacedDigit()).foregroundColor(Theme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .toolbar {
            if !album.isCloud {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Eliminar del iPhone", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .confirmationDialog("¿Eliminar \"\(album.title)\" del iPhone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                if album.tracks.contains(where: { $0.id == player.current?.id }) { player.stop() }
                library.delete(album)
                dismiss()
            }
        }
    }
}

// MARK: - Descargar álbum para escuchar sin internet

struct DownloadButton: View {
    @EnvironmentObject var library: Library
    let album: Album
    @State private var confirmRemove = false

    private var saved: Int { album.tracks.filter { library.offline.contains($0.id) }.count }
    private var complete: Bool { saved == album.tracks.count }

    var body: some View {
        let progress = library.downloads[album.id]
        Button {
            if complete { confirmRemove = true } else { library.download(album) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.bar)
                if let p = progress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .progressViewStyle(.circular).tint(Theme.accent)
                    Text("\(p.done)/\(p.total)").font(.system(size: 9, weight: .medium)).foregroundColor(.white).offset(y: 18)
                } else {
                    // La integral de Sonora + flecha (roja: descargar, verde: ya está en el iPhone)
                    Image("Glyph").resizable().scaledToFit()
                    Image(systemName: complete ? "checkmark" : "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(complete ? Color(red: 0.36, green: 0.82, blue: 0.55) : Color(red: 0.9, green: 0.28, blue: 0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                }
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(progress != nil)
        .overlay(alignment: .trailing) {
            if saved > 0 && !complete && progress == nil {
                Text("\(saved)/\(album.tracks.count)").font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize().offset(x: 34)
            }
        }
        .confirmationDialog("Este álbum está en el iPhone y se escucha sin internet. ¿Borrarlo del iPhone? Seguirá disponible en OneDrive.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Borrar del iPhone", role: .destructive) { library.removeDownload(album) }
        }
    }
}

struct Thumb: View {
    @EnvironmentObject var library: Library
    let key: String
    let size: CGFloat

    var body: some View {
        Group {
            if let img = library.artworkImage(forKey: key) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.bar
                    Image(systemName: "music.note").foregroundColor(Theme.dim)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 8 : 4))
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
