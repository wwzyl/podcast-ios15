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

/// 由 App 根节点持有，离开播放页或切换标签不会取消正在进行的 Whisper 转录。
@MainActor
final class TranscriptionManager: ObservableObject {
    @Published private(set) var jobs: [String: TranscriptionJobState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    func state(for episode: Episode) -> TranscriptionJobState {
        if let state = jobs[episode.id] { return state }
        let cached = TranscriptCache.load(episodeID: episode.id) ?? []
        let complete = TranscriptCache.isComplete(episodeID: episode.id)
        return TranscriptionJobState(segments: cached,
                                     progress: complete ? 1 : 0,
                                     isRunning: false,
                                     isComplete: complete,
                                     errorMessage: nil)
    }

    func start(episode: Episode, audioURL: URL, force: Bool = false) {
        if tasks[episode.id] != nil { return }
        if !force, TranscriptCache.isComplete(episodeID: episode.id), let cached = TranscriptCache.load(episodeID: episode.id) {
            jobs[episode.id] = TranscriptionJobState(segments: cached, progress: 1, isRunning: false, isComplete: true, errorMessage: nil)
            return
        }
        if force { TranscriptCache.clear(episodeID: episode.id) }
        let existing = force ? [] : (TranscriptCache.load(episodeID: episode.id) ?? [])
        jobs[episode.id] = TranscriptionJobState(segments: existing, progress: 0, isRunning: true, isComplete: false, errorMessage: nil)
        beginBackgroundExecution(for: episode.id)
        let generation = UUID()
        generations[episode.id] = generation
        tasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await WhisperTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                for try await batch in stream {
                    guard self.generations[episode.id] == generation else { return }
                    var state = self.jobs[episode.id] ?? .idle
                    state.segments.append(contentsOf: batch.segments)
                    state.progress = batch.progress
                    state.isRunning = true
                    state.errorMessage = nil
                    self.jobs[episode.id] = state
                }
                guard self.generations[episode.id] == generation else { return }
                var state = self.jobs[episode.id] ?? .idle
                state.progress = 1
                state.isRunning = false
                state.isComplete = true
                state.errorMessage = nil
                self.jobs[episode.id] = state
            } catch is CancellationError {
                guard self.generations[episode.id] == generation else { return }
                var state = self.jobs[episode.id] ?? .idle
                state.isRunning = false
                self.jobs[episode.id] = state
            } catch {
                guard self.generations[episode.id] == generation else { return }
                var state = self.jobs[episode.id] ?? .idle
                state.isRunning = false
                state.errorMessage = error.localizedDescription
                self.jobs[episode.id] = state
            }
            if self.generations[episode.id] == generation {
                self.tasks[episode.id] = nil
                self.generations[episode.id] = nil
                self.endBackgroundExecution(for: episode.id)
            }
        }
    }

    /// 保留已完成句子，从最后断点继续 Whisper。
    func retry(episode: Episode, audioURL: URL) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL)
    }

    /// 清除旧文稿，从头进行 Whisper 转录。
    func restart(episode: Episode, audioURL: URL) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL, force: true)
    }

    func retranscribe(episode: Episode, audioURL: URL, from time: TimeInterval) {
        cancelCurrentTask(for: episode.id)
        let retained = (TranscriptCache.load(episodeID: episode.id) ?? []).filter {
            ($0.end ?? $0.start) <= max(0, time)
        }
        try? TranscriptCache.savePartial(retained, episodeID: episode.id)
        try? TranscriptCache.setResumeTime(time, episodeID: episode.id)
        start(episode: episode, audioURL: audioURL)
    }

    private func cancelCurrentTask(for episodeID: String) {
        generations[episodeID] = nil
        tasks.removeValue(forKey: episodeID)?.cancel()
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
