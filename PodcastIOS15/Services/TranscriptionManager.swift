import Foundation
import Combine
import UIKit

enum TranscriptionEngine: String, CaseIterable {
    case scribe
    case whisperFast
    case whisperBalanced
    case whisperFastEnglish
    case whisperBalancedEnglish
    case systemSpeech

    var title: String {
        switch self {
        case .scribe: return "Scribe v2"
        case .whisperFast: return "Whisper 极速"
        case .whisperBalanced: return "Whisper 均衡"
        case .whisperFastEnglish: return "Whisper 英语极速"
        case .whisperBalancedEnglish: return "Whisper 英语均衡"
        case .systemSpeech: return "Apple 系统识别"
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

    static let idle = TranscriptionJobState(segments: [], progress: 0, isRunning: false,
                                            isComplete: false, errorMessage: nil, engine: .scribe)
}

/// App-root-owned transcription jobs survive navigation away from the player.
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
        return TranscriptionJobState(segments: cached, progress: complete ? 1 : 0,
                                     isRunning: false, isComplete: complete,
                                     errorMessage: nil, engine: .scribe)
    }

    func start(episode: Episode, audioURL: URL, engine: TranscriptionEngine = .scribe, force: Bool = false) {
        if tasks[episode.id] != nil { return }
        if !force, TranscriptCache.isComplete(episodeID: episode.id), let cached = TranscriptCache.load(episodeID: episode.id) {
            jobs[episode.id] = TranscriptionJobState(segments: cached, progress: 1, isRunning: false,
                                                     isComplete: true, errorMessage: nil, engine: engine)
            return
        }
        if force {
            TranscriptCache.clear(episodeID: episode.id)
            ScribeTranscriber.shared.clearCache(episodeID: episode.id)
        }
        let existing = force ? [] : (TranscriptCache.load(episodeID: episode.id) ?? [])
        jobs[episode.id] = TranscriptionJobState(segments: existing, progress: 0, isRunning: true,
                                                 isComplete: false, errorMessage: nil, engine: engine)
        beginBackgroundExecution(for: episode.id, engine: engine)
        let generation = UUID()
        generations[episode.id] = generation
        tasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: AsyncThrowingStream<TranscriptionBatch, Error>
                switch engine {
                case .scribe:
                    stream = await ScribeTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                case .whisperFast, .whisperBalanced, .whisperFastEnglish, .whisperBalancedEnglish:
                    stream = await WhisperTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode,
                                                                              language: engine.whisperQuality?.language ?? "auto",
                                                                              quality: engine.whisperQuality ?? .fast)
                case .systemSpeech:
                    stream = await SystemSpeechTranscriber.shared.transcribeStream(audioURL: audioURL, episode: episode)
                }
                for try await batch in stream {
                    guard self.generations[episode.id] == generation else { return }
                    var state = self.jobs[episode.id] ?? .idle
                    if batch.replacesExisting { state.segments = batch.segments }
                    else { state.segments.append(contentsOf: batch.segments) }
                    state.progress = batch.progress
                    state.isRunning = true
                    state.isComplete = false
                    state.errorMessage = nil
                    state.engine = engine
                    self.jobs[episode.id] = state
                }
                guard self.generations[episode.id] == generation else { return }
                var state = self.jobs[episode.id] ?? .idle
                state.segments = TranscriptCache.load(episodeID: episode.id) ?? state.segments
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
                state.segments = TranscriptCache.load(episodeID: episode.id) ?? state.segments
                state.isRunning = false
                state.isComplete = false
                state.errorMessage = error.localizedDescription
                state.engine = engine
                self.jobs[episode.id] = state
            }
            if self.generations[episode.id] == generation {
                self.tasks[episode.id] = nil
                self.generations[episode.id] = nil
                self.endBackgroundExecution(for: episode.id)
            }
        }
    }

    func retry(episode: Episode, audioURL: URL, engine: TranscriptionEngine = .scribe) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL, engine: engine)
    }

    func restart(episode: Episode, audioURL: URL, engine: TranscriptionEngine) {
        cancelCurrentTask(for: episode.id)
        start(episode: episode, audioURL: audioURL, engine: engine, force: true)
    }

    func retranscribe(episode: Episode, audioURL: URL, from time: TimeInterval, engine: TranscriptionEngine = .scribe) {
        cancelCurrentTask(for: episode.id)
        ScribeTranscriber.shared.clearCache(episodeID: episode.id)
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
            Task { @MainActor in self?.endBackgroundExecution(for: episodeID) }
        }
        if identifier != .invalid { backgroundTasks[episodeID] = identifier }
    }

    private func endBackgroundExecution(for episodeID: String) {
        guard let identifier = backgroundTasks.removeValue(forKey: episodeID), identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

extension TranscriptionEngine {
    var whisperQuality: WhisperQuality? {
        switch self {
        case .scribe: return nil
        case .whisperFast: return .fast
        case .whisperBalanced: return .balanced
        case .whisperFastEnglish: return .fastEnglish
        case .whisperBalancedEnglish: return .balancedEnglish
        case .systemSpeech: return nil
        }
    }
}
