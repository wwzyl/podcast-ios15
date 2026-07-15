import Foundation
import AVFoundation
import CoreMedia
import whisper

enum WhisperTranscriptionError: LocalizedError {
    case modelDownloadFailed, modelInitializationFailed, audioDownloadFailed, audioDecodeFailed, transcriptionFailed
    var errorDescription: String? {
        switch self {
        case .modelDownloadFailed: return "Whisper 模型下载失败"
        case .modelInitializationFailed: return "Whisper 模型载入失败"
        case .audioDownloadFailed: return "节目音频下载失败"
        case .audioDecodeFailed: return "节目音频解码失败"
        case .transcriptionFailed: return "离线语音转写失败"
        }
    }
}

struct TranscriptionBatch {
    let segments: [TranscriptSegment]
    let progress: Double
}

actor WhisperTranscriber {
    static let shared = WhisperTranscriber()
    private var context: OpaquePointer?
    private var contextUsesGPU = false

    deinit { if let context { whisper_free(context) } }

    func transcribeStream(audioURL: URL, episode: Episode, language: String = "auto") -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.runTranscription(audioURL: audioURL, episode: episode, language: language, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func runTranscription(audioURL: URL, episode: Episode, language: String, continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) async throws {
        let model = try await WhisperModelStore().modelURL()
        if context == nil {
            context = makeContext(model: model, useGPU: true)
            contextUsesGPU = context != nil
            if context == nil { context = makeContext(model: model, useGPU: false); contextUsesGPU = false }
        }
        guard context != nil else { throw WhisperTranscriptionError.modelInitializationFailed }
        let asset = AVURLAsset(url: audioURL)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw WhisperTranscriptionError.audioDecodeFailed }
        let duration = asset.duration.seconds
        var allSegments = TranscriptCache.load(episodeID: episode.id) ?? []
        let cachedEnd = allSegments.last?.end ?? allSegments.last?.start ?? 0
        let resumeTime = min(max(0, max(cachedEnd, TranscriptCache.resumeTime(episodeID: episode.id) ?? 0)), max(0, duration))
        if !allSegments.isEmpty, duration.isFinite, resumeTime >= duration - 0.25 {
            try TranscriptCache.markComplete(episodeID: episode.id)
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperTranscriptionError.audioDecodeFailed }
        reader.add(output)
        if resumeTime > 0, duration.isFinite, duration > resumeTime {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: resumeTime, preferredTimescale: 600), end: CMTime(seconds: duration, preferredTimescale: 600))
        }
        guard reader.startReading() else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }

        let samplesPerSecond = 16_000
        let windowSize = samplesPerSecond * 20
        let stepSize = samplesPerSecond * 15
        var pending: [Float] = []
        pending.reserveCapacity(windowSize + samplesPerSecond)
        var processedSamples = 0
        var acceptedThrough = resumeTime
        var assembler = SentenceAssembler()

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            pending.append(contentsOf: samples(from: sampleBuffer))
            while pending.count >= windowSize {
                let chunk = Array(pending.prefix(windowSize))
                let baseTime = resumeTime + Double(processedSamples) / Double(samplesPerSecond)
                let raw = try transcribeChunk(chunk, model: model, language: language, baseTime: baseTime)
                try Task.checkCancellation()
                let boundary = baseTime + Double(stepSize) / Double(samplesPerSecond)
                let stable = raw.filter {
                    let midpoint = ($0.start + ($0.end ?? $0.start)) / 2
                    return midpoint >= acceptedThrough - 0.05 && midpoint < boundary
                }
                acceptedThrough = boundary
                let sentences = assembler.consume(stable)
                if !sentences.isEmpty { allSegments.append(contentsOf: sentences); try? TranscriptCache.save(allSegments, episodeID: episode.id) }
                continuation.yield(TranscriptionBatch(segments: sentences, progress: progress(at: boundary, duration: duration)))
                pending.removeFirst(stepSize)
                processedSamples += stepSize
            }
        }
        guard reader.status == .completed else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }
        if pending.count >= samplesPerSecond {
            let baseTime = resumeTime + Double(processedSamples) / Double(samplesPerSecond)
            let raw = try transcribeChunk(pending, model: model, language: language, baseTime: baseTime)
            try Task.checkCancellation()
            let remaining = raw.filter {
                let midpoint = ($0.start + ($0.end ?? $0.start)) / 2
                return midpoint >= acceptedThrough - 0.05
            }
            var sentences = assembler.consume(remaining)
            if let finalSentence = assembler.finish() { sentences.append(finalSentence) }
            allSegments.append(contentsOf: sentences)
            if !sentences.isEmpty { continuation.yield(TranscriptionBatch(segments: sentences, progress: 1)) }
        }
        guard !allSegments.isEmpty else { throw WhisperTranscriptionError.transcriptionFailed }
        try TranscriptCache.save(allSegments, episodeID: episode.id)
        try TranscriptCache.markComplete(episodeID: episode.id)
    }

    private func makeContext(model: URL, useGPU: Bool) -> OpaquePointer? {
        var options = whisper_context_default_params()
#if targetEnvironment(simulator)
        options.use_gpu = false
#else
        options.use_gpu = useGPU
        options.flash_attn = useGPU
#endif
        return whisper_init_from_file_with_params(model.path, options)
    }

    private func transcribeChunk(_ samples: [Float], model: URL, language: String, baseTime: TimeInterval) throws -> [TranscriptSegment] {
        guard var activeContext = context else { throw WhisperTranscriptionError.modelInitializationFailed }
        var status = runWhisper(samples, context: activeContext, language: language)
        if status != 0, contextUsesGPU {
            whisper_free(activeContext)
            context = makeContext(model: model, useGPU: false)
            contextUsesGPU = false
            guard let cpuContext = context else { throw WhisperTranscriptionError.modelInitializationFailed }
            activeContext = cpuContext
            status = runWhisper(samples, context: activeContext, language: language)
        }
        guard status == 0 else { throw WhisperTranscriptionError.transcriptionFailed }
        var result: [TranscriptSegment] = []
        for index in 0..<whisper_full_n_segments(activeContext) {
            let text = String(cString: whisper_full_get_segment_text(activeContext, index)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = baseTime + Double(whisper_full_get_segment_t0(activeContext, index)) / 100
            let end = baseTime + Double(whisper_full_get_segment_t1(activeContext, index)) / 100
            result.append(TranscriptSegment(start: start, end: end, text: text))
        }
        return result
    }

    private func runWhisper(_ samples: [Float], context: OpaquePointer, language: String) -> Int32 {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false; params.print_progress = false; params.print_timestamps = false; params.print_special = false
        params.translate = false
        params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        params.no_context = false; params.single_segment = false
        return language.withCString { code in
            params.language = code
            return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
    }

    private func progress(at time: TimeInterval, duration: TimeInterval) -> Double {
        duration.isFinite && duration > 0 ? min(1, time / duration) : 0
    }

    private func samples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer else { return [] }
        let count = length / MemoryLayout<Int16>.size
        let values = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: count)
        return (0..<count).map { Float(Int16(littleEndian: values[$0])) / 32768 }
    }
}

private struct SentenceAssembler {
    private var pending: TranscriptSegment?
    private let terminalPattern = #"[.!?。！？…][\"'”’)]*$"#

    mutating func consume(_ fragments: [TranscriptSegment]) -> [TranscriptSegment] {
        var completed: [TranscriptSegment] = []
        for fragment in fragments {
            guard !fragment.text.isEmpty else { continue }
            if let current = pending {
                let gap = fragment.start - (current.end ?? current.start)
                if isTerminal(current.text) || gap > 1.8 {
                    completed.append(current)
                    pending = fragment
                } else {
                    let separator = needsSpace(after: current.text, before: fragment.text) ? " " : ""
                    pending = TranscriptSegment(id: current.id,
                                                start: current.start,
                                                end: fragment.end,
                                                text: current.text + separator + fragment.text)
                }
            } else {
                pending = fragment
            }
            if let current = pending, isTerminal(current.text) {
                completed.append(current)
                pending = nil
            }
        }
        return completed
    }

    mutating func finish() -> TranscriptSegment? {
        defer { pending = nil }
        return pending
    }

    private func isTerminal(_ text: String) -> Bool {
        text.range(of: terminalPattern, options: .regularExpression) != nil
    }

    private func needsSpace(after left: String, before right: String) -> Bool {
        guard let first = right.first, let last = left.last else { return false }
        if ",.;:!?。！？…，；：)]}”’".contains(first) { return false }
        if "([{“‘\"".contains(last) { return false }
        return true
    }
}

private struct WhisperModelStore {
    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin?download=true")!
    func modelURL() async throws -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-base-q5_1", withExtension: "bin") {
            return bundled
        }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("ggml-base-q5_1.bin")
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 50_000_000 { return destination }
        let (temporary, response) = try await URLSession.shared.download(from: modelURL)
        try validate(response)
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { throw WhisperTranscriptionError.modelDownloadFailed }
        return destination
    }
}

enum TranscriptCache {
    static func load(episodeID: String) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: url(episodeID: episodeID)) else { return nil }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }
    static func save(_ segments: [TranscriptSegment], episodeID: String) throws {
        let destination = url(episodeID: episodeID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(segments).write(to: destination, options: .atomic)
    }
    static func isComplete(episodeID: String) -> Bool {
        FileManager.default.fileExists(atPath: completionURL(episodeID: episodeID).path)
    }
    static func markComplete(episodeID: String) throws {
        let destination = completionURL(episodeID: episodeID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: destination, options: .atomic)
        try? FileManager.default.removeItem(at: resumeURL(episodeID: episodeID))
    }
    static func clear(episodeID: String) {
        try? FileManager.default.removeItem(at: url(episodeID: episodeID))
        try? FileManager.default.removeItem(at: completionURL(episodeID: episodeID))
        try? FileManager.default.removeItem(at: resumeURL(episodeID: episodeID))
    }
    static func savePartial(_ segments: [TranscriptSegment], episodeID: String) throws {
        try? FileManager.default.removeItem(at: completionURL(episodeID: episodeID))
        try save(segments, episodeID: episodeID)
    }
    static func setResumeTime(_ time: TimeInterval, episodeID: String) throws {
        let destination = resumeURL(episodeID: episodeID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(max(0, time)).utf8).write(to: destination, options: .atomic)
    }
    static func resumeTime(episodeID: String) -> TimeInterval? {
        guard let data = try? Data(contentsOf: resumeURL(episodeID: episodeID)),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return TimeInterval(value)
    }
    private static func url(episodeID: String) -> URL {
        let safe = episodeID.data(using: .utf8)?.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") ?? UUID().uuidString
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Transcripts", isDirectory: true).appendingPathComponent(String(safe.prefix(120)) + ".json")
    }
    private static func completionURL(episodeID: String) -> URL {
        url(episodeID: episodeID).appendingPathExtension("complete")
    }
    private static func resumeURL(episodeID: String) -> URL {
        url(episodeID: episodeID).appendingPathExtension("resume")
    }
}
