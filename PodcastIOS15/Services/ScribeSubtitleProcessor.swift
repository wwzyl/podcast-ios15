import Foundation

struct ScribeWordToken: Codable, Hashable {
    var text: String
    var type: String
    var start: TimeInterval?
    var end: TimeInterval?
    var speakerID: String?

    enum CodingKeys: String, CodingKey {
        case text, type, start, end
        case speakerID = "speaker_id"
    }

    init(text: String, type: String, start: TimeInterval?, end: TimeInterval?, speakerID: String? = nil) {
        self.text = text
        self.type = type
        self.start = start
        self.end = end
        self.speakerID = speakerID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "word"
        start = try values.decodeIfPresent(TimeInterval.self, forKey: .start)
        end = try values.decodeIfPresent(TimeInterval.self, forKey: .end)
        speakerID = try values.decodeIfPresent(String.self, forKey: .speakerID)
    }
}

/// Paragraph segmentation matching Aisten's transcript-oriented behavior.
/// Full sentences are preferred; subtitle line-count and seven-second limits
/// must not create timeline boundaries inside normal spoken sentences.
enum ScribeSubtitleProcessor {
    struct Settings {
        let minimumDuration: TimeInterval = 0.35
        let targetParagraphDuration: TimeInterval = 3.2
        let preferredMaximumDuration: TimeInterval = 14
        let maximumDuration: TimeInterval = 30
        let minimumGap: TimeInterval = 0.083
        let cjkCPS: Double = 11
        let latinCPS: Double = 15
        let cjkMaximumCharacters = 360
        let latinMaximumCharacters = 520
        let semanticPause: TimeInterval = 1.8
        let naturalSplitPause: TimeInterval = 0.35
        let maximumMergeGap: TimeInterval = 0.9
    }

    private struct TimedWord: Hashable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var type: String
        var speakerID: String?
    }

    private struct Entry {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var words: [TimedWord]
        var isAudioEvent: Bool
        var speakerID: String?

        var characterCount: Int { text.filter { !$0.isWhitespace }.count }
        var duration: TimeInterval { max(0, end - start) }
    }

    static func process(words rawWords: [ScribeWordToken], languageCode: String?) -> [TranscriptSegment] {
        let settings = Settings()
        let cjk = isCJK(languageCode)
        let limits = Limits(cps: cjk ? settings.cjkCPS : settings.latinCPS,
                            maximumCharacters: cjk ? settings.cjkMaximumCharacters : settings.latinMaximumCharacters)
        let preprocessed = preprocess(rawWords)
        var basicEntries: [Entry] = []

        for group in semanticGroups(preprocessed.words, pauseThreshold: settings.semanticPause) {
            for safeGroup in splitOversized(group, limits: limits, settings: settings) {
                if let entry = makeEntry(from: safeGroup, isAudioEvent: false) {
                    basicEntries.append(entry)
                }
            }
        }

        let merged = mergeShortEntries(basicEntries, cjk: cjk, limits: limits, settings: settings)
        var allEntries = optimizeTimings(merged, limits: limits, settings: settings)
        allEntries.append(contentsOf: preprocessed.audioEvents.compactMap {
            makeEntry(from: [$0], isAudioEvent: true)
        })
        allEntries.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        return allEntries.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, entry.start.isFinite, entry.end.isFinite else { return nil }
            return TranscriptSegment(start: max(0, entry.start),
                                     end: max(entry.start + 0.01, entry.end),
                                     text: text)
        }
    }

    private struct Limits {
        let cps: Double
        let maximumCharacters: Int
    }

    private static func isCJK(_ languageCode: String?) -> Bool {
        let code = (languageCode ?? "").lowercased()
        return ["zh", "zho", "chi", "ja", "jpn", "ko", "kor"].contains { code.hasPrefix($0) }
    }

    private static func preprocess(_ rawWords: [ScribeWordToken]) -> (words: [TimedWord], audioEvents: [TimedWord]) {
        var words: [TimedWord] = []
        var audioEvents: [TimedWord] = []
        let cjkPunctuation = "。？！」「、・，；：『』【】（）《》"

        for token in rawWords {
            if token.type == "audio_event" {
                if let event = timedWord(token) { audioEvents.append(event) }
                continue
            }
            if token.type == "spacing" {
                if !words.isEmpty,
                   token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !words[words.count - 1].text.hasSuffix(" ") {
                    words[words.count - 1].text += " "
                }
                continue
            }
            guard var word = timedWord(token) else { continue }
            let characters = Array(word.text)
            if characters.count == 1,
               let character = characters.first,
               cjkPunctuation.contains(character),
               !words.isEmpty,
               !cjkPunctuation.contains(words[words.count - 1].text.last ?? " ") {
                words[words.count - 1].text += word.text
                words[words.count - 1].end = word.end
                continue
            }
            word.type = "word"
            words.append(word)
        }
        return (words, audioEvents)
    }

    private static func timedWord(_ token: ScribeWordToken) -> TimedWord? {
        guard let start = token.start, let end = token.end,
              start.isFinite, end.isFinite, end >= start,
              !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TimedWord(text: token.text, start: start, end: end, type: token.type, speakerID: token.speakerID)
    }

    private static func semanticGroups(_ words: [TimedWord], pauseThreshold: TimeInterval) -> [[TimedWord]] {
        guard !words.isEmpty else { return [] }
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            if let previous = current.last {
                let speakerChanged = previous.speakerID != nil && word.speakerID != nil && previous.speakerID != word.speakerID
                if speakerChanged || word.start - previous.end > pauseThreshold {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
            if punctuationPriority(word.text) == 0 {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func splitOversized(_ words: [TimedWord], limits: Limits, settings: Settings) -> [[TimedWord]] {
        guard !words.isEmpty else { return [] }
        var output: [[TimedWord]] = []
        var remaining = words

        while !remaining.isEmpty {
            var allowedCount = 0
            var characters = 0
            var mediumBoundary: Int?
            var lowBoundary: Int?
            var pauseBoundary: Int?
            let groupStart = remaining[0].start

            for (index, word) in remaining.enumerated() {
                let nextCharacters = characters + word.text.filter { !$0.isWhitespace }.count
                let nextDuration = word.end - groupStart
                if index > 0 && (nextCharacters > limits.maximumCharacters || nextDuration > settings.maximumDuration) {
                    break
                }
                characters = nextCharacters
                allowedCount = index + 1
                let priority = punctuationPriority(word.text)
                if priority == 1 { mediumBoundary = index + 1 }
                if priority == 2 { lowBoundary = index + 1 }
                if index + 1 < remaining.count,
                   remaining[index + 1].start - word.end >= settings.naturalSplitPause {
                    pauseBoundary = index + 1
                }
            }

            if allowedCount >= remaining.count {
                output.append(remaining)
                break
            }

            let minimumUsefulBoundary = max(1, allowedCount / 2)
            // Only exceptionally long sentences are split. Prefer clause
            // punctuation or a real acoustic pause before a neutral boundary.
            let preferred = [mediumBoundary, lowBoundary, pauseBoundary]
                .compactMap { $0 }
                .filter { $0 >= minimumUsefulBoundary && $0 <= allowedCount }
                .max()
            let neutralBoundary = allowedCount
            let splitCount = max(1, preferred ?? neutralBoundary)
            output.append(Array(remaining.prefix(splitCount)))
            remaining.removeFirst(splitCount)
        }
        return output
    }

    private static func makeEntry(from words: [TimedWord], isAudioEvent: Bool) -> Entry? {
        guard let first = words.first, let last = words.last else { return nil }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Entry(text: text, start: first.start, end: last.end, words: words,
                     isAudioEvent: isAudioEvent, speakerID: words.compactMap(\.speakerID).first)
    }

    private static func mergeShortEntries(_ entries: [Entry], cjk: Bool, limits: Limits, settings: Settings) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        var merged: [Entry] = []
        var index = 0

        while index < entries.count {
            var current = entries[index]
            while index + 1 < entries.count {
                let next = entries[index + 1]
                guard canMerge(current, next, cjk: cjk, limits: limits, settings: settings),
                      mergeBenefit(current, next, settings: settings) > 5 else { break }
                current = merge(current, next, cjk: cjk)
                index += 1
            }
            merged.append(current)
            index += 1
        }
        return merged
    }

    private static func canMerge(_ first: Entry, _ second: Entry, cjk: Bool, limits: Limits, settings: Settings) -> Bool {
        guard !first.isAudioEvent, !second.isAudioEvent else { return false }
        if let firstSpeaker = first.speakerID, let secondSpeaker = second.speakerID,
           firstSpeaker != secondSpeaker { return false }
        let gap = second.start - first.end
        guard gap >= -0.15, gap <= settings.maximumMergeGap else { return false }
        let joined = join(first.text, second.text, cjk: cjk)
        let duration = second.end - first.start
        guard duration <= settings.preferredMaximumDuration else { return false }
        return joined.filter { !$0.isWhitespace }.count <= limits.maximumCharacters
    }

    private static func mergeBenefit(_ first: Entry, _ second: Entry, settings: Settings) -> Double {
        var score = 0.0
        if first.duration < settings.targetParagraphDuration { score += (settings.targetParagraphDuration - first.duration) * 8 }
        if second.duration < settings.targetParagraphDuration { score += (settings.targetParagraphDuration - second.duration) * 8 }
        let gap = second.start - first.end
        if gap < 0.3 { score += (0.3 - gap) * 10 }
        else if gap < 0.5 { score += (0.5 - gap) * 5 }
        score += shortTextBenefit(first.characterCount)
        score += shortTextBenefit(second.characterCount)
        return score
    }

    private static func shortTextBenefit(_ count: Int) -> Double {
        if count < 3 { return Double(3 - count) * 5 }
        if count < 8 { return Double(8 - count) * 2 }
        return 0
    }

    private static func merge(_ first: Entry, _ second: Entry, cjk: Bool) -> Entry {
        Entry(text: join(first.text, second.text, cjk: cjk),
              start: first.start,
              end: second.end,
              words: first.words + second.words,
              isAudioEvent: false,
              speakerID: first.speakerID ?? second.speakerID)
    }

    private static func join(_ first: String, _ second: String, cjk: Bool) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        if cjk { return first + second }
        if let leading = second.first, ",.;:!?)]}”’".contains(leading) { return first + second }
        if let trailing = first.last, "([{“‘\"".contains(trailing) { return first + second }
        return first + " " + second
    }

    private static func optimizeTimings(_ entries: [Entry], limits: Limits, settings: Settings) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        var output: [Entry] = []
        for (index, value) in entries.enumerated() {
            var entry = value
            var duration = min(settings.maximumDuration, max(settings.minimumDuration, entry.duration))
            let requiredForReading = Double(entry.characterCount) / dynamicCPSLimit(entry.text, base: limits.cps)
            duration = min(settings.maximumDuration, max(duration, requiredForReading))
            entry.end = entry.start + duration
            if index + 1 < entries.count {
                let latestEnd = entries[index + 1].start - settings.minimumGap
                entry.end = min(entry.end, max(entry.start + 0.01, latestEnd))
            }
            output.append(entry)
        }
        return output
    }

    private static func dynamicCPSLimit(_ text: String, base: Double) -> Double {
        let count = text.filter { !$0.isWhitespace }.count
        if count <= 3 { return base * 3 }
        if count <= 5 { return base * 2 }
        if count <= 10 { return base * 1.5 }
        return base
    }

    /// 0 = sentence ending, 1 = clause ending, 2 = phrase separator.
    private static func punctuationPriority(_ text: String) -> Int {
        let high = ".!?。！？"
        let medium = ";:)]}；：》」』】）"
        let low = ",([{…-，、《「『【（、"
        let closingQuotes = "\"'”’」』】）)]}》"
        for character in text.reversed() {
            if high.contains(character) { return 0 }
            if medium.contains(character) { return 1 }
            if low.contains(character) { return 2 }
            if character.isWhitespace || closingQuotes.contains(character) { continue }
            break
        }
        return -1
    }
}
