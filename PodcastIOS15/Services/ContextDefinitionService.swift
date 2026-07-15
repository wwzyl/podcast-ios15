import Foundation

struct ContextDefinitionConfiguration {
    let enabled: Bool
    let baseURL: String
    let apiKey: String
    let model: String
}

struct ContextDefinitionService {
    func meaning(of selection: String,
                 previous: String?,
                 sentence: String,
                 next: String?,
                 dictionary: DictionaryResult?,
                 targetLanguage: String,
                 configuration: ContextDefinitionConfiguration) async throws -> String {
        if configuration.enabled, !configuration.apiKey.isEmpty {
            if let value = try? await gptMeaning(of: selection, previous: previous, sentence: sentence, next: next, targetLanguage: targetLanguage, configuration: configuration) {
                return value
            }
        }

        let direct = try await MicrosoftTranslator.shared.translate(selection, to: targetLanguage)
        guard let sense = dictionary?.contextualMeaning(in: [previous, sentence, next].compactMap { $0 }.joined(separator: " ")) else {
            return direct
        }
        let explanation = try await MicrosoftTranslator.shared.translate(sense.definition, to: targetLanguage)
        return explanation.isEmpty ? direct : "\(direct)\n\(explanation)"
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
