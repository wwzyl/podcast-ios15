import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var podcasts: [Podcast] = []
    @Published private(set) var vocabulary: [VocabularyItem] = []
    @Published var importedTranscript: [TranscriptSegment]?
    @Published var importMessage: String?
    @Published var targetLanguage = "zh-Hans" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }

    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    init() {
        targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "zh-Hans"
        podcasts = load([Podcast].self, name: "podcasts.json") ?? []
        vocabulary = load([VocabularyItem].self, name: "vocabulary.json") ?? []
    }

    func subscribe(feedURL: URL) async throws {
        let podcast = try await RSSService().load(feedURL: feedURL)
        if let index = podcasts.firstIndex(where: { $0.feedURL == feedURL }) {
            podcasts[index] = podcast
        } else {
            podcasts.insert(podcast, at: 0)
        }
        savePodcasts()
    }

    func refresh(_ podcast: Podcast) async throws {
        try await subscribe(feedURL: podcast.feedURL)
    }

    func remove(_ podcast: Podcast) {
        podcasts.removeAll { $0.id == podcast.id }
        savePodcasts()
    }

    func addVocabulary(_ item: VocabularyItem) {
        if let index = vocabulary.firstIndex(where: { $0.word.caseInsensitiveCompare(item.word) == .orderedSame && $0.sentence == item.sentence }) {
            vocabulary[index] = item
        } else {
            vocabulary.insert(item, at: 0)
        }
        saveVocabulary()
    }

    func removeVocabulary(at offsets: IndexSet) {
        vocabulary.remove(atOffsets: offsets)
        saveVocabulary()
    }

    func clearVocabulary() {
        vocabulary.removeAll()
        saveVocabulary()
    }

    func importFile(_ url: URL) {
        let allowed = ["srt", "vtt", "json"]
        guard allowed.contains(url.pathExtension.lowercased()) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            importedTranscript = try TranscriptService.parse(data: Data(contentsOf: url), type: url.pathExtension)
            importMessage = "已导入 \(importedTranscript?.count ?? 0) 条文本"
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func savePodcasts() { save(podcasts, name: "podcasts.json") }
    private func saveVocabulary() { save(vocabulary, name: "vocabulary.json") }

    private func documentURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name)
    }

    private func save<T: Encodable>(_ value: T, name: String) {
        guard let url = documentURL(name), let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = documentURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

