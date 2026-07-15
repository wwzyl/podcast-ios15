import Foundation
import Combine
import UIKit

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
    private var generations: [String: UUID] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

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
        beginBackgroundExecution(for: episode.id)
        let generation = UUID()
        generations[episode.id] = generation
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
            // retry 后旧任务的取消回调不能清掉刚启动的新任务。
            if self.generations[episode.id] == generation {
                self.tasks[episode.id] = nil
                self.generations[episode.id] = nil
                self.endBackgroundExecution(for: episode.id)
            }
        }
    }

    func retry(episode: Episode, audioURL: URL) {
        tasks[episode.id]?.cancel()
        tasks[episode.id] = nil
        start(episode: episode, audioURL: audioURL, force: true)
    }

    private func beginBackgroundExecution(for episodeID: String) {
        guard backgroundTasks[episodeID] == nil else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Whisper-\(episodeID)") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.endBackgroundExecution(for: episodeID)
            }
        }
        if identifier != .invalid { backgroundTasks[episodeID] = identifier }
    }

    private func endBackgroundExecution(for episodeID: String) {
        guard let identifier = backgroundTasks.removeValue(forKey: episodeID), identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
