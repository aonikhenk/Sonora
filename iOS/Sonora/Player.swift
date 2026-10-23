import Foundation
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isLoading = false        // descargando la canción desde la nube
    @Published private(set) var fileDuration: Double = 0

    var artworkFor: ((Track) -> UIImage?)?
    var onTrackReady: ((Track) -> Void)?                  // para leer etiquetas de canciones de la nube

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var duration: Double { fileDuration > 0 ? fileDuration : (current?.duration ?? 0) }

    /// Actualiza los datos de una canción en la cola (tras leer sus etiquetas).
    func replace(_ t: Track) {
        if let i = queue.firstIndex(where: { $0.id == t.id }) { queue[i] = t; updateNowPlaying() }
    }
    var outputRate: Double { AVAudioSession.sharedInstance().sampleRate }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var resumeAfterInterruption = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Streaming directo (OneDrive) mientras la canción aún no está en caché
    private var stream: AVPlayer?
    private var streamObservers: [NSObjectProtocol] = []
    private var streamStatus: NSKeyValueObservation?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        Task { await Self.activateSession(rate: nil) }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigChange() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in self?.handleInterruption(type, shouldResume: opts.contains(.shouldResume)) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Al desconectar audífonos o DAC: pausa
            if reason == .oldDeviceUnavailable { Task { @MainActor in self?.pause() } }
        })

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        setupRemoteCommands()
    }

    // MARK: Control

    func play(_ tracks: [Track], startAt i: Int) {
        queue = tracks
        start(index: i, at: 0)
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        if let s = stream { s.pause(); isPlaying = false; updateNowPlaying(); return }
        if isLoading { isPlaying = false; return }
        node.pause()
        engine.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard let i = index else { return }
        if let s = stream { s.play(); isPlaying = true; updateNowPlaying(); return }
        if isLoading { isPlaying = true; return }
        guard file != nil else { start(index: i, at: currentTime); return }
        if !engine.isRunning {
            do { try engine.start() } catch { start(index: i, at: currentTime); return }
        }
        node.play()
        isPlaying = true
        updateNowPlaying()
    }

    func next() {
        guard let i = index, i + 1 < queue.count else { return }
        start(index: i + 1, at: 0)
    }

    func previous() {
        guard let i = index else { return }
        start(index: (currentTime > 3 || i == 0) ? i : i - 1, at: 0)
    }

    func seek(to seconds: Double) {
        if let s = stream {
            s.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
            currentTime = max(0, seconds)
            updateNowPlaying()
            return
        }
        guard let f = file else { return }
        let rate = f.processingFormat.sampleRate
        generation += 1
        node.stop()
        startFrame = min(AVAudioFramePosition(max(0, seconds) * rate), f.length)
        currentTime = Double(startFrame) / rate
        schedule(f, from: startFrame)
        if isPlaying {
            if !engine.isRunning { try? engine.start() }
            node.play()
        }
        updateNowPlaying()
    }

    // MARK: Motor

    private func start(index i: Int, at seconds: Double, autoplay: Bool = true) {
        guard queue.indices.contains(i) else { return }
        generation += 1
        let gen = generation
        node.stop()
        endStream()
        file = nil
        index = i
        fileDuration = 0
        currentTime = max(0, seconds)
        isPlaying = autoplay
        isLoading = true
        updateNowPlaying()

        let track = queue[i]

        // OneDrive sin caché: empieza a sonar por streaming y en paralelo guarda la canción
        if track.isOneDrive && !OneDriveCache.isCached(track) {
            Task {
                do {
                    let url = try await OneDrive.shared.downloadURL(itemID: track.path)
                    guard gen == generation else { return }
                    startStream(url, track: track, at: seconds, gen: gen)
                } catch {
                    guard gen == generation else { return }
                    isLoading = false
                    skip(from: i)
                }
            }
            Task { [weak self] in
                if await OneDriveCache.download(track) {
                    self?.onTrackReady?(track)
                }
            }
            prefetch(after: i)
            return
        }

        Task {
            let ok = track.isOneDrive ? await OneDriveCache.download(track) : await CloudFiles.ensureLocal(track.url)
            guard gen == generation else { return }
            isLoading = false
            guard ok, let opened = await open(track, at: seconds, autoplay: isPlaying, gen: gen) else {
                if !ok && gen == generation { skip(from: i) }
                return
            }
            if opened {
                onTrackReady?(track)
                prefetch(after: i)
            } else {
                skip(from: i)
            }
        }
    }

    private func skip(from i: Int) {
        if i + 1 < queue.count { start(index: i + 1, at: 0) } else { stop() }
    }

    // MARK: Streaming

    private func startStream(_ url: URL, track: Track, at seconds: Double, gen: Int) {
        if engine.isRunning { engine.pause() }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        let s = AVPlayer(playerItem: item)
        s.automaticallyWaitsToMinimizeStalling = true
        stream = s
        if seconds > 0 { s.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

        let nc = NotificationCenter.default
        streamObservers.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.trackFinished()
            }
        })
        streamObservers.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.streamFailed(track, gen: gen) }
        })
        streamStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let d = item.duration.seconds
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    if d.isFinite && d > 0 { self.fileDuration = d }
                    self.updateNowPlaying()
                case .failed:
                    self.streamFailed(track, gen: gen)
                default: break
                }
            }
        }
        if isPlaying { s.play() }
    }

    /// Si el streaming falla (formato no soportado, red), descarga la canción y la reproduce desde el caché.
    private func streamFailed(_ track: Track, gen: Int) {
        guard gen == generation, let i = index else { return }
        let position = currentTime
        endStream()
        isLoading = true
        Task {
            let ok = await OneDriveCache.download(track)
            guard gen == generation else { return }
            isLoading = false
            guard ok, let opened = await open(track, at: position, autoplay: isPlaying, gen: gen) else {
                if !ok && gen == generation { skip(from: i) }
                return
            }
            if opened { onTrackReady?(track) } else { skip(from: i) }
        }
    }

    private func endStream() {
        stream?.pause()
        stream?.replaceCurrentItem(with: nil)
        stream = nil
        streamStatus?.invalidate()
        streamStatus = nil
        for o in streamObservers { NotificationCenter.default.removeObserver(o) }
        streamObservers = []
    }

    /// Activa la sesión de audio fuera del hilo principal (evita que la pantalla se congele).
    nonisolated private static func activateSession(rate: Double?) async {
        await Task.detached(priority: .userInitiated) {
            let s = AVAudioSession.sharedInstance()
            if let rate, s.sampleRate != rate { try? s.setPreferredSampleRate(rate) }
            try? s.setActive(true)
        }.value
    }

    /// Abre el archivo ya disponible y lo reproduce. Devuelve nil si mientras tanto se eligió otra canción.
    private func open(_ track: Track, at seconds: Double, autoplay: Bool, gen: Int) async -> Bool? {
        do {
            let f = try AVAudioFile(forReading: track.url)
            let rate = f.fileFormat.sampleRate

            // Pide al iPhone (o al DAC USB-C) la frecuencia nativa del archivo
            if AVAudioSession.sharedInstance().sampleRate != rate {
                if engine.isRunning { engine.stop() }
                await Self.activateSession(rate: rate)
                guard gen == generation else { return nil }
            }
            file = f
            fileDuration = Double(f.length) / rate

            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
            if !engine.isRunning { try engine.start() }

            startFrame = min(AVAudioFramePosition(max(0, seconds) * rate), f.length)
            currentTime = Double(startFrame) / rate
            schedule(f, from: startFrame)
            if autoplay { node.play() }
            isPlaying = autoplay
            updateNowPlaying()
            return true
        } catch {
            file = nil
            isPlaying = false
            return false
        }
    }

    /// Descarga en segundo plano la siguiente canción para que empiece sin espera.
    private func prefetch(after i: Int) {
        guard i + 1 < queue.count else { return }
        let next = queue[i + 1]
        Task.detached(priority: .utility) {
            if next.isOneDrive { _ = await OneDriveCache.download(next) } else { _ = await CloudFiles.ensureLocal(next.url) }
        }
    }

    private func schedule(_ f: AVAudioFile, from frame: AVAudioFramePosition) {
        let remaining = f.length - frame
        guard remaining > 0 else { return }
        let gen = generation
        node.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.trackFinished()
            }
        }
    }

    private func trackFinished() {
        if let i = index, i + 1 < queue.count {
            start(index: i + 1, at: 0)
        } else {
            stop()
        }
    }

    /// Detiene todo y vuelve a mostrar el logo.
    func stop() {
        generation += 1
        node.stop()
        endStream()
        engine.stop()
        isPlaying = false
        currentTime = 0
        file = nil
        fileDuration = 0
        isLoading = false
        index = nil
        queue = []
        updateNowPlaying()
    }

    private func tick() {
        if let s = stream {
            let t = s.currentTime().seconds
            if t.isFinite { currentTime = t }
            if isPlaying { isLoading = s.timeControlStatus == .waitingToPlayAtSpecifiedRate }
            return
        }
        guard isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return }
        currentTime = Double(startFrame + pt.sampleTime) / pt.sampleRate
    }

    private func handleConfigChange() {
        guard let i = index, file != nil else { return }
        start(index: i, at: currentTime, autoplay: isPlaying)
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying { node.pause(); stream?.pause(); isPlaying = false; updateNowPlaying() }
        case .ended:
            if shouldResume && resumeAfterInterruption {
                Task {
                    await Self.activateSession(rate: nil)
                    resume()
                }
            }
            resumeAfterInterruption = false
        default: break
        }
    }

    // MARK: Pantalla bloqueada / Centro de control

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent {
                let t = e.positionTime
                Task { @MainActor in self?.seek(to: t) }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let img = artworkFor?(t) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
    }
}
