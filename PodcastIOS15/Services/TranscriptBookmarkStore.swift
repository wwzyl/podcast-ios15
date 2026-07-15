import Foundation
import CryptoKit

enum TranscriptBookmarkStore {
    static func load(episodeID: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(episodeID)) ?? [])
    }

    static func save(_ values: Set<String>, episodeID: String) {
        UserDefaults.standard.set(values.sorted(), forKey: key(episodeID))
    }

    private static func key(_ episodeID: String) -> String {
        let digest = SHA256.hash(data: Data(episodeID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "transcript.bookmarks.\(digest)"
    }
}
