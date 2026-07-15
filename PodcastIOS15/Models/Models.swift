import Foundation

struct Podcast: Identifiable, Codable, Hashable {
    var id: String { feedURL.absoluteString }
    let title: String
    let author: String
    let summary: String
    let artworkURL: URL?
    let feedURL: URL
    var episodes: [Episode]
}

struct Episode: Identifiable, Codable, Hashable {
    let id: String
    let podcastTitle: String
    let title: String
    let summary: String
    let publishedAt: Date?
    let duration: TimeInterval?
    let audioURL: URL
    let artworkURL: URL?
    let transcriptURL: URL?
    let transcriptType: String?
}

struct TranscriptSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval?
    let text: String
    var translation: String?

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval? = nil, text: String, translation: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
    }
}

struct VocabularyItem: Identifiable, Codable, Hashable {
    let id: UUID
    var word: String
    var definition: String
    var translation: String
    var sentence: String
    var sentenceTranslation: String
    var podcastTitle: String
    var episodeTitle: String
    var timestamp: TimeInterval
    var createdAt: Date

    init(id: UUID = UUID(), word: String, definition: String = "", translation: String = "", sentence: String, sentenceTranslation: String = "", podcastTitle: String, episodeTitle: String, timestamp: TimeInterval, createdAt: Date = Date()) {
        self.id = id
        self.word = word
        self.definition = definition
        self.translation = translation
        self.sentence = sentence
        self.sentenceTranslation = sentenceTranslation
        self.podcastTitle = podcastTitle
        self.episodeTitle = episodeTitle
        self.timestamp = timestamp
        self.createdAt = createdAt
    }
}

struct PodcastSearchResult: Identifiable, Codable {
    let collectionId: Int?
    let collectionName: String
    let artistName: String
    let feedUrl: String
    let artworkUrl600: String?

    var id: String { feedUrl }
}

extension TimeInterval {
    var clockString: String {
        guard isFinite && self >= 0 else { return "0:00" }
        let value = Int(self)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}
