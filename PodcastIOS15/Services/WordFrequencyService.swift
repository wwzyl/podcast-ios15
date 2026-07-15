import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct WordFrequency: Equatable {
    let word: String
    let rank: Int
    let partOfSpeech: String

    var level: String {
        switch rank {
        case ...1000: return "极高频"
        case ...3000: return "高频"
        case ...10_000: return "常用"
        case ...30_000: return "较少见"
        default: return "低频"
        }
    }
}

struct WordFrequencyService {
    func lookup(_ selection: String) -> WordFrequency? {
        guard let databaseURL = Bundle.main.url(forResource: "words", withExtension: "sqlite") else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }

        let exact = normalizedWords(selection).joined(separator: " ")
        if let result = query(exact, database: database) { return result }

        // COCA 表不包含词组时，用词组中最少见的实词作为参考排名。
        return normalizedWords(selection)
            .filter { !Self.stopWords.contains($0) }
            .compactMap { query($0, database: database) }
            .max(by: { $0.rank < $1.rank })
    }

    private func query(_ word: String, database: OpaquePointer) -> WordFrequency? {
        guard !word.isEmpty else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT RANK, PoS, word FROM COCA60000 WHERE word = ? COLLATE NOCASE ORDER BY RANK LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, word, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let rank = Int(sqlite3_column_int(statement, 0))
        let partOfSpeech = sqlite3_column_text(statement, 1).map { String(cString: $0).trimmingCharacters(in: .whitespaces) } ?? ""
        let matchedWord = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? word
        return WordFrequency(word: matchedWord, rank: rank, partOfSpeech: partOfSpeech)
    }

    private func normalizedWords(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "to", "was", "were", "with"
    ]
}
