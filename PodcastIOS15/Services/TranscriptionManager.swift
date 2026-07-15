import Foundation
import Combine

struct TranscriptionJobState {
    var segments: [TranscriptSegment]
    var progress: Double
    var isRunning: Bool
    var isComplete: Bool
    var errorMessage: String?

    static let idle = TranscriptionJobState(segments: [], progress: 0, isRunning: false, isComplete: false, errorMessage: nil)
}

/// 由 App 根节点持有，离开播放页不会取消正在进行的转录。
@MainActor
final class TranscriptionManager: ObservableObject {
    @Published private(set) var jobs: [String: TranscriptionJobState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func state(for episode: Episode) -> TranscriptionJobState {
        if let state = jobs[episode.id] { return state }
        let cached = TranscriptCache.load(episodeID: episode.id) ?? []
        return TranscriptionJobState(segments: cached,
                                     progress: TranscriptCache.isComplete(episodeID: episode.id) ? 1 : 0,
                                     isRunning: false,
                                     isComplete: TranscriptCache.isComplete(episodeID: episode.id),
                                     errorMessage: nil)
    }

    func start(episode: Episode, audioURL: URL, force: Bool = false) {
        if tasks[episode.id] != nil { return }
        if !force, TranscriptCache.isComplete(episodeID: episode.id), let cached = TranscriptCache.load(episodeID: episode.id) {
            jobs[episode.id] = TranscriptionJobState(segments: cached, progress: 1, isRunning: false, isComplete: true, errorMessage: nil)
            return
        }
        if force { TranscriptCache.clear(episodeID: episode.id) }
        jobs[episode.id] = TranscriptionJobState(segments: [], progress: 0, isRunning: true, isComplete: false, errorMessage: nil)
        tasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await WhisperTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                for try await batch in stream {
                    var state = self.jobs[episode.id] ?? .idle
                    state.segments.append(contentsOf: batch.segments)
                    state.progress = batch.progress
                    state.isRunning = true
                    self.jobs[episode.id] = state
                }
                var state = self.jobs[episode.id] ?? .idle
                state.progress = 1
                state.isRunning = false
                state.isComplete = true
                self.jobs[episode.id] = state
            } catch is CancellationError {
                var state = self.jobs[episode.id] ?? .idle
                state.isRunning = false
                self.jobs[episode.id] = state
            } catch {
                var state = self.jobs[episode.id] ?? .idle
                state.isRunning = false
                state.errorMessage = error.localizedDescription
                self.jobs[episode.id] = state
            }
            self.tasks[episode.id] = nil
        }
    }

    func retry(episode: Episode, audioURL: URL) {
        tasks[episode.id]?.cancel()
        tasks[episode.id] = nil
        start(episode: episode, audioURL: audioURL, force: true)
    }
}
