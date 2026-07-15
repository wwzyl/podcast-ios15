import AVFoundation
import MediaPlayer
import Foundation

enum PlaybackRepeatMode: String, CaseIterable, Identifiable {
    case off, one, queue
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "不循环"; case .one: return "单集循环"; case .queue: return "队列循环" }
    }
}

@MainActor
final class PlayerManager: ObservableObject {
    @Published private(set) var episode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackStatus: String?
    @Published var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    @Published var repeatSegment: TranscriptSegment? { didSet { completedSentenceRepeats = 0 } }
    @Published var sentenceRepeatCount = 0
    @Published private(set) var queue: [Episode] = []
    @Published var repeatMode: PlaybackRepeatMode = .off
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var abStart: TimeInterval?
    @Published private(set) var abEnd: TimeInterval?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var completedSentenceRepeats = 0

    init() {
        configureAudioSession()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let manager = self else { return }
            Task { @MainActor in manager.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in manager.handlePlaybackEnded() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ episode: Episode, sourceURL: URL? = nil, autoPlay: Bool = true) {
        if self.episode?.id != episode.id {
            saveProgress()
            repeatSegment = nil
            clearABRepeat()
            self.episode = episode
            currentTime = 0
            duration = episode.duration ?? 0
            playbackStatus = "正在准备播放…"
            player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL ?? episode.audioURL))
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
        playbackStatus = "正在缓冲…"
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

    func setQueue(_ episodes: [Episode], current: Episode) {
        queue = episodes
        if !queue.contains(where: { $0.id == current.id }) { queue.append(current) }
    }

    func playNext() {
        guard let episode, let index = queue.firstIndex(where: { $0.id == episode.id }), index + 1 < queue.count else { return }
        load(queue[index + 1])
    }

    func playPrevious() {
        guard let episode, let index = queue.firstIndex(where: { $0.id == episode.id }), index > 0 else { return }
        load(queue[index - 1])
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerEnd = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    func markABoundary() {
        repeatSegment = nil
        if abStart == nil || abEnd != nil {
            abStart = currentTime
            abEnd = nil
        } else if let start = abStart, currentTime > start + 0.2 {
            abEnd = currentTime
            seek(to: start)
        }
    }

    func clearABRepeat() { abStart = nil; abEnd = nil }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let value = player.currentItem?.duration.seconds, value.isFinite { duration = value }
        switch player.timeControlStatus {
        case .playing: playbackStatus = nil
        case .waitingToPlayAtSpecifiedRate: playbackStatus = "正在缓冲…"
        case .paused: if isPlaying { playbackStatus = "正在准备播放…" }
        @unknown default: break
        }
        if let end = sleepTimerEnd, Date() >= end { setSleepTimer(minutes: nil); pause(); return }
        if let start = abStart, let end = abEnd, seconds >= end { seek(to: start) }
        if let segment = repeatSegment, let end = segment.end, seconds >= end {
            completedSentenceRepeats += 1
            if sentenceRepeatCount == 0 || completedSentenceRepeats < sentenceRepeatCount {
                seek(to: segment.start)
            } else {
                repeatSegment = nil
            }
        }
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

    private func handlePlaybackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0); play()
        case .queue:
            guard let episode, let index = queue.firstIndex(where: { $0.id == episode.id }) else { isPlaying = false; return }
            if index + 1 < queue.count { load(queue[index + 1]) }
            else if let first = queue.first { load(first) }
            else { isPlaying = false }
        case .off:
            if let episode, let index = queue.firstIndex(where: { $0.id == episode.id }), index + 1 < queue.count {
                load(queue[index + 1])
            } else {
                isPlaying = false
            }
        }
    }

    private func progressKey(_ episode: Episode) -> String { "progress.\(episode.id)" }
    private func saveProgress() {
        guard let episode else { return }
        UserDefaults.standard.set(currentTime, forKey: progressKey(episode))
    }
}
