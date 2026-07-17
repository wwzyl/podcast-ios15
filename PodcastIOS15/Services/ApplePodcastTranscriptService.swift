import Foundation

struct ApplePodcastTranscriptService {
    private let storefront = "us"

    func load(for episode: Episode) async throws -> [TranscriptSegment] {
        let token = try await apiToken()
        let episodeID = try await findEpisodeID(for: episode, token: token)
        let metadata = try await requestJSON(
            URL(string: "https://amp-api.podcasts.apple.com/v1/catalog/\(storefront)/podcast-episodes/\(episodeID)/transcripts")!,
            token: token)
        let candidates = transcriptCandidates(in: metadata)
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.timeoutInterval = 30
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let assetToken = candidate.assetToken {
                    request.setValue(assetToken, forHTTPHeaderField: "X-Apple-Transcript-Token")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                try validate(response)
                return try TranscriptService.parse(data: data, type: "ttml")
            } catch {
                continue
            }
        }
        throw TranscriptError.empty
    }

    private func apiToken() async throws -> String {
        var components = URLComponents(string: "https://sf-api-token-service.itunes.apple.com/apiToken")!
        components.queryItems = [
            URLQueryItem(name: "clientClass", value: "apple"),
            URLQueryItem(name: "clientId", value: "com.apple.podcasts.macos"),
            URLQueryItem(name: "os", value: "OS X"),
            URLQueryItem(name: "osVersion", value: "26.1"),
            URLQueryItem(name: "productVersion", value: "1.1.0"),
            URLQueryItem(name: "version", value: "2")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any] {
            for key in ["token", "accessToken", "apiToken"] {
                if let token = dictionary[key] as? String, !token.isEmpty { return token }
            }
        }
        if let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        throw URLError(.cannotParseResponse)
    }

    private func findEpisodeID(for episode: Episode, token: String) async throws -> String {
        var components = URLComponents(string: "https://amp-api.podcasts.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(episode.podcastTitle) \(episode.title)"),
            URLQueryItem(name: "types", value: "podcast-episodes"),
            URLQueryItem(name: "limit", value: "25")
        ]
        let object = try await requestJSON(components.url!, token: token)
        let records = dictionaries(in: object).filter { ($0["type"] as? String) == "podcast-episodes" }
        let targetEpisode = normalized(episode.title)
        let targetPodcast = normalized(episode.podcastTitle)
        let ranked = records.compactMap { record -> (String, Int)? in
            guard let id = record["id"] as? String else { return nil }
            let attributes = record["attributes"] as? [String: Any] ?? [:]
            let title = normalized(attributes["name"] as? String ?? attributes["title"] as? String ?? "")
            let podcast = normalized(attributes["podcastName"] as? String ?? attributes["showName"] as? String ?? "")
            var score = 0
            if title == targetEpisode { score += 8 }
            else if title.contains(targetEpisode) || targetEpisode.contains(title) { score += 4 }
            if podcast == targetPodcast { score += 4 }
            else if podcast.contains(targetPodcast) || targetPodcast.contains(podcast) { score += 2 }
            return (id, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 6 else { throw TranscriptError.empty }
        return best.0
    }

    private func requestJSON(_ url: URL, token: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Music/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func transcriptCandidates(in object: Any) -> [(url: URL, assetToken: String?)] {
        let token = firstString(named: ["ttmlToken", "token"], in: object)
        let urls = allStrings(in: object).compactMap(URL.init(string:)).filter {
            let value = $0.absoluteString.lowercased()
            return value.contains("ttml") || value.contains("transcript") || value.hasSuffix(".xml")
        }
        return Array(Set(urls)).map { ($0, token) }
    }

    private func dictionaries(in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap { dictionaries(in: $0) }
        }
        if let array = object as? [Any] { return array.flatMap { dictionaries(in: $0) } }
        return []
    }

    private func allStrings(in object: Any) -> [String] {
        if let string = object as? String { return [string] }
        if let dictionary = object as? [String: Any] { return dictionary.values.flatMap { allStrings(in: $0) } }
        if let array = object as? [Any] { return array.flatMap { allStrings(in: $0) } }
        return []
    }

    private func firstString(named names: Set<String>, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where names.contains(key) {
                if let value = value as? String { return value }
            }
            for value in dictionary.values {
                if let result = firstString(named: names, in: value) { return result }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let result = firstString(named: names, in: value) { return result }
            }
        }
        return nil
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9\\p{Han}]", with: "", options: .regularExpression)
    }
}
