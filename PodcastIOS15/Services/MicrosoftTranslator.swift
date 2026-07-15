import Foundation

actor MicrosoftTranslator {
    static let shared = MicrosoftTranslator()
    private let authURL = URL(string: "https://edge.microsoft.com/translate/auth")!
    private let translateBaseURL = URL(string: "https://api-edge.cognitive.microsofttranslator.com/translate")!
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var cache: [String: String] = [:]

    func translate(_ text: String, to language: String) async throws -> String {
        try await translateBatch([text], to: language).first ?? ""
    }

    func translateWithContext(previous: String?, current: String, next: String?, to language: String) async throws -> String {
        let context = [previous, current, next].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard context.count > 1 else { return try await translate(current, to: language) }
        let joined = context.joined(separator: "\n")
        let result = try await translate(joined, to: language)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let currentIndex = previous?.isEmpty == false ? 1 : 0
        return lines.indices.contains(currentIndex) ? lines[currentIndex] : result
    }

    func translateBatch(_ texts: [String], to language: String) async throws -> [String] {
        var output = Array(repeating: "", count: texts.count)
        var missing: [(Int, String)] = []
        for (index, text) in texts.enumerated() {
            let key = "\(language)|\(text)"
            if let cached = cache[key] { output[index] = cached }
            else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output[index] = text }
            else { missing.append((index, text)) }
        }
        for chunk in missing.chunked(maxCount: 50, maxCharacters: 30_000) {
            let translated = try await request(chunk.map { $0.1 }, language: language, retried: false)
            for (position, item) in chunk.enumerated() {
                output[item.0] = translated[position]
                cache["\(language)|\(item.1)"] = translated[position]
            }
        }
        return output
    }

    private func request(_ texts: [String], language: String, retried: Bool) async throws -> [String] {
        let bearer = try await getToken()
        var components = URLComponents(url: translateBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: ""),
            URLQueryItem(name: "to", value: language),
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "includeSentenceLength", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: texts.map { ["Text": $0] })
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !retried {
            token = nil
            tokenExpiry = .distantPast
            return try await self.request(texts, language: language, retried: true)
        }
        try validate(response)
        let decoded = try JSONDecoder().decode([TranslationResponse].self, from: data)
        guard decoded.count == texts.count else { throw URLError(.cannotParseResponse) }
        return decoded.map { $0.translations.first?.text ?? "" }
    }

    private func getToken() async throws -> String {
        if let token, Date() < tokenExpiry { return token }
        var request = URLRequest(url: authURL)
        request.timeoutInterval = 30
        request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw URLError(.userAuthenticationRequired) }
        token = value
        tokenExpiry = Date().addingTimeInterval(8 * 60)
        return value
    }
}

private struct TranslationResponse: Decodable {
    struct Translation: Decodable { let text: String }
    let translations: [Translation]
}

private extension Array where Element == (Int, String) {
    func chunked(maxCount: Int, maxCharacters: Int) -> [[Element]] {
        var chunks: [[Element]] = [], current: [Element] = []
        var characters = 0
        for item in self {
            if !current.isEmpty && (current.count >= maxCount || characters + item.1.count > maxCharacters) {
                chunks.append(current); current = []; characters = 0
            }
            current.append(item); characters += item.1.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
