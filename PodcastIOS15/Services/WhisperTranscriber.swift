import Foundation
import AVFoundation
import CoreMedia
import CoreML
import whisper
import ZIPFoundation

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

enum WhisperQuality: String, CaseIterable {
    case fast
    case balanced
    case fastEnglish
    case balancedEnglish

    var filename: String {
        switch self {
        case .fast: return "ggml-base-q5_1.bin"
        case .balanced: return "ggml-small-q5_1.bin"
        case .fastEnglish: return "ggml-base.en-q5_1.bin"
        case .balancedEnglish: return "ggml-small.en-q5_1.bin"
        }
    }

    var language: String { self == .fastEnglish || self == .balancedEnglish ? "en" : "auto" }
    var title: String {
        switch self {
        case .fast: return "极速"
        case .balanced: return "均衡"
        case .fastEnglish: return "英语极速"
        case .balancedEnglish: return "英语均衡"
        }
    }

    var encoderArchiveFilename: String? {
        switch self {
        case .fast: return nil
        case .balanced: return "ggml-small-encoder.mlmodelc.zip"
        case .fastEnglish: return "ggml-base.en-encoder.mlmodelc.zip"
        case .balancedEnglish: return "ggml-small.en-encoder.mlmodelc.zip"
        }
    }

    var installedEncoderFilename: String {
        switch self {
        case .fast: return "ggml-base-encoder.mlmodelc"
        case .balanced: return "ggml-small-encoder.mlmodelc"
        case .fastEnglish: return "ggml-base.en-encoder.mlmodelc"
        case .balancedEnglish: return "ggml-small.en-encoder.mlmodelc"
        }
    }
}

struct TranscriptionBatch {
    let segments: [TranscriptSegment]
    let progress: Double
    let replacesExisting: Bool
    let statusText: String?

    init(segments: [TranscriptSegment], progress: Double, replacesExisting: Bool = false, statusText: String? = nil) {
        self.segments = segments
        self.progress = progress
        self.replacesExisting = replacesExisting
        self.statusText = statusText
    }
}

actor WhisperTranscriber {
    static let shared = WhisperTranscriber()
    private var context: OpaquePointer?
    private var contextUsesGPU = false
    private var contextModelPath: String?
    private var vad = SileroVAD()

    deinit { if let context { whisper_free(context) } }

    func transcribeStream(audioURL: URL, episode: Episode, language: String = "auto", quality: WhisperQuality = .fast) -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.runTranscription(audioURL: audioURL, episode: episode, language: language, quality: quality, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func runTranscription(audioURL: URL, episode: Episode, language: String, quality: WhisperQuality, continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) async throws {
        let model = try await WhisperModelStore().modelURL(for: quality) { progress in
            continuation.yield(TranscriptionBatch(segments: [], progress: progress * 0.05,
                                                  statusText: "正在下载 \(quality.title) 模型 \(Int(progress * 100))%"))
        }
        continuation.yield(TranscriptionBatch(segments: [], progress: 0.05,
                                              statusText: "正在初始化 \(quality.title) 模型"))
        if contextModelPath != model.path {
            if let context { whisper_free(context) }
            context = nil
            contextModelPath = nil
        }
        if context == nil {
            context = makeContext(model: model, useGPU: true)
            contextUsesGPU = context != nil
            if context == nil {
                let fallbackModel = try cpuFallbackModel(for: model)
                context = makeContext(model: fallbackModel, useGPU: false)
                contextUsesGPU = false
            }
            if context != nil { contextModelPath = model.path }
        }
        guard context != nil else { throw WhisperTranscriptionError.modelInitializationFailed }
        continuation.yield(TranscriptionBatch(segments: [], progress: 0.06,
                                              statusText: "正在解码节目音频"))
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
        let pcmBuffer = try DiskPCMBuffer()
        defer { pcmBuffer.remove() }
        let preferences = TranscriptionPreferences.current
        var assembler = SentenceAssembler(preferences: preferences)

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try pcmBuffer.append(samples(from: sampleBuffer))
        }
        guard reader.status == .completed else { throw reader.error ?? WhisperTranscriptionError.audioDecodeFailed }

        let mappedPCM = try pcmBuffer.mappedData()
        continuation.yield(TranscriptionBatch(segments: [], progress: 0.08,
                                              statusText: "正在分析语音和静音片段"))
        let vadRanges = try? vad.speechRanges(in: mappedPCM, sampleCount: pcmBuffer.sampleCount,
                                              sampleRate: samplesPerSecond,
                                              maximumDuration: preferences.maximumSegmentDuration)
        let speechRanges = (vadRanges?.isEmpty == false)
            ? vadRanges!
            : boundedFallbackRanges(sampleCount: pcmBuffer.sampleCount,
                                    sampleRate: samplesPerSecond,
                                    maximumDuration: preferences.maximumSegmentDuration)
        guard !speechRanges.isEmpty else { throw WhisperTranscriptionError.audioDecodeFailed }
        continuation.yield(TranscriptionBatch(segments: [], progress: 0.1,
                                              statusText: "正在转录第 1 个语音片段，共 \(speechRanges.count) 个"))
        for (rangeIndex, range) in speechRanges.enumerated() {
            try Task.checkCancellation()
            let chunk = mappedPCM.floatSamples(in: range)
            let baseTime = resumeTime + Double(range.lowerBound) / Double(samplesPerSecond)
            let raw = try transcribeChunk(chunk, model: model, language: language, baseTime: baseTime)
            let sentences = assembler.consume(raw)
            if !sentences.isEmpty {
                allSegments.append(contentsOf: sentences)
                try? TranscriptCache.save(allSegments, episodeID: episode.id)
            }
            let processedTime = resumeTime + Double(range.upperBound) / Double(samplesPerSecond)
            continuation.yield(TranscriptionBatch(segments: sentences,
                                                  progress: progress(at: processedTime, duration: duration),
                                                  statusText: "正在转录第 \(rangeIndex + 1) 个语音片段，共 \(speechRanges.count) 个"))
        }
        if let finalSentence = assembler.finish() {
            allSegments.append(finalSentence)
            continuation.yield(TranscriptionBatch(segments: [finalSentence], progress: 1))
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
            let fallbackModel = try cpuFallbackModel(for: model)
            context = makeContext(model: fallbackModel, useGPU: false)
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

    private func cpuFallbackModel(for model: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("WhisperCPUFallback", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(model.lastPathComponent)
        let sourceSize = (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let destinationSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if sourceSize != destinationSize {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: model, to: destination)
        }
        return destination
    }

    private func runWhisper(_ samples: [Float], context: OpaquePointer, language: String) -> Int32 {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false; params.print_progress = false; params.print_timestamps = false; params.print_special = false
        params.translate = TranscriptionPreferences.current.translateToEnglish
        params.token_timestamps = TranscriptionPreferences.current.wordTimestamps
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

    private func boundedFallbackRanges(sampleCount: Int, sampleRate: Int,
                                       maximumDuration: TimeInterval) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        let chunkSize = max(sampleRate * 10, Int(maximumDuration * Double(sampleRate)))
        return stride(from: 0, to: sampleCount, by: chunkSize).map { start in
            start..<min(sampleCount, start + chunkSize)
        }
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

private final class DiskPCMBuffer {
    private let url: URL
    private let handle: FileHandle
    private(set) var sampleCount = 0

    init() throws {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TranscriptionPCM", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("f32")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func mappedData() throws -> Data {
        try handle.synchronize()
        try handle.close()
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private extension Data {
    func floatSamples(in range: Range<Int>) -> [Float] {
        guard !range.isEmpty else { return [] }
        return withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            return Array(values[range])
        }
    }
}

private final class SileroVAD {
    private let model: MLModel?
    private var hidden: MLMultiArray?
    private var cell: MLMultiArray?

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        if let url = Bundle.main.url(forResource: "silero-vad-unified-256ms-v6.0.0", withExtension: "mlmodelc") {
            model = try? MLModel(contentsOf: url, configuration: configuration)
        } else {
            model = nil
        }
        hidden = try? MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try? MLMultiArray(shape: [1, 128], dataType: .float32)
    }

    func speechRanges(in samples: Data, sampleCount: Int, sampleRate: Int, maximumDuration: Double) throws -> [Range<Int>] {
        resetState()
        guard model != nil else { return [0..<sampleCount] }
        let frameSize = 4_160
        var probabilities: [Double] = []
        var offset = 0
        while offset < sampleCount {
            probabilities.append(try probability(for: samples, sampleCount: sampleCount, offset: offset, frameSize: frameSize))
            offset += frameSize
        }

        let startThreshold = 0.55
        let endThreshold = 0.35
        let minSpeechFrames = 2
        let minSilenceFrames = 2
        let paddingFrames = 1
        var rawRanges: [Range<Int>] = []
        var startFrame: Int?
        var speechRun = 0
        var silenceRun = 0

        for index in probabilities.indices {
            let probability = probabilities[index]
            if startFrame == nil {
                speechRun = probability >= startThreshold ? speechRun + 1 : 0
                if speechRun >= minSpeechFrames { startFrame = max(0, index - speechRun + 1 - paddingFrames); silenceRun = 0 }
            } else {
                silenceRun = probability <= endThreshold ? silenceRun + 1 : 0
                if silenceRun >= minSilenceFrames, let start = startFrame {
                    let end = min(probabilities.count, index - silenceRun + 1 + paddingFrames)
                    if end > start { rawRanges.append(start..<end) }
                    startFrame = nil
                    speechRun = 0
                    silenceRun = 0
                }
            }
        }
        if let start = startFrame { rawRanges.append(start..<probabilities.count) }

        let merged = merge(rawRanges, maximumGapFrames: 2)
        let maximumFrames = max(46, Int(maximumDuration * Double(sampleRate) / Double(frameSize)))
        let split = merged.flatMap { splitRange($0, probabilities: probabilities, maximumFrames: maximumFrames, preferredSearchFrames: 32) }
        return split.compactMap { frameRange in
            let lower = min(sampleCount, frameRange.lowerBound * frameSize)
            let upper = min(sampleCount, frameRange.upperBound * frameSize)
            guard upper - lower >= sampleRate / 4 else { return nil }
            return lower..<upper
        }
    }

    private func probability(for samples: Data, sampleCount: Int, offset: Int, frameSize: Int) throws -> Double {
        guard let model, var hidden, var cell else { return 1 }
        let audio = try MLMultiArray(shape: [1, NSNumber(value: frameSize)], dataType: .float32)
        let count = min(frameSize, sampleCount - offset)
        samples.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            for index in 0..<frameSize { audio[index] = NSNumber(value: index < count ? values[offset + index] : 0) }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: audio),
            "hidden_state": MLFeatureValue(multiArray: hidden),
            "cell_state": MLFeatureValue(multiArray: cell)
        ])
        let output = try model.prediction(from: input)
        if let next = output.featureValue(for: "new_hidden_state")?.multiArrayValue { hidden = next }
        if let next = output.featureValue(for: "new_cell_state")?.multiArrayValue { cell = next }
        self.hidden = hidden
        self.cell = cell
        return output.featureValue(for: "vad_output")?.multiArrayValue?[0].doubleValue ?? 0
    }

    private func resetState() {
        hidden = try? MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try? MLMultiArray(shape: [1, 128], dataType: .float32)
    }

    private func merge(_ ranges: [Range<Int>], maximumGapFrames: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges {
            if let last = result.last, range.lowerBound - last.upperBound <= maximumGapFrames {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func splitRange(_ range: Range<Int>, probabilities: [Double], maximumFrames: Int, preferredSearchFrames: Int) -> [Range<Int>] {
        guard range.count > maximumFrames else { return [range] }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maximumFrames {
            let hardEnd = start + maximumFrames
            let searchStart = max(start + maximumFrames - preferredSearchFrames, start + 1)
            let split = (searchStart..<hardEnd).min { probabilities[$0] < probabilities[$1] } ?? hardEnd
            result.append(start..<max(start + 1, split))
            start = max(start + 1, split)
        }
        if start < range.upperBound { result.append(start..<range.upperBound) }
        return result
    }
}

private struct SentenceAssembler {
    private var pending: TranscriptSegment?
    private let terminalPattern = #"[.!?。！？…][\"'”’)]*$"#
    private let preferences: TranscriptionPreferences

    init(preferences: TranscriptionPreferences) { self.preferences = preferences }

    mutating func consume(_ fragments: [TranscriptSegment]) -> [TranscriptSegment] {
        var completed: [TranscriptSegment] = []
        for fragment in fragments {
            guard !fragment.text.isEmpty else { continue }
            if let current = pending {
                let gap = fragment.start - (current.end ?? current.start)
                let duration = (current.end ?? current.start) - current.start
                let commaBoundary = preferences.splitOnComma && isCommaTerminal(current.text)
                let chineseBoundary = chineseCharacterCount(current.text) >= preferences.chineseSegmentCount
                if (duration >= preferences.minimumSegmentDuration && (isTerminal(current.text) || commaBoundary || chineseBoundary)) ||
                    gap > 1.8 || duration >= preferences.maximumSegmentDuration {
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

    private func isCommaTerminal(_ text: String) -> Bool {
        text.range(of: #"[,，;；:：][\"'”’)]*$"#, options: .regularExpression) != nil
    }

    private func chineseCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ? count + 1 : count
        }
    }

    private func needsSpace(after left: String, before right: String) -> Bool {
        guard let first = right.first, let last = left.last else { return false }
        if ",.;:!?。！？…，；：)]}”’".contains(first) { return false }
        if "([{“‘\"".contains(last) { return false }
        return true
    }
}

private struct WhisperModelStore {
    func modelURL(for quality: WhisperQuality, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let name = (quality.filename as NSString).deletingPathExtension
        if let bundled = Bundle.main.url(forResource: name, withExtension: "bin") {
            return bundled
        }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(quality.filename)
        let minimumSize = quality == .balanced || quality == .balancedEnglish ? 150_000_000 : 50_000_000
        let modelReady = ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > minimumSize
        if !modelReady {
            let partial = destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            do {
                try await ModelDataDownloader.download(sources(for: quality.filename), to: partial) { progress($0 * 0.72) }
                let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > minimumSize else { throw WhisperTranscriptionError.modelDownloadFailed }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw WhisperTranscriptionError.modelDownloadFailed
            }
        }
        try await ensureEncoder(for: quality, folder: folder) { encoderProgress in
            progress(0.72 + encoderProgress * 0.28)
        }
        progress(1)
        return destination
    }

    private func ensureEncoder(for quality: WhisperQuality, folder: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let archiveFilename = quality.encoderArchiveFilename else { progress(1); return }
        let destination = folder.appendingPathComponent(quality.installedEncoderFilename, isDirectory: true)
        let weights = destination.appendingPathComponent("weights/weight.bin")
        if FileManager.default.fileExists(atPath: weights.path) { progress(1); return }

        let archive = folder.appendingPathComponent(archiveFilename)
        try? FileManager.default.removeItem(at: archive)
        try await ModelDataDownloader.download(sources(for: archiveFilename), to: archive, progress: progress)
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard archiveSize > 1_000_000 else { throw WhisperTranscriptionError.modelDownloadFailed }
        defer { try? FileManager.default.removeItem(at: archive) }
        let namedExtraction = folder.appendingPathComponent((archiveFilename as NSString).deletingPathExtension, isDirectory: true)
        let genericExtraction = folder.appendingPathComponent("mlmodelc", isDirectory: true)
        try? FileManager.default.removeItem(at: namedExtraction)
        try? FileManager.default.removeItem(at: genericExtraction)
        try FileManager.default.unzipItem(at: archive, to: folder)
        let extracted: URL
        if FileManager.default.fileExists(atPath: namedExtraction.path) { extracted = namedExtraction }
        else if FileManager.default.fileExists(atPath: genericExtraction.path) { extracted = genericExtraction }
        else { throw WhisperTranscriptionError.modelDownloadFailed }
        try? FileManager.default.removeItem(at: destination)
        if extracted != destination { try FileManager.default.moveItem(at: extracted, to: destination) }
        guard FileManager.default.fileExists(atPath: weights.path) else { throw WhisperTranscriptionError.modelDownloadFailed }
    }

    private func sources(for filename: String) -> [URL] {
        [
            URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(filename)?download=true")!,
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)?download=true")!
        ]
    }
}

enum WhisperModelCacheManager {
    static func cacheSize() -> Int64 {
        let folder = cacheFolder()
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func removeDownloadedModels() {
        try? FileManager.default.removeItem(at: cacheFolder())
    }

    private static func cacheFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Whisper", isDirectory: true)
    }
}

private final class ModelDataDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var expectedLength: Int64 = 0
    private var receivedLength: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var fileHandle: FileHandle?

    static func download(_ urls: [URL], to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in urls {
            try? FileManager.default.removeItem(at: destination)
            do {
                try await download(url, to: destination, progress: progress)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destination)
            }
        }
        throw lastError
    }

    private static func download(_ url: URL, to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ModelDataDownloader()
        delegate.progress = progress
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        delegate.fileHandle = try FileHandle(forWritingTo: destination)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 1_800
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            completionHandler(.cancel)
            return
        }
        expectedLength = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            receivedLength += Int64(data.count)
            if expectedLength > 0 { progress?(min(1, Double(receivedLength) / Double(expectedLength))) }
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil
        defer { self.session?.finishTasksAndInvalidate(); self.session = nil }
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else if expectedLength > 0, receivedLength != expectedLength { continuation.resume(throwing: URLError(.cannotDecodeContentData)) }
        else { progress?(1); continuation.resume() }
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
