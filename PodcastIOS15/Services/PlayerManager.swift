import AVFoundation
import MediaPlayer
import Foundation

@MainActor
final class PlayerManager: ObservableObject {
    @Published private(set) var episode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    @Published var repeatSegment: TranscriptSegment?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let manager = self else { return }
            Task { @MainActor in manager.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in manager.isPlaying = false }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ episode: Episode, autoPlay: Bool = true) {
        if self.episode?.id != episode.id {
            saveProgress()
            self.episode = episode
            player.replaceCurrentItem(with: AVPlayerItem(url: episode.audioURL))
            let saved = UserDefaults.standard.double(forKey: progressKey(episode))
            if saved > 3 { seek(to: saved) }
            updateNowPlaying()
        }
        if autoPlay { play() }
    }

    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }
    func pause() {
        player.pause()
        isPlaying = false
        saveProgress()
        updateNowPlaying()
    }
    func seek(to seconds: TimeInterval) {
        let safe = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = safe
        updateNowPlaying()
    }
    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let value = player.currentItem?.duration.seconds, value.isFinite { duration = value }
        if let segment = repeatSegment, let end = segment.end, seconds >= end { seek(to: segment.start) }
        if Int(seconds) % 10 == 0 { saveProgress() }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothA2DP])
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let manager = self else { return .commandFailed }
            Task { @MainActor in manager.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let manager = self else { return .commandFailed }
            Task { @MainActor in manager.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let manager = self else { return .commandFailed }
            Task { @MainActor in manager.toggle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let manager = self else { return .commandFailed }
            Task { @MainActor in manager.skip(15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let manager = self else { return .commandFailed }
            Task { @MainActor in manager.skip(-15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            guard let manager = self else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in manager.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyPodcastTitle: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
    }

    private func progressKey(_ episode: Episode) -> String { "progress.\(episode.id)" }
    private func saveProgress() {
        guard let episode else { return }
        UserDefaults.standard.set(currentTime, forKey: progressKey(episode))
    }
}
