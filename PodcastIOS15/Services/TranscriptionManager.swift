import Foundation
import Combine
import UIKit

enum TranscriptionEngine: String, CaseIterable {
    case elevenLabs
    case whisper

    var title: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .whisper: return "Whisper"
        }
    }
}

struct TranscriptionJobState {
    var segments: [TranscriptSegment]
    var progress: Double
    var isRunning: Bool
    var isComplete: Bool
    var errorMessage: String?
    var engine: TranscriptionEngine

    static let idle = TranscriptionJobState(segments: [], progress: 0, isRunning: false, isComplete: false, errorMessage: nil, engine: .elevenLabs)
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
                                     errorMessage: nil,
                                     engine: .elevenLabs)
    }

    func start(episode: Episode, audioURL: URL, engine: TranscriptionEngine = .elevenLabs, force: Bool = false) {
        if tasks[episode.id] != nil { return }
        if !force, TranscriptCache.isComplete(episodeID: episode.id), let cached = TranscriptCache.load(episodeID: episode.id) {
            jobs[episode.id] = TranscriptionJobState(segments: cached, progress: 1, isRunning: false, isComplete: true, errorMessage: nil, engine: engine)
            return
        }
        if force { TranscriptCache.clear(episodeID: episode.id) }
        let existing = force ? [] : (TranscriptCache.load(episodeID: episode.id) ?? [])
        jobs[episode.id] = TranscriptionJobState(segments: existing, progress: 0, isRunning: true, isComplete: false, errorMessage: nil, engine: engine)
        beginBackgroundExecution(for: episode.id, engine: engine)
        let generation = UUID()
        generations[episode.id] = generation
        tasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: AsyncThrowingStream<TranscriptionBatch, Error>
                switch engine {
                case .elevenLabs:
                    stream = await ElevenLabsTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                case .whisper:
                    stream = await WhisperTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                }
                for try await batch in stream {
                    guard self.generations[episode.id] == generation else { return }
                    var state = self.jobs[episode.id] ?? .idle
                    state.segments.append(contentsOf: batch.segments)
                    state.progress = batch.progress
                    state.isRunning = true
                    state.errorMessage = nil
                    state.engine = engine
                    self.jobs[episode.id] = state
                }
                guard self.generations[episode.id] == generation else { return }
                var state = self.jobs[episode.id] ?? .idle
                state.progress = 1
                state.isRunning = false
                state.isComplete = true
                state.errorMessage = nil
                state.engine = engine
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
                state.engine = engine
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

    /// 保留已经完成的分片，从断点继续尝试同一引擎或切换引擎。
    func retry(episode: Episode, audioURL: URL, engine: TranscriptionEngine = .elevenLabs) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL, engine: engine)
    }

    /// 清除旧文稿并从头使用指定引擎重新转写。
    func restart(episode: Episode, audioURL: URL, engine: TranscriptionEngine) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL, engine: engine, force: true)
    }

    func retranscribe(episode: Episode, audioURL: URL, from time: TimeInterval, engine: TranscriptionEngine = .elevenLabs) {
        cancelCurrentTask(for: episode.id)
        let retained = (TranscriptCache.load(episodeID: episode.id) ?? []).filter {
            ($0.end ?? $0.start) <= max(0, time)
        }
        try? TranscriptCache.savePartial(retained, episodeID: episode.id)
        try? TranscriptCache.setResumeTime(time, episodeID: episode.id)
        start(episode: episode, audioURL: audioURL, engine: engine)
    }

    private func cancelCurrentTask(for episodeID: String) {
        generations[episodeID] = nil
        tasks.removeValue(forKey: episodeID)?.cancel()
    }

    private func beginBackgroundExecution(for episodeID: String, engine: TranscriptionEngine) {
        guard backgroundTasks[episodeID] == nil else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "\(engine.title)-\(episodeID)") { [weak self] in
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
