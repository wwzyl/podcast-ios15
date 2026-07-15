import Foundation
import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var podcasts: [Podcast] = []
    @Published private(set) var vocabulary: [VocabularyItem] = []
    @Published var importedTranscript: [TranscriptSegment]?
    @Published var importMessage: String?
    @Published var targetLanguage = "zh-Hans" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    @Published var contextGPTEnabled = false { didSet { UserDefaults.standard.set(contextGPTEnabled, forKey: "contextGPTEnabled") } }
    @Published var contextGPTBaseURL = "https://api.openai.com/v1" { didSet { UserDefaults.standard.set(contextGPTBaseURL, forKey: "contextGPTBaseURL") } }
    @Published var contextGPTAPIKey = "" { didSet { UserDefaults.standard.set(contextGPTAPIKey, forKey: "contextGPTAPIKey") } }
    @Published var contextGPTModel = "gpt-4o-mini" { didSet { UserDefaults.standard.set(contextGPTModel, forKey: "contextGPTModel") } }
    private var repairingArtwork = false

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
        contextGPTEnabled = UserDefaults.standard.bool(forKey: "contextGPTEnabled")
        contextGPTBaseURL = UserDefaults.standard.string(forKey: "contextGPTBaseURL") ?? "https://api.openai.com/v1"
        contextGPTAPIKey = UserDefaults.standard.string(forKey: "contextGPTAPIKey") ?? ""
        contextGPTModel = UserDefaults.standard.string(forKey: "contextGPTModel") ?? "gpt-4o-mini"
        podcasts = load([Podcast].self, name: "podcasts.json") ?? []
        vocabulary = load([VocabularyItem].self, name: "vocabulary.json") ?? []
    }

    func subscribe(feedURL: URL, fallbackArtworkURL: URL? = nil) async throws {
        var podcast = try await RSSService().load(feedURL: feedURL)
        // Apple 搜索结果的封面通常比 RSS 中的旧 HTTP 地址更稳定。
        podcast.artworkURL = fallbackArtworkURL ?? podcast.artworkURL ?? podcast.episodes.compactMap(\.artworkURL).first
        if let index = podcasts.firstIndex(where: { $0.feedURL == feedURL }) {
            podcasts[index] = podcast
        } else {
            podcasts.insert(podcast, at: 0)
        }
        savePodcasts()
    }

    /// 为升级前已经收藏、但缺失或已经失效的频道封面补齐封面并持久化。
    func repairMissingArtwork() async {
        guard !repairingArtwork else { return }
        repairingArtwork = true
        defer { repairingArtwork = false }
        var changed = false
        for podcastID in podcasts.map(\.id) {
            guard let index = podcasts.firstIndex(where: { $0.id == podcastID }) else { continue }
            let podcast = podcasts[index]
            if let current = podcast.artworkURL, await artworkCanBeDisplayed(current) { continue }
            var resolved: URL?
            for candidate in podcast.episodes.compactMap(\.artworkURL) {
                if await artworkCanBeDisplayed(candidate) { resolved = candidate; break }
            }
            if resolved == nil {
                resolved = try? await PodcastSearchService().artworkURL(feedURL: podcast.feedURL, title: podcast.title)
            }
            if let resolved, let currentIndex = podcasts.firstIndex(where: { $0.id == podcastID }) {
                podcasts[currentIndex].artworkURL = resolved
                changed = true
            }
        }
        if changed { savePodcasts() }
    }

    private func artworkCanBeDisplayed(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return false }
        return UIImage(data: data) != nil
    }

    func refresh(_ podcast: Podcast) async throws {
        try await subscribe(feedURL: podcast.feedURL, fallbackArtworkURL: podcast.artworkURL)
    }

    func remove(_ podcast: Podcast) {
        podcasts.removeAll { $0.id == podcast.id }
        savePodcasts()
    }

    func addVocabulary(_ item: VocabularyItem) {
        if let index = vocabulary.firstIndex(where: { $0.word.caseInsensitiveCompare(item.word) == .orderedSame && $0.sentence == item.sentence }) {
            if vocabulary[index].audioClipFilename != item.audioClipFilename { AudioClipStore.remove(vocabulary[index].audioClipFilename) }
            vocabulary[index] = item
        } else {
            vocabulary.insert(item, at: 0)
        }
        saveVocabulary()
    }

    func removeVocabulary(at offsets: IndexSet) {
        for index in offsets where vocabulary.indices.contains(index) { AudioClipStore.remove(vocabulary[index].audioClipFilename) }
        vocabulary.remove(atOffsets: offsets)
        saveVocabulary()
    }

    func clearVocabulary() {
        vocabulary.removeAll()
        AudioClipStore.removeAll()
        saveVocabulary()
    }

    func audioClipURL(for item: VocabularyItem) -> URL? {
        guard let filename = item.audioClipFilename else { return nil }
        let url = AudioClipStore.url(for: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
