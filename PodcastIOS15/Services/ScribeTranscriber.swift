import Foundation
import AVFoundation

enum ScribeTranscriptionError: LocalizedError {
    case audioUnavailable
    case audioExportFailed(String)
    case multipartCreationFailed
    case uploadFailed(status: Int, message: String, retryable: Bool)
    case invalidResponse
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .audioUnavailable: return "Scribe 无法读取已下载的节目音频"
        case .audioExportFailed(let message): return "Scribe 音频分片失败：\(message)"
        case .multipartCreationFailed: return "Scribe 上传文件准备失败"
        case .uploadFailed(let status, let message, _): return "Scribe v2 请求失败（HTTP \(status)）：\(message)"
        case .invalidResponse: return "Scribe v2 返回了无法解析的词级时间戳"
        case .noSpeech: return "Scribe v2 没有识别到可生成逐句稿的语音"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .uploadFailed(_, _, let retryable): return retryable
        case .invalidResponse: return true
        default: return false
        }
    }
}

private struct ScribeResponse: Decodable {
    let languageCode: String?
    let words: [ScribeWordToken]

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case words
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode)
        words = try values.decodeIfPresent([ScribeWordToken].self, forKey: .words) ?? []
    }
}

private struct ScribeChunkDescriptor: Hashable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let sourceDuration: TimeInterval
    let audioURL: URL
}

private struct ScribeChunkRecord: Codable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let languageCode: String?
    let words: [ScribeWordToken]

    func matches(_ descriptor: ScribeChunkDescriptor) -> Bool {
        index == descriptor.index && abs(start - descriptor.start) < 0.01 && abs(end - descriptor.end) < 0.01
    }
}

/// Complete iOS implementation of the scribe2srt processing flow: fixed-size
/// media chunks, bounded parallel uploads, rate limiting, retry/backoff,
/// per-chunk recovery, global word timestamps, and professional segmentation.
actor ScribeTranscriber {
    static let shared = ScribeTranscriber()

    private let chunkDuration: TimeInterval = 40 * 60
    private let maximumConcurrentChunks = 4
    private let rateLimiter = ScribeRateLimiter(maximumRequests: 30, interval: 60)

    func transcribeStream(audioURL: URL,
                          episode: Episode,
                          language: String = "auto") -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.run(audioURL: audioURL,
                                       episode: episode,
                                       language: language,
                                       continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    nonisolated func clearCache(episodeID: String) {
        ScribeChunkCache.clear(episodeID: episodeID)
    }

    private func run(audioURL: URL,
                     episode: Episode,
                     language: String,
                     continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) async throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ScribeTranscriptionError.audioUnavailable
        }
        let asset = AVURLAsset(url: audioURL)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, !asset.tracks(withMediaType: .audio).isEmpty else {
            throw ScribeTranscriptionError.audioUnavailable
        }

        let existingSegments = TranscriptCache.load(episodeID: episode.id) ?? []
        let cachedEnd = existingSegments.last?.end ?? existingSegments.last?.start ?? 0
        let requestedResume = TranscriptCache.resumeTime(episodeID: episode.id) ?? 0
        let cachedRecords = ScribeChunkCache.load(episodeID: episode.id)
        let hasRecordsFromBeginning = cachedRecords.contains { abs($0.start) < 0.01 }
        let baseStart = hasRecordsFromBeginning ? 0 : min(duration, max(cachedEnd, requestedResume))
        let prefix = baseStart > 0.01 ? existingSegments.filter { ($0.end ?? $0.start) <= baseStart + 0.01 } : []
        let descriptors = makeDescriptors(audioURL: audioURL, duration: duration, baseStart: baseStart)

        if descriptors.isEmpty {
            guard !prefix.isEmpty else { throw ScribeTranscriptionError.noSpeech }
            try TranscriptCache.markComplete(episodeID: episode.id)
            return
        }

        var records: [Int: ScribeChunkRecord] = [:]
        for descriptor in descriptors {
            if let record = cachedRecords.first(where: { $0.matches(descriptor) }) {
                records[descriptor.index] = record
            }
        }

        if !records.isEmpty {
            try publishContiguous(records: records,
                                  descriptors: descriptors,
                                  prefix: prefix,
                                  episodeID: episode.id,
                                  duration: duration,
                                  continuation: continuation)
        }

        let missing = descriptors.filter { records[$0.index] == nil }
        var nextIndex = 0
        try await withThrowingTaskGroup(of: ScribeChunkRecord.self) { group in
            func addNext() {
                guard nextIndex < missing.count else { return }
                let descriptor = missing[nextIndex]
                nextIndex += 1
                group.addTask {
                    try await ScribeChunkWorker.process(descriptor: descriptor,
                                                        language: language,
                                                        rateLimiter: self.rateLimiter)
                }
            }

            for _ in 0..<min(maximumConcurrentChunks, missing.count) { addNext() }
            while let record = try await group.next() {
                try Task.checkCancellation()
                records[record.index] = record
                try ScribeChunkCache.save(record, episodeID: episode.id)
                try publishContiguous(records: records,
                                      descriptors: descriptors,
                                      prefix: prefix,
                                      episodeID: episode.id,
                                      duration: duration,
                                      continuation: continuation)
                addNext()
            }
        }

        let finalSegments = render(records: records, descriptors: descriptors, prefix: prefix)
        guard !finalSegments.isEmpty else { throw ScribeTranscriptionError.noSpeech }
        try TranscriptCache.save(finalSegments, episodeID: episode.id)
        try TranscriptCache.markComplete(episodeID: episode.id)
    }

    private func makeDescriptors(audioURL: URL, duration: TimeInterval, baseStart: TimeInterval) -> [ScribeChunkDescriptor] {
        var descriptors: [ScribeChunkDescriptor] = []
        var cursor = max(0, baseStart)
        var index = 0
        while cursor < duration - 0.01 {
            let end = min(duration, cursor + chunkDuration)
            descriptors.append(ScribeChunkDescriptor(index: index,
                                                      start: cursor,
                                                      end: end,
                                                      sourceDuration: duration,
                                                      audioURL: audioURL))
            cursor = end
            index += 1
        }
        return descriptors
    }

    private func publishContiguous(records: [Int: ScribeChunkRecord],
                                   descriptors: [ScribeChunkDescriptor],
                                   prefix: [TranscriptSegment],
                                   episodeID: String,
                                   duration: TimeInterval,
                                   continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) throws {
        var contiguous: [ScribeChunkDescriptor] = []
        for descriptor in descriptors {
            guard records[descriptor.index] != nil else { break }
            contiguous.append(descriptor)
        }
        guard let last = contiguous.last else { return }
        let rendered = render(records: records, descriptors: contiguous, prefix: prefix)
        guard !rendered.isEmpty else { return }
        try TranscriptCache.savePartial(rendered, episodeID: episodeID)
        try TranscriptCache.setResumeTime(last.end, episodeID: episodeID)
        continuation.yield(TranscriptionBatch(segments: rendered,
                                              progress: min(1, last.end / duration),
                                              replacesExisting: true))
    }

    private func render(records: [Int: ScribeChunkRecord],
                        descriptors: [ScribeChunkDescriptor],
                        prefix: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered = descriptors.compactMap { records[$0.index] }
        let language = ordered.compactMap(\.languageCode).first
        let words = ordered.flatMap(\.words).sorted {
            ($0.start ?? .infinity) == ($1.start ?? .infinity)
                ? ($0.end ?? .infinity) < ($1.end ?? .infinity)
                : ($0.start ?? .infinity) < ($1.start ?? .infinity)
        }
        let generated = ScribeSubtitleProcessor.process(words: words, languageCode: language)
        return mergePrefix(prefix, with: generated)
    }

    private func mergePrefix(_ prefix: [TranscriptSegment], with generated: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !prefix.isEmpty else { return removeDuplicateBoundaries(generated) }
        guard let firstGenerated = generated.first else { return prefix }
        var result = prefix.filter { ($0.end ?? $0.start) <= firstGenerated.start + 0.05 }
        while let last = result.last,
              normalized(last.text) == normalized(firstGenerated.text),
              abs(last.start - firstGenerated.start) < 1 {
            result.removeLast()
        }
        result.append(contentsOf: generated)
        return removeDuplicateBoundaries(result)
    }

    private func removeDuplicateBoundaries(_ input: [TranscriptSegment]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for segment in input.sorted(by: { $0.start < $1.start }) {
            if let previous = output.last,
               normalized(previous.text) == normalized(segment.text),
               abs(previous.start - segment.start) < 1.5 {
                let end = max(previous.end ?? previous.start, segment.end ?? segment.start)
                output[output.count - 1] = TranscriptSegment(id: previous.id,
                                                             start: min(previous.start, segment.start),
                                                             end: end,
                                                             text: previous.text,
                                                             translation: previous.translation)
            } else {
                output.append(segment)
            }
        }
        return output
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

private enum ScribeChunkWorker {
    static func process(descriptor: ScribeChunkDescriptor,
                        language: String,
                        rateLimiter: ScribeRateLimiter) async throws -> ScribeChunkRecord {
        try Task.checkCancellation()
        let uploadURL: URL
        let shouldRemoveUpload: Bool
        if descriptor.start < 0.01, abs(descriptor.end - descriptor.sourceDuration) < 0.01 {
            uploadURL = descriptor.audioURL
            shouldRemoveUpload = false
        } else {
            uploadURL = try await export(descriptor)
            shouldRemoveUpload = true
        }
        defer { if shouldRemoveUpload { try? FileManager.default.removeItem(at: uploadURL) } }

        let response = try await uploadWithRetry(uploadURL, language: language, rateLimiter: rateLimiter)
        let offsetWords = response.words.map { word -> ScribeWordToken in
            var value = word
            value.start = word.start.map { roundedMilliseconds($0 + descriptor.start) }
            value.end = word.end.map { roundedMilliseconds($0 + descriptor.start) }
            return value
        }
        return ScribeChunkRecord(index: descriptor.index,
                                 start: descriptor.start,
                                 end: descriptor.end,
                                 languageCode: response.languageCode,
                                 words: offsetWords)
    }

    private static func export(_ descriptor: ScribeChunkDescriptor) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeChunk-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: descriptor.audioURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ScribeTranscriptionError.audioExportFailed("无法创建 M4A 导出器")
        }
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: descriptor.start, preferredTimescale: 600),
                                         end: CMTime(seconds: descriptor.end, preferredTimescale: 600))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: ScribeTranscriptionError.audioExportFailed(exporter.error?.localizedDescription ?? "未知错误"))
                }
            }
        }
        guard let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw ScribeTranscriptionError.audioExportFailed("导出的分片为空")
        }
        return output
    }

    private static func uploadWithRetry(_ audioURL: URL,
                                        language: String,
                                        rateLimiter: ScribeRateLimiter) async throws -> ScribeResponse {
        let maximumAttempts = 10
        var lastError: Error = ScribeTranscriptionError.invalidResponse
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            do {
                try await rateLimiter.acquire()
                return try await upload(audioURL, language: language)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let retryable = (error as? ScribeTranscriptionError)?.isRetryable ?? isTransient(error)
                guard retryable, attempt + 1 < maximumAttempts else { throw error }
                let exponential = min(60.0, pow(2.0, Double(attempt)))
                let jitter = Double.random(in: 0...0.75)
                try await Task.sleep(nanoseconds: UInt64((exponential + jitter) * 1_000_000_000))
            }
        }
        throw lastError
    }

    private static func upload(_ audioURL: URL, language: String) async throws -> ScribeResponse {
        let boundary = "----Scribe2SRT\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let bodyURL = try makeMultipartBody(audioURL: audioURL, boundary: boundary, language: language)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        components.queryItems = [URLQueryItem(name: "allow_unauthenticated", value: "1")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 * 60
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://elevenlabs.io", forHTTPHeaderField: "Origin")
        request.setValue("https://elevenlabs.io/", forHTTPHeaderField: "Referer")
        request.setValue(randomUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(randomAcceptLanguage(), forHTTPHeaderField: "Accept-Language")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let address = randomPublicIPv4()
        request.setValue("for=\(address)", forHTTPHeaderField: "Forwarded")
        request.setValue(address, forHTTPHeaderField: "X-Forwarded-For")
        request.setValue(address, forHTTPHeaderField: "X-Real-IP")
        request.setValue(address, forHTTPHeaderField: "CF-Connecting-IP")
        request.setValue(address, forHTTPHeaderField: "True-Client-IP")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else { throw ScribeTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = responseMessage(data).prefix(500)
            let retryable = http.statusCode == 408 || http.statusCode == 409 || http.statusCode == 425 || http.statusCode == 429 || (500...599).contains(http.statusCode)
            throw ScribeTranscriptionError.uploadFailed(status: http.statusCode,
                                                        message: String(message),
                                                        retryable: retryable)
        }
        do { return try JSONDecoder().decode(ScribeResponse.self, from: data) }
        catch { throw ScribeTranscriptionError.invalidResponse }
    }

    private static func makeMultipartBody(audioURL: URL, boundary: String, language: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeBody-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ScribeTranscriptionError.multipartCreationFailed
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            func write(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
            func field(_ name: String, _ value: String) throws {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            try field("model_id", "scribe_v2")
            try field("diarize", "true")
            try field("tag_audio_events", "true")
            try field("timestamps_granularity", "word")
            if !language.isEmpty, language.lowercased() != "auto" { try field("language_code", language) }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: \(mimeType(audioURL))\r\n\r\n")
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                let data = try input.read(upToCount: 512 * 1024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try write("\r\n--\(boundary)--\r\n")
            try output.synchronize()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "aac": return "audio/aac"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private static func responseMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { return detail }
            if let message = object["message"] as? String { return message }
            if let detail = object["detail"] { return String(describing: detail) }
        }
        return String(data: data, encoding: .utf8) ?? "服务没有返回错误详情"
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                .internationalRoamingOff, .callIsActive, .dataNotAllowed].contains(error.code)
    }

    private static func roundedMilliseconds(_ value: TimeInterval) -> TimeInterval {
        (value * 1_000).rounded() / 1_000
    }

    private static func randomUserAgent() -> String {
        [
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Version/15.0 Mobile/15E148 Safari/604.1"
        ].randomElement()!
    }

    private static func randomAcceptLanguage() -> String {
        ["zh-CN,zh;q=0.9,en;q=0.8", "en-US,en;q=0.9", "en-GB,en;q=0.9", "ja-JP,ja;q=0.9,en;q=0.8", "ko-KR,ko;q=0.9,en;q=0.8"].randomElement()!
    }

    private static func randomPublicIPv4() -> String {
        while true {
            let first = Int.random(in: 1...223)
            let second = Int.random(in: 0...255)
            let third = Int.random(in: 0...255)
            let fourth = Int.random(in: 1...254)
            if first == 10 || first == 127 || first >= 224 { continue }
            if first == 172 && (16...31).contains(second) { continue }
            if first == 192 && second == 168 { continue }
            if first == 169 && second == 254 { continue }
            return "\(first).\(second).\(third).\(fourth)"
        }
    }
}

private actor ScribeRateLimiter {
    let maximumRequests: Int
    let interval: TimeInterval
    private var requestDates: [Date] = []

    init(maximumRequests: Int, interval: TimeInterval) {
        self.maximumRequests = maximumRequests
        self.interval = interval
    }

    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            requestDates.removeAll { now.timeIntervalSince($0) >= interval }
            if requestDates.count < maximumRequests {
                requestDates.append(now)
                return
            }
            guard let first = requestDates.first else { continue }
            let wait = max(0.05, interval - now.timeIntervalSince(first))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

private enum ScribeChunkCache {
    static func load(episodeID: String) -> [ScribeChunkRecord] {
        let folder = directory(episodeID: episodeID)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(ScribeChunkRecord.self, from: $0) }
            .sorted { $0.index < $1.index }
    }

    static func save(_ record: ScribeChunkRecord, episodeID: String) throws {
        let folder = directory(episodeID: episodeID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(String(format: "%05d.json", record.index))
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
    }

    static func clear(episodeID: String) {
        try? FileManager.default.removeItem(at: directory(episodeID: episodeID))
    }

    private static func directory(episodeID: String) -> URL {
        let encoded = Data(episodeID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("ScribeChunks", isDirectory: true)
            .appendingPathComponent(String(encoded.prefix(120)), isDirectory: true)
    }
}
