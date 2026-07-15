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

actor WhisperTranscriber {
    static let shared = WhisperTranscriber()
    private var context: OpaquePointer?

    deinit { if let context { whisper_free(context) } }

    func transcribe(episode: Episode, language: String = "auto") async throws -> [TranscriptSegment] {
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
        let localAudio = try await downloadAudio(episode.audioURL)
        let samples = try decodeAudio(localAudio)
        guard !samples.isEmpty else { throw WhisperTranscriptionError.audioDecodeFailed }
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
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            result.append(TranscriptSegment(start: start, end: end, text: text))
        }
        guard !result.isEmpty else { throw WhisperTranscriptionError.transcriptionFailed }
        try? TranscriptCache.save(result, episodeID: episode.id)
        return result
    }

    private func downloadAudio(_ remoteURL: URL) async throws -> URL {
        if remoteURL.isFileURL { return remoteURL }
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 600
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try validate(response)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).\(remoteURL.pathExtension.isEmpty ? "m4a" : remoteURL.pathExtension)")
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { throw WhisperTranscriptionError.audioDownloadFailed }
        return destination
    }

    private func decodeAudio(_ url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw WhisperTranscriptionError.audioDecodeFailed }
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
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperTranscriptionError.audioDecodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }
        var samples: [Float] = []
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer else { continue }
            let values = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: length / MemoryLayout<Int16>.size)
            for index in 0..<(length / MemoryLayout<Int16>.size) { samples.append(Float(Int16(littleEndian: values[index])) / 32768) }
        }
        guard reader.status == .completed else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }
        return samples
    }
}

private struct WhisperModelStore {
    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin?download=true")!
    func modelURL() async throws -> URL {
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
