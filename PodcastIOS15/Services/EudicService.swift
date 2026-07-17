import Foundation
import UIKit

enum EudicService {
    static func open(_ term: String) {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        guard let appURL = URL(string: "eudic://dict/\(encoded)") else { return }
        UIApplication.shared.open(appURL, options: [:]) { opened in
            guard !opened, let webURL = URL(string: "https://dict.eudic.net/dicts/en/\(encoded)") else { return }
            UIApplication.shared.open(webURL)
        }
    }
}
