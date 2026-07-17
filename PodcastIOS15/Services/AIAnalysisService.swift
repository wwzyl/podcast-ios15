import Foundation

enum AIAnalysisKind {
    case sentence
    case expression(String)
}

struct AIAnalysisService {
    func analyze(kind: AIAnalysisKind,
                 previous: String?,
                 sentence: String,
                 next: String?,
                 outputLanguage: String,
                 configuration: ContextDefinitionConfiguration) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextDefinitionError.missingAPIKey
        }
        let endpoint = try chatEndpoint(configuration.baseURL)
        let context = [previous.map { "Previous: \($0)" }, "Current: \(sentence)", next.map { "Next: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        let task: String
        switch kind {
        case .sentence:
            task = """
            Analyze the current podcast sentence for a language learner. Use concise Markdown with these sections when relevant:
            1. Natural meaning
            2. Sentence structure and grammar
            3. Key expressions and collocations
            4. Tone, implication, or cultural context
            Do not invent information and do not analyze unrelated surrounding sentences.
            """
        case .expression(let expression):
            task = """
            Explain the selected expression "\(expression)" specifically in the current context. Include its contextual meaning, part of speech or grammatical role, nuance, why it is used here, and one short parallel example. Do not provide unrelated dictionary senses.
            """
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.15,
            "messages": [
                ["role": "system", "content": "You are a precise podcast language-learning tutor. Answer in language code \(outputLanguage)."],
                ["role": "user", "content": task + "\n\nContext:\n" + context]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(AIAnalysisResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    private func chatEndpoint(_ source: String) throws -> URL {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value = trimmed.hasSuffix("chat/completions") ? trimmed : (trimmed.hasSuffix("/v1") ? trimmed + "/chat/completions" : trimmed + "/v1/chat/completions")
        guard let url = URL(string: value) else { throw URLError(.badURL) }
        return url
    }
}

private struct AIAnalysisResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
