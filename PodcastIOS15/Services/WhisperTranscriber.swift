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

    deinit { if let context { whisper_free(context) } }

    func transcribeStream(audioURL: URL, episode: Episode, language: String = "auto") -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTranscription(audioURL: audioURL, episode: episode, language: language, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runTranscription(audioURL: URL, episode: Episode, language: String, continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) async throws {
        let model = try await WhisperModelStore().modelURL()
        if context == nil {
            var options = whisper_context_default_params()
#if targetEnvironment(simulator)
            options.use_gpu = false
#else
            options.use_gpu = true
            options.flash_attn = true
#endif
            context = whisper_init_from_file_with_params(model.path, options)
        }
        guard let context else { throw WhisperTranscriptionError.modelInitializationFailed }
        let asset = AVURLAsset(url: audioURL)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw WhisperTranscriptionError.audioDecodeFailed }
        let duration = asset.duration.seconds
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperTranscriptionError.audioDecodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }

        let samplesPerSecond = 16_000
        let chunkSize = samplesPerSecond * 30
        var pending: [Float] = []
        pending.reserveCapacity(chunkSize + samplesPerSecond)
        var processedSamples = 0
        var allSegments: [TranscriptSegment] = []

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            pending.append(contentsOf: samples(from: sampleBuffer))
            while pending.count >= chunkSize {
                let chunk = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)
                let baseTime = Double(processedSamples) / Double(samplesPerSecond)
                let segments = try transcribeChunk(chunk, context: context, language: language, baseTime: baseTime)
                processedSamples += chunk.count
                allSegments.append(contentsOf: segments)
                try? TranscriptCache.save(allSegments, episodeID: episode.id)
                let progress = duration.isFinite && duration > 0 ? min(1, (baseTime + 30) / duration) : 0
                continuation.yield(TranscriptionBatch(segments: segments, progress: progress))
            }
        }
        guard reader.status == .completed else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }
        if pending.count >= samplesPerSecond {
            let baseTime = Double(processedSamples) / Double(samplesPerSecond)
            let segments = try transcribeChunk(pending, context: context, language: language, baseTime: baseTime)
            allSegments.append(contentsOf: segments)
            try? TranscriptCache.save(allSegments, episodeID: episode.id)
            continuation.yield(TranscriptionBatch(segments: segments, progress: 1))
        }
        guard !allSegments.isEmpty else { throw WhisperTranscriptionError.transcriptionFailed }
    }

    private func transcribeChunk(_ samples: [Float], context: OpaquePointer, language: String, baseTime: TimeInterval) throws -> [TranscriptSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(max(1, min(6, ProcessInfo.processInfo.processorCount - 2)))
        params.no_context = false
        params.single_segment = false
        let status: Int32 = language.withCString { code in
            params.language = code
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw WhisperTranscriptionError.transcriptionFailed }
        var result: [TranscriptSegment] = []
        for index in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, index)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = baseTime + Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = baseTime + Double(whisper_full_get_segment_t1(context, index)) / 100
            result.append(TranscriptSegment(start: start, end: end, text: text))
        }
        return result
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
    private static func url(episodeID: String) -> URL {
        let safe = episodeID.data(using: .utf8)?.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") ?? UUID().uuidString
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Transcripts", isDirectory: true).appendingPathComponent(String(safe.prefix(120)) + ".json")
    }
}
