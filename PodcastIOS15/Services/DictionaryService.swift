import Foundation

struct DictionaryResult {
    let phonetic: String
    let definition: String
}

struct DictionaryService {
    private struct Entry: Decodable {
        struct Meaning: Decodable {
            struct Definition: Decodable { let definition: String; let example: String? }
            let partOfSpeech: String
            let definitions: [Definition]
        }
        let phonetic: String?
        let meanings: [Meaning]
    }

    func lookup(_ word: String) async throws -> DictionaryResult {
        let safe = word.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(safe)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard let first = entries.first else { throw URLError(.zeroByteResource) }
        let definitions = first.meanings.prefix(4).compactMap { meaning -> String? in
            guard let value = meaning.definitions.first else { return nil }
            var line = "[\(meaning.partOfSpeech)] \(value.definition)"
            if let example = value.example { line += "\n例：\(example)" }
            return line
        }.joined(separator: "\n\n")
        return DictionaryResult(phonetic: first.phonetic ?? "", definition: definitions)
    }
}
