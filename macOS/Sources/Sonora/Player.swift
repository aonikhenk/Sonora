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

    var artworkFor: ((Track) -> NSImage?)?

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var nextTrack: Track? {
        guard let i = index, i + 1 < queue.count else { return nil }
        return queue[i + 1]
    }
    var duration: Double { current?.duration ?? 0 }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?

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
        guard let i = index else { return }
        start(index: i, at: seconds, autoplay: isPlaying)
    }

    // MARK: Motor

    private func start(index i: Int, at seconds: Double, autoplay: Bool = true) {
        guard queue.indices.contains(i) else { return }
        generation += 1
        node.stop()
        do {
            let f = try AVAudioFile(forReading: queue[i].url)
            let rate = f.fileFormat.sampleRate
            file = f
            index = i
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
        } catch {
            file = nil
            isPlaying = false
            if i + 1 < queue.count { start(index: i + 1, at: 0) }
        }
        updateNowPlaying()
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
            generation += 1
            node.stop()
            isPlaying = false
            currentTime = 0
            file = nil
            updateNowPlaying()
        }
    }

    private func tick() {
        guard isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return }
        currentTime = Double(startFrame + pt.sampleTime) / pt.sampleRate
    }

    private func handleConfigChange() {
        guard let i = index else { return }
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
            MPMediaItemPropertyPlaybackDuration: t.duration,
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
