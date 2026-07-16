import Foundation

struct ContextDefinitionConfiguration {
    let enabled: Bool
    let baseURL: String
    let apiKey: String
    let model: String
}

enum ContextDefinitionError: LocalizedError {
    case missingAPIKey
    case gptRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "已启用 GPT 上下文释义，但 API Key 为空"
        case .gptRequestFailed(let message): return "GPT 上下文释义失败：\(message)"
        }
    }
}

struct ContextDefinitionService {
    func meaning(of selection: String,
                 previous: String?,
                 sentence: String,
                 next: String?,
                 dictionary: DictionaryResult?,
                 targetLanguage: String,
                 configuration: ContextDefinitionConfiguration) async throws -> String {
        if configuration.enabled {
            guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextDefinitionError.missingAPIKey
            }
            return try await gptMeaningWithRetry(of: selection, previous: previous, sentence: sentence,
                                                 next: next, targetLanguage: targetLanguage,
                                                 configuration: configuration)
        }

        let direct = try await MicrosoftTranslator.shared.translate(selection, to: targetLanguage)
        guard let sense = dictionary?.contextualMeaning(in: [previous, sentence, next].compactMap { $0 }.joined(separator: " ")) else {
            return direct
        }
        let explanation = try await MicrosoftTranslator.shared.translate(sense.definition, to: targetLanguage)
        return explanation.isEmpty ? direct : "\(direct)\n\(explanation)"
    }

    private func gptMeaningWithRetry(of selection: String,
                                     previous: String?,
                                     sentence: String,
                                     next: String?,
                                     targetLanguage: String,
                                     configuration: ContextDefinitionConfiguration) async throws -> String {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<2 {
            do {
                return try await gptMeaning(of: selection, previous: previous, sentence: sentence,
                                            next: next, targetLanguage: targetLanguage,
                                            configuration: configuration)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt == 0 { try await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        throw ContextDefinitionError.gptRequestFailed(lastError.localizedDescription)
    }

    private func gptMeaning(of selection: String,
                            previous: String?,
                            sentence: String,
                            next: String?,
                            targetLanguage: String,
                            configuration: ContextDefinitionConfiguration) async throws -> String {
        let endpoint = try chatEndpoint(configuration.baseURL)
        let context = [previous.map { "上一句：\($0)" }, "当前句：\(sentence)", next.map { "下一句：\($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        let system = "你是播客语言学习词典。只解释用户选中的单词或词组在给定上下文中的具体含义，不要翻译整段。先给简洁译义，必要时再用一句话说明语气、词性或隐含义。输出语言代码：\(targetLanguage)。"
        let user = "选中内容：\(selection)\n\(context)"
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    private func chatEndpoint(_ source: String) throws -> URL {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value = trimmed.hasSuffix("chat/completions") ? trimmed : (trimmed.hasSuffix("/v1") ? trimmed + "/chat/completions" : trimmed + "/v1/chat/completions")
        guard let url = URL(string: value) else { throw URLError(.badURL) }
        return url
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
