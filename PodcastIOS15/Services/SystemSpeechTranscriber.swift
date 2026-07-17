import Foundation
import Speech

enum SystemSpeechError: LocalizedError {
    case denied
    case unavailable
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .denied: return "没有语音识别权限"
        case .unavailable: return "Apple 系统语音识别当前不可用"
        case .noSpeech: return "Apple 系统语音识别没有返回文本"
        }
    }
}

actor SystemSpeechTranscriber {
    static let shared = SystemSpeechTranscriber()

    func transcribeStream(audioURL: URL, episode: Episode) -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard await Self.authorized() else { throw SystemSpeechError.denied }
                    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw SystemSpeechError.unavailable }
                    let request = SFSpeechURLRecognitionRequest(url: audioURL)
                    request.shouldReportPartialResults = true
                    if #available(iOS 13.0, *), recognizer.supportsOnDeviceRecognition {
                        request.requiresOnDeviceRecognition = false
                    }
                    var recognitionTask: SFSpeechRecognitionTask?
                    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                        var finished = false
                        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                            if let result {
                                let segments = result.bestTranscription.segments.map {
                                    TranscriptSegment(start: $0.timestamp,
                                                      end: $0.timestamp + $0.duration,
                                                      text: $0.substring)
                                }
                                continuation.yield(TranscriptionBatch(segments: segments,
                                                                      progress: result.isFinal ? 1 : 0.5,
                                                                      replacesExisting: true))
                                if result.isFinal, !finished {
                                    finished = true
                                    do {
                                        guard !segments.isEmpty else { throw SystemSpeechError.noSpeech }
                                        try TranscriptCache.save(segments, episodeID: episode.id)
                                        try TranscriptCache.markComplete(episodeID: episode.id)
                                        completion.resume()
                                    } catch { completion.resume(throwing: error) }
                                }
                            } else if let error, !finished {
                                finished = true
                                completion.resume(throwing: error)
                            }
                        }
                    }
                    recognitionTask?.cancel()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}
