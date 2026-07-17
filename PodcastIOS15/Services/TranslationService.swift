import Foundation

enum TranslationProvider: String, CaseIterable, Identifiable {
    case gpt
    case microsoft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gpt: return "GPT"
        case .microsoft: return "Microsoft"
        }
    }
}

struct TranslationConfiguration {
    let provider: TranslationProvider
    let allowFallback: Bool
    let gptBaseURL: String
    let gptAPIKey: String
    let gptModel: String
}

enum TranslationServiceError: LocalizedError {
    case emptyResponse
    case allProvidersFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "翻译服务返回了空结果"
        case .allProvidersFailed(let message): return "翻译失败：\(message)"
        }
    }
}

actor TranslationService {
    static let shared = TranslationService()
    private var disabledUntil: [TranslationProvider: Date] = [:]

    func translate(_ text: String, to language: String, configuration: TranslationConfiguration) async throws -> String {
        let order = providerOrder(configuration)
        var failures: [String] = []
        for provider in order {
            if let until = disabledUntil[provider], until > Date() { continue }
            do {
                let value = try await request(provider, text: text, language: language, configuration: configuration)
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationServiceError.emptyResponse }
                disabledUntil[provider] = nil
                return value
            } catch {
                failures.append("\(provider.title): \(error.localizedDescription)")
                if isTemporary(error) { disabledUntil[provider] = Date().addingTimeInterval(60) }
                if !configuration.allowFallback { throw error }
            }
        }
        throw TranslationServiceError.allProvidersFailed(failures.joined(separator: "；"))
    }

    private func providerOrder(_ configuration: TranslationConfiguration) -> [TranslationProvider] {
        guard configuration.allowFallback else { return [configuration.provider] }
        return [configuration.provider] + TranslationProvider.allCases.filter { $0 != configuration.provider }
    }

    private func request(_ provider: TranslationProvider, text: String, language: String, configuration: TranslationConfiguration) async throws -> String {
        switch provider {
        case .gpt:
            return try await translateWithGPT(text, to: language, configuration: configuration)
        case .microsoft:
            return try await MicrosoftTranslator.shared.translate(text, to: language)
        }
    }

    private func translateWithGPT(_ text: String, to language: String, configuration: TranslationConfiguration) async throws -> String {
        let resolvedConfiguration = try await BuiltInAIConfigurationProvider.shared.resolvedConfiguration(
            from: ContextDefinitionConfiguration(enabled: true,
                                                 baseURL: configuration.gptBaseURL,
                                                 apiKey: configuration.gptAPIKey,
                                                 model: configuration.gptModel))
        let base = resolvedConfiguration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("chat/completions") ? base : (base.hasSuffix("/v1") ? base + "/chat/completions" : base + "/v1/chat/completions")
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": resolvedConfiguration.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": "Translate the podcast transcript naturally and accurately into language code \(language). Preserve meaning, tone, names, and paragraph structure. Return only the translation."],
                ["role": "user", "content": text]
            ]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let result = try JSONDecoder().decode(GPTTranslationResponse.self, from: data)
        guard let value = result.choices.first?.message.content else { throw TranslationServiceError.emptyResponse }
        return value
    }

    private func isTemporary(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(urlError.code)
        }
        return true
    }
}

private struct GPTTranslationResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
