import Foundation
import AVFoundation
import CoreAudio
import MediaPlayer
import AppKit

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var outputRate: Double = 0
    @Published var nativeRate: Bool = UserDefaults.standard.bool(forKey: "nativeRate") {
        didSet { UserDefaults.standard.set(nativeRate, forKey: "nativeRate") }
    }

    @Published private(set) var isLoading = false         // esperando la canción desde OneDrive
    @Published private(set) var fileDuration: Double = 0

    var artworkFor: ((Track) -> NSImage?)?
    var onTrackReady: ((Track) -> Void)?                   // para leer etiquetas de canciones de OneDrive

    /// Actualiza los datos de una canción en la cola (tras leer sus etiquetas).
    func replace(_ t: Track) {
        if let i = queue.firstIndex(where: { $0.id == t.id }) { queue[i] = t; updateNowPlaying() }
    }

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var nextTrack: Track? {
        guard let i = index, i + 1 < queue.count else { return nil }
        return queue[i + 1]
    }
    var duration: Double { fileDuration > 0 ? fileDuration : (current?.duration ?? 0) }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    // Streaming directo (OneDrive) mientras la canción aún no está en caché
    private var stream: AVPlayer?
    private var streamObservers: [NSObjectProtocol] = []
    private var streamStatus: NSKeyValueObservation?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleConfigChange() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        setupRemoteCommands()
        outputRate = Self.deviceRate()
    }

    // MARK: Control

    func play(_ tracks: [Track], startAt i: Int) {
        queue = tracks
        start(index: i, at: 0)
    }

    func togglePlay() {
        guard let i = index else { return }
        if let s = stream {
            if isPlaying { s.pause() } else { s.play() }
            isPlaying.toggle()
            updateNowPlaying()
            return
        }
        if isLoading { isPlaying.toggle(); return }
        if isPlaying {
            node.pause()
            isPlaying = false
        } else if !engine.isRunning || file == nil {
            start(index: i, at: currentTime)
            return
        } else {
            node.play()
            isPlaying = true
        }
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
        guard let i = index else { return }
        start(index: i, at: seconds, autoplay: isPlaying)
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
        let track = queue[i]

        // OneDrive sin caché: suena por streaming y en paralelo se guarda la canción
        if track.isOneDrive && !OneDriveCache.isCached(track) {
            isPlaying = autoplay
            isLoading = true
            updateNowPlaying()
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
                if await OneDriveCache.download(track) { self?.onTrackReady?(track) }
            }
            prefetch(after: i)
            return
        }

        isLoading = false
        if open(track, at: seconds, autoplay: autoplay) {
            if track.isOneDrive { onTrackReady?(track) }
            prefetch(after: i)
        } else {
            skip(from: i)
        }
        updateNowPlaying()
    }

    /// Abre un archivo disponible en el Mac y lo reproduce.
    private func open(_ track: Track, at seconds: Double, autoplay: Bool) -> Bool {
        do {
            let f = try AVAudioFile(forReading: track.url)
            let rate = f.fileFormat.sampleRate
            file = f
            fileDuration = Double(f.length) / rate
            if nativeRate { matchDeviceRate(rate) }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
            if !engine.isRunning { try engine.start() }

            startFrame = min(AVAudioFramePosition(max(0, seconds) * rate), f.length)
            currentTime = Double(startFrame) / rate
            schedule(f, from: startFrame)
            if autoplay { node.play() }
            isPlaying = autoplay
            outputRate = Self.deviceRate()
            updateNowPlaying()
            return true
        } catch {
            file = nil
            isPlaying = false
            return false
        }
    }

    private func skip(from i: Int) {
        if i + 1 < queue.count { start(index: i + 1, at: 0) } else { finish() }
    }

    /// Descarga en segundo plano la siguiente canción de OneDrive para que empiece sin espera.
    private func prefetch(after i: Int) {
        guard i + 1 < queue.count, queue[i + 1].isOneDrive else { return }
        let next = queue[i + 1]
        Task.detached(priority: .utility) { _ = await OneDriveCache.download(next) }
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
            if ok, open(track, at: position, autoplay: isPlaying) { onTrackReady?(track) } else { skip(from: i) }
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
            finish()
        }
    }

    private func finish() {
        generation += 1
        node.stop()
        endStream()
        isPlaying = false
        isLoading = false
        currentTime = 0
        file = nil
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

    // MARK: Frecuencia nativa del DAC

    private func matchDeviceRate(_ rate: Double) {
        let dev = Self.outputDevice()
        guard dev != 0, Self.deviceRate() != rate, Self.supportedRates(dev).contains(rate) else { return }
        if engine.isRunning { engine.stop() }
        var r = rate
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
        for _ in 0..<50 where Self.deviceRate() != rate { usleep(10_000) }
    }

    private static func outputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func deviceRate() -> Double {
        let dev = outputDevice()
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return rate
    }

    private static func supportedRates(_ dev: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges)
        return ranges.map(\.mMinimum)
    }

    // MARK: Teclas multimedia / Centro de control

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == false { self?.togglePlay() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == true { self?.togglePlay() } }; return .success }
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
        guard let t = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
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
        center.playbackState = isPlaying ? .playing : .paused
    }
}
