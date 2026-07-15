import Foundation
import AVFoundation

enum ElevenLabsTranscriptionError: LocalizedError {
    case audioExportFailed, uploadFailed(String), invalidResponse, noSpeech
    var errorDescription: String? {
        switch self {
        case .audioExportFailed: return "ElevenLabs 分片音频生成失败"
        case .uploadFailed(let message): return "ElevenLabs 转录失败：\(message)"
        case .invalidResponse: return "ElevenLabs 返回的数据无法解析"
        case .noSpeech: return "ElevenLabs 没有识别到语音"
        }
    }
}

actor ElevenLabsTranscriber {
    static let shared = ElevenLabsTranscriber()
    private let chunkDuration: TimeInterval = 40 * 60
    private let maxRetries = 4

    func transcribeStream(audioURL: URL, episode: Episode, language: String = "auto") -> AsyncThrowingStream<TranscriptionBatch, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.run(audioURL: audioURL, episode: episode, language: language, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func run(audioURL: URL, episode: Episode, language: String, continuation: AsyncThrowingStream<TranscriptionBatch, Error>.Continuation) async throws {
        let asset = AVURLAsset(url: audioURL)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { throw ElevenLabsTranscriptionError.audioExportFailed }
        var allSegments = TranscriptCache.load(episodeID: episode.id) ?? []
        let cachedEnd = allSegments.last?.end ?? allSegments.last?.start ?? 0
        var cursor = min(duration, max(cachedEnd, TranscriptCache.resumeTime(episodeID: episode.id) ?? 0))
        if !allSegments.isEmpty, cursor >= duration - 0.25 {
            try TranscriptCache.markComplete(episodeID: episode.id)
            return
        }

        while cursor < duration - 0.05 {
            try Task.checkCancellation()
            let end = min(duration, cursor + chunkDuration)
            let chunkURL = try await exportChunk(asset: asset, start: cursor, end: end)
            let response: ElevenResponse
            do {
                response = try await uploadWithRetry(chunkURL, language: language)
            } catch {
                try? FileManager.default.removeItem(at: chunkURL)
                throw error
            }
            try? FileManager.default.removeItem(at: chunkURL)
            let basic = ElevenSentenceProcessor.segments(from: response.words, offset: cursor)
            let sentences = ElevenSentenceProcessor.optimize(basic, language: response.languageCode)
            guard !sentences.isEmpty else { throw ElevenLabsTranscriptionError.noSpeech }
            allSegments.append(contentsOf: sentences)
            try TranscriptCache.save(allSegments, episodeID: episode.id)
            continuation.yield(TranscriptionBatch(segments: sentences, progress: min(1, end / duration)))
            cursor = end
            try TranscriptCache.setResumeTime(cursor, episodeID: episode.id)
        }
        guard !allSegments.isEmpty else { throw ElevenLabsTranscriptionError.noSpeech }
        try TranscriptCache.save(allSegments, episodeID: episode.id)
        try TranscriptCache.markComplete(episodeID: episode.id)
    }

    private func exportChunk(asset: AVAsset, start: TimeInterval, end: TimeInterval) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ElevenLabs-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ElevenLabsTranscriptionError.audioExportFailed
        }
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                         end: CMTime(seconds: end, preferredTimescale: 600))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: exporter.error ?? ElevenLabsTranscriptionError.audioExportFailed)
                }
            }
        }
        return output
    }

    private func uploadWithRetry(_ audioURL: URL, language: String) async throws -> ElevenResponse {
        var lastError: Error = ElevenLabsTranscriptionError.invalidResponse
        for attempt in 0..<maxRetries {
            try Task.checkCancellation()
            do { return try await upload(audioURL, language: language) }
            catch {
                lastError = error
                if attempt + 1 < maxRetries {
                    let delay = UInt64(1 << attempt) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError
    }

    private func upload(_ audioURL: URL, language: String) async throws -> ElevenResponse {
        let boundary = "----PodcastIOS15\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
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
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Version/15.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else { throw ElevenLabsTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? "HTTP \(http.statusCode)"
            throw ElevenLabsTranscriptionError.uploadFailed("HTTP \(http.statusCode)：\(detail)")
        }
        do { return try JSONDecoder().decode(ElevenResponse.self, from: data) }
        catch { throw ElevenLabsTranscriptionError.invalidResponse }
    }

    private func makeMultipartBody(audioURL: URL, boundary: String, language: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ElevenLabsBody-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func write(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try field("model_id", "scribe_v2")
        try field("diarize", "true")
        try field("tag_audio_events", "false")
        try field("timestamps_granularity", "word")
        if !language.isEmpty, language.lowercased() != "auto" { try field("language_code", language) }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
        try write("\r\n--\(boundary)--\r\n")
        return destination
    }
}

private struct ElevenResponse: Decodable {
    let languageCode: String?
    let words: [ElevenWord]
    enum CodingKeys: String, CodingKey { case languageCode = "language_code", words }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        words = try container.decodeIfPresent([ElevenWord].self, forKey: .words) ?? []
    }
}

private struct ElevenWord: Decodable {
    let text: String
    let type: String
    let start: TimeInterval?
    let end: TimeInterval?
}

private enum ElevenSentenceProcessor {
    static func segments(from words: [ElevenWord], offset: TimeInterval) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var text = ""
        var firstStart: TimeInterval?
        var lastEnd: TimeInterval?
        var wordCount = 0
        for (index, word) in words.enumerated() {
            if word.type == "audio_event" { continue }
            if word.type == "spacing" {
                if word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.hasSuffix(" ") { text += " " }
                else { text += word.text }
                continue
            }
            text += word.text
            if let start = word.start, firstStart == nil { firstStart = start }
            if let end = word.end { lastEnd = end }
            wordCount += 1
            let priority = punctuationPriority(word.text.last)
            let split = priority == 0 || (priority == 1 && wordCount - 1 >= 3) || (priority == 2 && wordCount - 1 >= 5)
            let isLast = index == words.count - 1
            if split || isLast {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let start = firstStart, let end = lastEnd, !clean.isEmpty {
                    result.append(TranscriptSegment(start: offset + start, end: offset + end, text: clean))
                }
                text = ""; firstStart = nil; lastEnd = nil; wordCount = 0
            }
        }
        return result
    }

    static func optimize(_ input: [TranscriptSegment], language: String?) -> [TranscriptSegment] {
        guard !input.isEmpty else { return [] }
        let code = language?.lowercased() ?? ""
        let cjk = code.hasPrefix("zh") || code.hasPrefix("zho") || code.hasPrefix("ja") || code.hasPrefix("jpn") || code.hasPrefix("ko") || code.hasPrefix("kor")
        let cpsLimit = cjk ? 11.0 : 15.0
        let lineLimit = cjk ? 25 : 42
        var merged: [TranscriptSegment] = []
        for segment in input {
            guard let previous = merged.last else { merged.append(adjust(segment)); continue }
            let previousEnd = previous.end ?? previous.start
            let segmentEnd = segment.end ?? segment.start
            let gap = segment.start - previousEnd
            let joined = joinsWithoutSpace(previous.text) || cjk ? previous.text + segment.text : previous.text + " " + segment.text
            let duration = segmentEnd - previous.start
            let chars = joined.filter { !$0.isWhitespace }.count
            let canMerge = gap >= 0.083 && gap <= 2 && duration <= 6 && Double(chars) / max(duration, 0.1) <= dynamicLimit(chars, base: cpsLimit) && chars <= lineLimit * 2
            if canMerge && mergeBenefit(previous, segment, gap: gap) > 5 {
                merged[merged.count - 1] = adjust(TranscriptSegment(id: previous.id, start: previous.start, end: segment.end, text: joined))
            } else {
                merged.append(adjust(segment))
            }
        }
        return merged
    }

    private static func adjust(_ value: TranscriptSegment) -> TranscriptSegment {
        let naturalEnd = value.end ?? value.start
        let end = min(value.start + 7, max(naturalEnd, value.start + 0.83))
        return TranscriptSegment(id: value.id, start: value.start, end: end, text: value.text)
    }
    private static func mergeBenefit(_ first: TranscriptSegment, _ second: TranscriptSegment, gap: TimeInterval) -> Double {
        var score = 0.0
        let firstDuration = (first.end ?? first.start) - first.start
        let secondDuration = (second.end ?? second.start) - second.start
        if firstDuration < 0.83 { score += (0.83 - firstDuration) * 20 }
        if secondDuration < 0.83 { score += (0.83 - secondDuration) * 20 }
        if gap < 0.3 { score += (0.3 - gap) * 10 } else if gap < 0.5 { score += (0.5 - gap) * 5 }
        score += shortScore(first.text) + shortScore(second.text)
        return score
    }
    private static func shortScore(_ text: String) -> Double {
        let count = text.filter { !$0.isWhitespace }.count
        if count < 3 { return Double(3 - count) * 5 }
        if count < 8 { return Double(8 - count) * 2 }
        return 0
    }
    private static func dynamicLimit(_ count: Int, base: Double) -> Double {
        if count <= 3 { return base * 3 }; if count <= 5 { return base * 2 }; if count <= 10 { return base * 1.5 }; return base
    }
    private static func joinsWithoutSpace(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。？！、，；：\"'（）《》「」『』?!,;:()\"'-".contains(last)
    }
    private static func punctuationPriority(_ character: Character?) -> Int {
        guard let character else { return -1 }
        if ".!?。？！".contains(character) { return 0 }
        if ";:)]}；：」』》）".contains(character) { return 1 }
        if ",([{…-，、「『《（".contains(character) { return 2 }
        return -1
    }
}
