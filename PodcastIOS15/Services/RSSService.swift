import Foundation

struct RSSService {
    func load(feedURL: URL) async throws -> Podcast {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 30
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try RSSParser(data: data, feedURL: feedURL).parse()
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private struct Item {
        var guid = ""
        var title = ""
        var summary = ""
        var published = ""
        var duration = ""
        var audio = ""
        var artwork = ""
        var transcript = ""
        var transcriptType = ""
    }

    private let data: Data
    private let feedURL: URL
    private var currentKey = ""
    private var currentText = ""
    private var insideItem = false
    private var currentItem = Item()
    private var items: [Item] = []
    private var channelTitle = ""
    private var channelAuthor = ""
    private var channelSummary = ""
    private var channelArtwork = ""
    private var parseError: Error?

    init(data: Data, feedURL: URL) {
        self.data = data
        self.feedURL = feedURL
    }

    func parse() throws -> Podcast {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parseError ?? parser.parserError ?? URLError(.cannotParseResponse) }
        let artwork = makeURL(channelArtwork)
        let episodes = items.compactMap { item -> Episode? in
            guard let audio = makeURL(item.audio) else { return nil }
            let identifier = item.guid.isEmpty ? audio.absoluteString : item.guid
            return Episode(
                id: identifier,
                podcastTitle: channelTitle,
                title: item.title.plainText.fallback("未命名节目"),
                summary: item.summary.plainText,
                publishedAt: Self.parseDate(item.published),
                duration: Self.parseDuration(item.duration),
                audioURL: audio,
                artworkURL: makeURL(item.artwork) ?? artwork,
                transcriptURL: makeURL(item.transcript),
                transcriptType: item.transcriptType.isEmpty ? nil : item.transcriptType
            )
        }.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        return Podcast(title: channelTitle.plainText.fallback(feedURL.host ?? "Podcast"), author: channelAuthor.plainText, summary: channelSummary.plainText, artworkURL: artwork, feedURL: feedURL, episodes: episodes)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { self.parseError = parseError }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let key = (qName ?? elementName).lowercased()
        currentKey = key
        currentText = ""
        if key == "item" || key == "entry" {
            insideItem = true
            currentItem = Item()
        }
        if insideItem && (key == "enclosure" || key == "media:content") {
            currentItem.audio = attributeDict["url"] ?? currentItem.audio
        }
        if insideItem && key == "link" && attributeDict["rel"] == "enclosure" {
            currentItem.audio = attributeDict["href"] ?? currentItem.audio
        }
        if key == "podcast:transcript" && insideItem {
            currentItem.transcript = attributeDict["url"] ?? ""
            currentItem.transcriptType = attributeDict["type"] ?? ""
        }
        if key == "itunes:image" {
            if insideItem { currentItem.artwork = attributeDict["href"] ?? "" }
            else { channelArtwork = attributeDict["href"] ?? "" }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { currentText += String(data: CDATABlock, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let key = (qName ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem {
            switch key {
            case "guid", "id": currentItem.guid = text
            case "title": currentItem.title = text
            case "description", "content:encoded", "summary": if currentItem.summary.isEmpty { currentItem.summary = text }
            case "pubdate", "published", "updated": if currentItem.published.isEmpty { currentItem.published = text }
            case "itunes:duration": currentItem.duration = text
            case "link": if currentItem.audio.isEmpty && text.hasPrefix("http") { currentItem.audio = text }
            case "item", "entry": items.append(currentItem); insideItem = false
            default: break
            }
        } else {
            switch key {
            case "title": if channelTitle.isEmpty { channelTitle = text }
            case "itunes:author", "author", "dc:creator": if channelAuthor.isEmpty { channelAuthor = text }
            case "description", "subtitle": if channelSummary.isEmpty { channelSummary = text }
            default: break
            }
        }
        currentText = ""
    }

    private func makeURL(_ string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        return URL(string: string, relativeTo: feedURL)?.absoluteURL
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func parseDuration(_ value: String) -> TimeInterval? {
        if let seconds = Double(value) { return seconds }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}

private extension String {
    var plainText: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func fallback(_ value: String) -> String { isEmpty ? value : self }
}
