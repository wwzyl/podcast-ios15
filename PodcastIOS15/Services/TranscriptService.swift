import Foundation

enum TranscriptError: LocalizedError {
    case unsupported, empty
    var errorDescription: String? {
        switch self { case .unsupported: return "不支持的文本格式"; case .empty: return "没有解析到带时间的文本" }
    }
}

struct TranscriptService {
    func load(for episode: Episode) async throws -> [TranscriptSegment] {
        guard let url = episode.transcriptURL else {
            throw TranscriptError.empty
        }
        var request = URLRequest(url: url)
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try Self.parse(data: data, type: episode.transcriptType ?? url.pathExtension)
    }

    static func parse(data: Data, type: String) throws -> [TranscriptSegment] {
        let lower = type.lowercased()
        if lower.contains("json") { return try parseJSON(data) }
        guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw TranscriptError.unsupported }
        let result = lower.contains("vtt") || value.hasPrefix("WEBVTT") ? parseVTT(value) : parseSRT(value)
        guard !result.isEmpty else { throw TranscriptError.empty }
        return result
    }

    private static func parseSRT(_ source: String) -> [TranscriptSegment] {
        source.normalizedLines.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timing].components(separatedBy: "-->")
            guard let start = parseTimestamp(times.first ?? "") else { return nil }
            let end = times.count > 1 ? parseTimestamp(times[1]) : nil
            let text = lines.dropFirst(timing + 1).joined(separator: " ").strippingTags
            return text.isEmpty ? nil : TranscriptSegment(start: start, end: end, text: text)
        }
    }

    private static func parseVTT(_ source: String) -> [TranscriptSegment] {
        parseSRT(source.replacingOccurrences(of: "WEBVTT", with: ""))
    }

    private static func parseJSON(_ data: Data) throws -> [TranscriptSegment] {
        let object = try JSONSerialization.jsonObject(with: data)
        let array: [[String: Any]]
        if let direct = object as? [[String: Any]] { array = direct }
        else if let dict = object as? [String: Any], let segments = dict["segments"] as? [[String: Any]] { array = segments }
        else { throw TranscriptError.unsupported }
        let result = array.compactMap { item -> TranscriptSegment? in
            let text = (item["text"] as? String ?? item["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = number(item["startTime"] ?? item["start"] ?? item["offset"]) ?? 0
            let end = number(item["endTime"] ?? item["end"])
            return TranscriptSegment(start: start, end: end, text: text)
        }
        guard !result.isEmpty else { throw TranscriptError.empty }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) ?? parseTimestamp(value) }
        return nil
    }

    private static func parseTimestamp(_ source: String) -> TimeInterval? {
        let clean = source.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? source
        let parts = clean.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}

private extension String {
    var normalizedLines: String { replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    var strippingTags: String { replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}
