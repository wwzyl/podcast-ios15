import Foundation

struct TranscriptionPreferences {
    var splitOnComma: Bool
    var wordTimestamps: Bool
    var minimumSegmentDuration: Double
    var maximumSegmentDuration: Double
    var chineseSegmentCount: Int
    var translateToEnglish: Bool
    var keepScreenOn: Bool
    var autoDetectLanguage: Bool
    var sourceLanguage: String

    static var current: TranscriptionPreferences {
        let defaults = UserDefaults.standard
        return TranscriptionPreferences(
            splitOnComma: defaults.bool(forKey: "transcriptionSplitOnComma"),
            wordTimestamps: defaults.object(forKey: "transcriptionWordTimestamps") as? Bool ?? true,
            minimumSegmentDuration: defaults.object(forKey: "transcriptionMinimumSegmentDuration") as? Double ?? 1.0,
            maximumSegmentDuration: defaults.object(forKey: "transcriptionMaximumSegmentDuration") as? Double ?? 28.0,
            chineseSegmentCount: defaults.object(forKey: "transcriptionChineseSegmentCount") as? Int ?? 28,
            translateToEnglish: defaults.bool(forKey: "transcriptionTranslateToEnglish"),
            keepScreenOn: defaults.object(forKey: "transcriptionKeepScreenOn") as? Bool ?? true,
            autoDetectLanguage: defaults.object(forKey: "transcriptionAutoDetectLanguage") as? Bool ?? true,
            sourceLanguage: defaults.string(forKey: "transcriptionSourceLanguage") ?? "en")
    }
}
