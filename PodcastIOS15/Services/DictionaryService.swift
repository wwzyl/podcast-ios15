import Foundation

struct DictionaryMeaning: Hashable {
    let partOfSpeech: String
    let definition: String
    let example: String?
    let synonyms: [String]
}

struct DictionaryResult {
    let phonetic: String
    let meanings: [DictionaryMeaning]

    var definition: String {
        meanings.prefix(6).map { meaning in
            var line = "[\(meaning.partOfSpeech)] \(meaning.definition)"
            if let example = meaning.example, !example.isEmpty { line += "\n例：\(example)" }
            return line
        }.joined(separator: "\n\n")
    }

    func contextualMeaning(in context: String) -> DictionaryMeaning? {
        let contextWords = Self.contentWords(context)
        return meanings.max { left, right in
            score(left, contextWords: contextWords) < score(right, contextWords: contextWords)
        }
    }

    private func score(_ meaning: DictionaryMeaning, contextWords: Set<String>) -> Int {
        let description = ([meaning.definition, meaning.example ?? ""] + meaning.synonyms).joined(separator: " ")
        return Self.contentWords(description).intersection(contextWords).count
    }

    private static func contentWords(_ value: String) -> Set<String> {
        let stop: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "to", "was", "were", "with"]
        return Set(value.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 && !stop.contains($0) })
    }
}

struct DictionaryService {
    private struct Entry: Decodable {
        struct Phonetic: Decodable { let text: String? }
        struct Meaning: Decodable {
            struct Definition: Decodable {
                let definition: String
                let example: String?
                let synonyms: [String]?
            }
            let partOfSpeech: String
            let definitions: [Definition]
            let synonyms: [String]?
        }
        let phonetic: String?
        let phonetics: [Phonetic]?
        let meanings: [Meaning]
    }

    /// Aisten 6.3.5 使用的 Free Dictionary API 代理；失败时回退到上游公开接口。
    func lookup(_ word: String) async throws -> DictionaryResult {
        let safe = word.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        let endpoints = [
            URL(string: "https://fda.josscii.top/api/v2/entries/en/\(safe)")!,
            URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(safe)")!
        ]
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for url in endpoints {
            do { return try await request(url) }
            catch { lastError = error }
        }
        throw lastError
    }

    private func request(_ url: URL) async throws -> DictionaryResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Aisten/6.3.5 PodcastIOS15/1.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard let first = entries.first else { throw URLError(.zeroByteResource) }
        let meanings = first.meanings.flatMap { meaning in
            meaning.definitions.prefix(3).map {
                DictionaryMeaning(partOfSpeech: meaning.partOfSpeech,
                                  definition: $0.definition,
                                  example: $0.example,
                                  synonyms: ($0.synonyms ?? []) + (meaning.synonyms ?? []))
            }
        }
        let phonetic = first.phonetic ?? first.phonetics?.compactMap(\.text).first ?? ""
        return DictionaryResult(phonetic: phonetic, meanings: meanings)
    }
}
