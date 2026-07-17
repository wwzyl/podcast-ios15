import Foundation

struct ApplePodcastTranscriptService {
    private let tokenPage = URL(string: "https://www.apple.com/apple-podcasts/")!
    private let transcriptTokenURL = URL(string: "https://sf-api-token-service.itunes.apple.com/apiToken?clientClass=apple&clientId=com.apple.podcasts.macos&os=OS%20X&osVersion=26.1&productVersion=1.1.0&version=2")!
    private let ampBaseURL = "https://amp.josscii.top/v1/catalog/us"
    private let transcriptRequestTimestamp = "2025-12-12T10:01:02Z"
    private let transcriptStorefront = "143465-19,42 t:podcasts1"
    private let transcriptActionSignature = [
        "Aq9HDM432en0ARuPy8y3XaZIRq+AUn1wo4lSVR1gtq9XAAAB0AMAAAABAAABAIpWWhi9cLSe56os64UsS93Ue3Eh+ryXKDuOxypy",
        "hH2+gVHHnqtvzls1BuMig3FKQ2mBnyR8s73aW5qpUNXdiDQnQBhzvkr9Sv7rFZFak1VdYNcqR2ou8AiHuaJKtTPRnbmdD/3ukpQy",
        "rfBSCLiEFs806ockTYRF7Kq01pupgixUuMir8qZIkUaHBcG/sxBaM7gV86M6mBmU34ELxxd6cnhIIV0CCSoH9aMfD0aGmLveNfo1",
        "m+Z5uJTlI9btFuikdtNDe+kkHDuMivEocrUmiO9ycWCPCm76guX9sggjexvoniQ8jZw+4O5y2ENHKrBVfirYYovrBBFMidA/byD8",
        "Q0YAAAAfQGlWB7+aN4g4IHYyPRMnxSevbnT9byQbZ4M+YE5zWQAAAJ8BgVGjNVGSjwOXXgb2Ht8lG/mWl/gAAACGAAP/+3a7FWKQ",
        "3B0gjOvK0ng+aTvns5Lej8O9bvWJJY1SR522QevROcOaEy8yL3jCAUVSLhvJPAScJw6Y0WIY6jabCHWYOX88OnfkCR+v6OBOw4v2",
        "4D6KniJh5bp8ftbUWMfYmARKX4F1JFUfXtPEJ3IeJVomhUSv2zc3wJYonytx7kA0YFQA"
    ].joined()

    func load(for episode: Episode) async throws -> [TranscriptSegment] {
        let episodeID: String
        if let knownEpisodeID = episode.appleEpisodeID, !knownEpisodeID.isEmpty {
            episodeID = knownEpisodeID
        } else {
            let catalogToken = try await applePodcastToken()
            guard let resolvedEpisodeID = try await resolveAppleEpisodeID(for: episode, token: catalogToken) else {
                throw TranscriptError.empty
            }
            episodeID = resolvedEpisodeID
        }
        let transcriptToken = try await appleTranscriptToken()
        let asset = try await transcriptAsset(for: episodeID, token: transcriptToken)
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 30
        request.setValue("Aisten/6.3.5 PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(asset.token ?? transcriptToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try TranscriptService.parse(data: data, type: asset.type)
    }

    private func applePodcastToken() async throws -> String {
        var request = URLRequest(url: tokenPage)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let html = String(data: data, encoding: .utf8),
              let token = html.firstMatch(#"apple-podcast-token"\s+content="([^"]+)""#) else {
            throw TranscriptError.empty
        }
        return token
    }

    private func appleTranscriptToken() async throws -> String {
        var request = URLRequest(url: transcriptTokenURL)
        request.timeoutInterval = 30
        request.setValue("Aisten/6.3.5", forHTTPHeaderField: "User-Agent")
        request.setValue(transcriptRequestTimestamp, forHTTPHeaderField: "x-request-timestamp")
        request.setValue(transcriptActionSignature, forHTTPHeaderField: "X-Apple-ActionSignature")
        request.setValue(transcriptStorefront, forHTTPHeaderField: "X-Apple-Store-Front")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(AppleTranscriptTokenResponse.self, from: data)
        guard !decoded.token.isEmpty else { throw TranscriptError.empty }
        return decoded.token
    }

    private func resolveAppleEpisodeID(for episode: Episode, token: String) async throws -> String? {
        if let id = episode.appleEpisodeID, !id.isEmpty { return id }
        guard let podcastID = episode.applePodcastID else { return nil }
        var components = URLComponents(string: "\(ampBaseURL)/podcasts/\(podcastID)/episodes")!
        components.queryItems = [
            URLQueryItem(name: "include", value: "channel,podcast"),
            URLQueryItem(name: "limit", value: "300"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "with", value: "entitlements,transcripts"),
            URLQueryItem(name: "l", value: "en-US")
        ]
        let data = try await ampData(url: components.url!, token: token)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return nil }
        let scored = items.compactMap { item -> (id: String, score: Int)? in
            guard let id = item["id"] as? String,
                  let attributes = item["attributes"] as? [String: Any] else { return nil }
            let score = matchScore(attributes: attributes, episode: episode)
            return score > 0 ? (id, score) : nil
        }.sorted { $0.score > $1.score }
        return scored.first { $0.score >= 5 }?.id
    }

    private func transcriptAsset(for episodeID: String, token: String) async throws -> (url: URL, token: String?, type: String) {
        let url = URL(string: "\(ampBaseURL)/podcast-episodes/\(episodeID)/transcripts?fields=ttmlToken,ttmlAssetUrls&include[podcast-episodes]=podcast&l=en&with=entitlements")!
        let data = try await ampData(url: url, token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let urlString = Self.findTTMLAssetURL(in: object),
              let url = URL(string: urlString) else {
            throw TranscriptError.empty
        }
        let assetToken = Self.findString(in: object, key: "ttmlToken")
        return (url, assetToken, "ttml")
    }

    private func ampData(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Aisten/6.3.5 PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard !data.isEmpty else { throw TranscriptError.empty }
        return data
    }

    private func matchScore(attributes: [String: Any], episode: Episode) -> Int {
        var score = 0
        let title = normalized(episode.title)
        let candidates = [
            attributes["name"] as? String,
            attributes["itunesTitle"] as? String,
            attributes["title"] as? String
        ].compactMap { $0 }.map { normalized($0) }
        if candidates.contains(title) {
            score += 6
        } else if candidates.contains(where: { !$0.isEmpty && (title.contains($0) || $0.contains(title)) }) {
            score += 4
        }
        if let guid = attributes["guid"] as? String, guid == episode.id {
            score += 3
        }
        if let duration = episode.duration,
           let milliseconds = attributes["durationInMilliseconds"] as? Double,
           abs(milliseconds / 1_000 - duration) <= 5 {
            score += 2
        }
        if let publishedAt = episode.publishedAt,
           let raw = attributes["releaseDateTime"] as? String,
           let release = ISO8601DateFormatter().date(from: raw),
           abs(release.timeIntervalSince(publishedAt)) <= 86_400 {
            score += 2
        }
        return score
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findString(in object: Any, key: String) -> String? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] as? String { return value }
            if let values = dict[key] as? [String: Any] {
                if let direct = values["url"] as? String { return direct }
                if let ttml = values["ttml"] as? String { return ttml }
            }
            for value in dict.values {
                if let match = findString(in: value, key: key) { return match }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findString(in: value, key: key) { return match }
            }
        }
        return nil
    }

    private static func findTTMLAssetURL(in object: Any) -> String? {
        if let direct = findString(in: object, key: "ttml") {
            return direct
        }
        if let dict = object as? [String: Any] {
            if let assetURLs = dict["ttmlAssetUrls"], let value = firstHTTPURL(in: assetURLs) {
                return value
            }
            for value in dict.values {
                if let match = findTTMLAssetURL(in: value) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findTTMLAssetURL(in: value) {
                    return match
                }
            }
        }
        return nil
    }

    private static func firstHTTPURL(in object: Any) -> String? {
        if let value = object as? String, value.hasPrefix("http") {
            return value
        }
        if let dict = object as? [String: Any] {
            for key in ["url", "ttml", "href", "assetUrl", "assetURL"] {
                if let value = dict[key] as? String, value.hasPrefix("http") {
                    return value
                }
            }
            for value in dict.values {
                if let match = firstHTTPURL(in: value) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = firstHTTPURL(in: value) {
                    return match
                }
            }
        }
        return nil
    }
}

private struct AppleTranscriptTokenResponse: Decodable {
    let token: String
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
