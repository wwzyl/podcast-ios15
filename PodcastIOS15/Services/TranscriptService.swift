import Foundation

enum TranscriptError: LocalizedError {
    case unsupported, empty
    var errorDescription: String? {
        switch self { case .unsupported: return "不支持的文本格式"; case .empty: return "没有解析到带时间的文本" }
    }
}

struct TranscriptService {
    func load(for episode: Episode) async throws -> [TranscriptSegment] {
        if let url = episode.transcriptURL {
            var request = URLRequest(url: url)
            request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            return try Self.parse(data: data, type: episode.transcriptType ?? url.pathExtension)
        }
        if let segments = try? await ApplePodcastTranscriptService().load(for: episode), !segments.isEmpty {
            return segments
        }
        // Treat episodes without a reachable RSS or Apple transcript as empty so
        // the player can present the manual transcription choices without an alert.
        throw TranscriptError.empty
    }

    static func parse(data: Data, type: String) throws -> [TranscriptSegment] {
        let lower = type.lowercased()
        if lower.contains("json") { return try parseJSON(data) }
        guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw TranscriptError.unsupported }
        let result: [TranscriptSegment]
        if lower.contains("ttml") || lower.contains("xml") || value.contains("<tt") {
            result = try TTMLTranscriptParser.parse(data)
        } else if lower.contains("vtt") || value.hasPrefix("WEBVTT") {
            result = parseVTT(value)
        } else {
            result = parseSRT(value)
        }
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
        else if let dict = object as? [String: Any], let transcript = dict["transcript"] as? [[String: Any]] { array = transcript }
        else if let dict = object as? [String: Any], let items = dict["items"] as? [[String: Any]] { array = items }
        else if let dict = object as? [String: Any], let captions = dict["captions"] as? [[String: Any]] { array = captions }
        else { throw TranscriptError.unsupported }
        let result = array.compactMap { item -> TranscriptSegment? in
            let text = (item["text"] as? String ?? item["body"] as? String ?? item["content"] as? String ?? item["caption"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = number(item["startTime"] ?? item["start"] ?? item["offset"] ?? item["from"]) ?? 0
            let end = number(item["endTime"] ?? item["end"] ?? item["to"])
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

private final class TTMLTranscriptParser: NSObject, XMLParserDelegate {
    private var segments: [TranscriptSegment] = []
    private var paragraphText = ""
    private var paragraphStart: TimeInterval?
    private var paragraphEnd: TimeInterval?
    private var insideParagraph = false
    private var parseError: Error?

    static func parse(_ data: Data) throws -> [TranscriptSegment] {
        let delegate = TTMLTranscriptParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw delegate.parseError ?? parser.parserError ?? TranscriptError.unsupported }
        guard !delegate.segments.isEmpty else { throw TranscriptError.empty }
        return delegate.segments
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { self.parseError = parseError }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).split(separator: ":").last?.lowercased() ?? ""
        if name == "p" {
            insideParagraph = true
            paragraphText = ""
            paragraphStart = Self.time(attributeDict["begin"] ?? attributeDict.first { $0.key.hasSuffix(":begin") }?.value)
            paragraphEnd = Self.time(attributeDict["end"] ?? attributeDict.first { $0.key.hasSuffix(":end") }?.value)
            if paragraphEnd == nil, let duration = Self.time(attributeDict["dur"]), let start = paragraphStart {
                paragraphEnd = start + duration
            }
        } else if insideParagraph, name == "br" {
            paragraphText += " "
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideParagraph { paragraphText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if insideParagraph { paragraphText += String(data: CDATABlock, encoding: .utf8) ?? "" }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).split(separator: ":").last?.lowercased() ?? ""
        guard name == "p", insideParagraph else { return }
        insideParagraph = false
        let text = paragraphText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = paragraphStart, !text.isEmpty {
            segments.append(TranscriptSegment(start: start, end: paragraphEnd, text: text))
        }
    }

    private static func time(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("ms"), let number = Double(value.dropLast(2)) { return number / 1_000 }
        if value.hasSuffix("s"), let number = Double(value.dropLast()) { return number }
        if value.hasSuffix("m"), let number = Double(value.dropLast()) { return number * 60 }
        if value.hasSuffix("h"), let number = Double(value.dropLast()) { return number * 3_600 }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}

private extension String {
    var normalizedLines: String { replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    var strippingTags: String { replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}
