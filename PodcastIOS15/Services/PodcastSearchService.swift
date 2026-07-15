import Foundation

struct PodcastSearchService {
    private struct Response: Decodable { let results: [PodcastSearchResult] }
    private struct PopularResponse: Decodable {
        struct Feed: Decodable {
            struct Item: Decodable { let id: String }
            let results: [Item]
        }
        let feed: Feed
    }

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

    func popular(limitPerCountry: Int = 15) async throws -> [PodcastSearchResult] {
        async let china = popular(country: "cn", limit: limitPerCountry)
        async let unitedStates = popular(country: "us", limit: limitPerCountry)
        let groups = [(try? await china) ?? [], (try? await unitedStates) ?? []]
        var seen: Set<String> = []
        let combined = groups.flatMap { $0 }.filter { seen.insert($0.feedUrl.lowercased()).inserted }
        if !combined.isEmpty { return combined }
        return try await search("英语学习", country: "CN")
    }

    private func popular(country: String, limit: Int) async throws -> [PodcastSearchResult] {
            let chartURL = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country.lowercased())/podcasts/top/\(limit)/podcasts.json")!
            let (chartData, chartResponse) = try await URLSession.shared.data(from: chartURL)
            try validate(chartResponse)
            let chart = try JSONDecoder().decode(PopularResponse.self, from: chartData)
            let ids = chart.feed.results.map(\.id)
            guard !ids.isEmpty else { throw URLError(.zeroByteResource) }
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                URLQueryItem(name: "entity", value: "podcast"),
                URLQueryItem(name: "country", value: country)
            ]
            let (lookupData, lookupResponse) = try await URLSession.shared.data(from: components.url!)
            try validate(lookupResponse)
            let values = try JSONDecoder().decode(Response.self, from: lookupData).results.filter { !$0.feedUrl.isEmpty }
            let byID = Dictionary(uniqueKeysWithValues: values.compactMap { item in item.collectionId.map { ($0, item) } })
            return ids.compactMap { Int($0).flatMap { byID[$0] } }
    }
}

func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
}
