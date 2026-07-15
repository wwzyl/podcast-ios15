import Foundation

struct PodcastSearchService {
    private struct Response: Decodable { let results: [PodcastSearchResult] }

    func search(_ query: String, country: String = "CN") async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "country", value: country)
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response)
        return try JSONDecoder().decode(Response.self, from: data).results.filter { !$0.feedUrl.isEmpty }
    }

    func artworkURL(feedURL: URL, title: String) async throws -> URL? {
        var candidates = (try? await search(title, country: "CN")) ?? []
        candidates.append(contentsOf: (try? await search(title, country: "US")) ?? [])
        let normalizedFeed = feedURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let match = candidates.first {
            $0.feedUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == normalizedFeed
        } ?? candidates.first {
            $0.collectionName.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } ?? candidates.first
        guard let value = match?.artworkUrl600 else {
            if candidates.isEmpty { throw URLError(.resourceUnavailable) }
            return nil
        }
        return URL(string: value)
    }
}

func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
}
