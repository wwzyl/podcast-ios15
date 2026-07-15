import Foundation
import CryptoKit
import SQLite3
import ZIPFoundation

enum ExportError: LocalizedError {
    case cannotCreateDatabase, sqlite(String), cannotCreateArchive
    var errorDescription: String? {
        switch self {
        case .cannotCreateDatabase: return "无法创建 Anki 数据库"
        case .sqlite(let message): return "Anki 数据库错误：\(message)"
        case .cannotCreateArchive: return "无法创建 APKG 文件"
        }
    }
}

enum AnkiTemplateType: String, CaseIterable, Identifiable {
    case questionAnswer
    case cloze
    case typeCloze

    var id: String { rawValue }
    var title: String {
        switch self {
        case .questionAnswer: return "Anki问答题"
        case .cloze: return "Anki填空题"
        case .typeCloze: return "Anki输入填空题"
        }
    }
}

struct VocabularyExporter {
    func csv(_ items: [VocabularyItem]) throws -> URL {
        let url = temporaryURL("PodcastIOS15_Vocabulary.csv")
        let header = ["Word", "Phonetic", "Translation", "Definition", "Sentence", "Sentence Translation", "Podcast", "Episode", "Timestamp"]
        let rows = items.map { [$0.word, $0.phonetic ?? "", $0.translation, $0.definition, $0.sentence, $0.sentenceTranslation, $0.podcastTitle, $0.episodeTitle, $0.timestamp.clockString] }
        let text = ([header] + rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n")
        try ("\u{FEFF}" + text).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func apkg(_ items: [VocabularyItem], template: AnkiTemplateType = .questionAnswer) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("PodcastIOS15-Anki-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let databaseURL = folder.appendingPathComponent("collection.anki2")
        let mediaURL = folder.appendingPathComponent("media")
        var mediaMap: [String: String] = [:]
        var audioFields: [UUID: String] = [:]
        for item in items {
            guard let filename = item.audioClipFilename else { continue }
            let source = AudioClipStore.url(for: filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let index = String(mediaMap.count)
            let mediaName = "Aisten_\(item.id.uuidString).m4a"
            try fileManager.copyItem(at: source, to: folder.appendingPathComponent(index))
            mediaMap[index] = mediaName
            audioFields[item.id] = "[sound:\(mediaName)]"
        }
        try JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys]).write(to: mediaURL)
        try createDatabase(at: databaseURL, items: items, templateType: template, audioFields: audioFields)
        let archiveURL = temporaryURL("PodcastIOS15_\(template.title).apkg")
        try? fileManager.removeItem(at: archiveURL)
        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .create) }
        catch { throw ExportError.cannotCreateArchive }
        try archive.addEntry(with: "collection.anki2", fileURL: databaseURL, compressionMethod: .deflate)
        try archive.addEntry(with: "media", fileURL: mediaURL, compressionMethod: .deflate)
        for index in mediaMap.keys.sorted(by: { Int($0)! < Int($1)! }) {
            try archive.addEntry(with: index, fileURL: folder.appendingPathComponent(index), compressionMethod: .deflate)
        }
        return archiveURL
    }

    private func createDatabase(at url: URL, items: [VocabularyItem], templateType: AnkiTemplateType, audioFields: [UUID: String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw ExportError.cannotCreateDatabase }
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        try execute(database, """
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn); CREATE INDEX ix_cards_usn on cards (usn); CREATE INDEX ix_cards_nid on cards (nid); CREATE INDEX ix_revlog_usn on revlog (usn); CREATE INDEX ix_cards_sched on cards (did, queue, due); CREATE INDEX ix_revlog_cid on revlog (cid);
        """)

        let now = Int64(Date().timeIntervalSince1970)
        let modelID = now * 1000
        let deckID = modelID + 1
        let cardFormats = formats(for: templateType)
        let template: [String: Any] = ["name": templateType.title, "ord": 0, "qfmt": cardFormats.question, "afmt": cardFormats.answer, "bqfmt": "", "bafmt": "", "did": NSNull()]
        let fieldNames = ["Word", "WordAudio", "Symbol", "Sentence1", "Audio1", "Source1", "Translation1", "Definition", "SentenceCloze", "Backlink"]
        let fields: [[String: Any]] = fieldNames.enumerated().map {
            ["name": $0.element, "ord": $0.offset, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []]
        }
        let model: [String: Any] = [
            "id": modelID, "name": officialModelName(for: templateType), "type": templateType == .questionAnswer ? 0 : 1, "mod": now, "usn": -1, "sortf": 0, "did": deckID,
            "tmpls": [template],
            "flds": fields,
            "css": ".card{font-family:-apple-system,Arial;font-size:20px;text-align:left;color:#222;background:#fff}.word{font-size:32px;font-weight:700;color:#5856d6}.phonetic{color:#777;margin:4px 0 16px}.sentence{font-size:22px;margin:12px 0}.translation{font-size:24px;color:#5856d6;margin:12px 0}.context,.source{color:#777;margin-top:10px}.source{font-size:13px}.cloze{font-weight:700;color:#5856d6}",
            "latexPre": "", "latexPost": "", "latexsvg": false, "req": [[0, "all", [templateType == .questionAnswer ? 0 : 8]]], "vers": []
        ]
        let deck: [String: Any] = ["id": deckID, "name": "Podcast iOS15", "mod": now, "usn": -1, "desc": "从 Podcast iOS15 生词库导出", "dyn": 0, "collapsed": false, "browserCollapsed": false, "extendNew": 0, "extendRev": 0, "conf": 1]
        let config: [String: Any] = ["nextPos": items.count + 1, "estTimes": true, "activeDecks": [deckID], "sortType": "noteFld", "timeLim": 0, "sortBackwards": false, "addToCur": true, "curDeck": deckID, "newBury": true, "newSpread": 0, "dueCounts": true, "curModel": modelID, "collapseTime": 1200]
        let deckConfig: [String: Any] = ["1": ["id": 1, "name": "Default", "mod": 0, "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true, "new": ["bury": false, "delays": [1, 10], "initialFactor": 2500, "ints": [1, 4], "order": 1, "perDay": 20], "rev": ["bury": false, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1, "maxIvl": 36500, "perDay": 200, "hardFactor": 1.2], "lapse": ["delays": [10], "leechAction": 0, "leechFails": 8, "minInt": 1, "mult": 0]]]
        let modelsJSON = try json([String(modelID): model])
        let decksJSON = try json([String(deckID): deck])
        let confJSON = try json(config)
        let dconfJSON = try json(deckConfig)
        try execute(database, "INSERT INTO col VALUES (1,\(now),\(now),\(now),11,0,0,0,'\(sql(confJSON))','\(sql(modelsJSON))','\(sql(decksJSON))','\(sql(dconfJSON))','{}');")

        for (index, item) in items.enumerated() {
            let noteID = now * 1000 + Int64(index * 2 + 10)
            let cardID = noteID + 1
            let cloze = clozeSentence(for: item, type: templateType)
            let source = "\(item.podcastTitle) — \(item.episodeTitle) [\(item.timestamp.clockString)]"
            let backlink = "podcastios15://episode/\(item.id.uuidString)"
            let noteFields = [item.word, "", item.phonetic ?? "", item.sentence, audioFields[item.id] ?? "", source, item.sentenceTranslation.isEmpty ? item.translation : item.sentenceTranslation, item.definition, cloze, backlink]
            let fields = noteFields.map(htmlPreservingAnkiMarkup).joined(separator: "\u{1f}")
            let checksum = sha1Checksum(item.word)
            try execute(database, "INSERT INTO notes VALUES (\(noteID),'\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))',\(modelID),\(now),-1,' ','\(sql(fields))','\(sql(item.word))',\(checksum),0,'');")
            try execute(database, "INSERT INTO cards VALUES (\(cardID),\(noteID),\(deckID),0,\(now),-1,0,0,\(index + 1),0,0,0,0,0,0,0,0,'');")
        }
    }

    private func execute(_ database: OpaquePointer, _ statement: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, statement, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw ExportError.sqlite(text)
        }
    }

    private func json(_ object: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}" }
    private func sql(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    private func html(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>") }
    private func htmlPreservingAnkiMarkup(_ value: String) -> String {
        if value.hasPrefix("[sound:") || value.hasPrefix("podcastios15://") { return value }
        return html(value)
    }
    private func formats(for type: AnkiTemplateType) -> (question: String, answer: String) {
        let wordFront = "<div class=\"section word\"><h1>{{Word}}{{WordAudio}}</h1><i>{{Symbol}}</i></div><div class=\"section sentence\"><blockquote>{{Sentence1}}{{Audio1}}<cite>{{Source1}}</cite></blockquote></div>"
        let wordBack = "{{FrontSide}}<div class=\"section translation\">{{Translation1}}</div><div class=\"section definition\">{{Definition}}</div><div class=\"section backlink\">{{Backlink}}</div>"
        switch type {
        case .questionAnswer:
            return (wordFront, wordBack)
        case .cloze:
            return ("<div class=\"section sentence\">{{cloze:SentenceCloze}}{{Audio1}}<cite>{{Source1}}</cite></div>", "{{FrontSide}}<div class=\"section word\">{{Word}}</div><div class=\"section translation\">{{Translation1}}</div><div class=\"section definition\">{{Definition}}</div>")
        case .typeCloze:
            return ("<div class=\"section sentence\">{{type:cloze:SentenceCloze}}{{Audio1}}<cite>{{Source1}}</cite></div>", "{{FrontSide}}<div class=\"section word\">{{Word}}</div><div class=\"section translation\">{{Translation1}}</div><div class=\"section definition\">{{Definition}}</div>")
        }
    }
    private func officialModelName(for type: AnkiTemplateType) -> String {
        switch type {
        case .questionAnswer: return "Aisten Word QA_2025-03-11"
        case .cloze: return "Aisten Word Cloze_2025-11-08"
        case .typeCloze: return "Aisten Word Type Cloze_2025-11-08"
        }
    }
    private func clozeSentence(for item: VocabularyItem, type: AnkiTemplateType) -> String {
        guard !item.word.isEmpty else { return item.sentence }
        let pattern = NSRegularExpression.escapedPattern(for: item.word)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return item.sentence }
        let range = NSRange(item.sentence.startIndex..., in: item.sentence)
        switch type {
        case .cloze: return regex.stringByReplacingMatches(in: item.sentence, range: range, withTemplate: "{{c1::$0}}")
        case .typeCloze: return regex.stringByReplacingMatches(in: item.sentence, range: range, withTemplate: "{{c1::$0}}")
        case .questionAnswer: return item.sentence
        }
    }
    private func sha1Checksum(_ value: String) -> UInt32 {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func csvField(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func temporaryURL(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }
}
