import Foundation

struct ContextDefinitionConfiguration {
    let enabled: Bool
    let baseURL: String
    let apiKey: String
    let model: String
    var style: AIExplanationStyle = .detailed

    var hasUserAPI: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldUseAIProvider: Bool {
        enabled || !hasUserAPI
    }

    func withStyle(_ style: AIExplanationStyle) -> ContextDefinitionConfiguration {
        ContextDefinitionConfiguration(enabled: enabled, baseURL: baseURL, apiKey: apiKey, model: model, style: style)
    }
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
        if configuration.shouldUseAIProvider {
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
        for attempt in 0..<3 {
            do {
                return try await gptMeaning(of: selection, previous: previous, sentence: sentence,
                                            next: next, targetLanguage: targetLanguage,
                                            configuration: configuration)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                let retryable = (error as? GPTConnectionError)?.retryable ?? ((error as? URLError).map {
                    [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                     .dnsLookupFailed, .notConnectedToInternet].contains($0.code)
                } ?? false)
                if !retryable { break }
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(700_000_000 * (1 << attempt))) }
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
        let resolvedConfiguration = try await BuiltInAIConfigurationProvider.shared.resolvedConfiguration(from: configuration)
        let endpoint = try chatEndpoint(resolvedConfiguration.baseURL)
        let context = [previous.map { "上一句：\($0)" }, "当前句：\(sentence)", next.map { "下一句：\($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        let styleInstruction: String
        switch configuration.style {
        case .concise: styleInstruction = "回答简洁，只保留当前语境义和最关键提示。"
        case .detailed: styleInstruction = "详细说明当前语境义、语气、词性和隐含含义。"
        case .grammar: styleInstruction = "重点说明词性、语法作用、搭配和可复用句型。"
        }
        let system = "你是播客语言学习词典。只解释用户选中的单词或词组在给定上下文中的具体含义，不要翻译整段。\(styleInstruction) 输出语言代码：\(targetLanguage)。"
        let user = "选中内容：\(selection)\n\(context)"
        let body: [String: Any] = [
            "model": resolvedConfiguration.model,
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
        request.setValue("Bearer \(resolvedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["error"] as? [String: Any], let detail = value["message"] as? String {
                message = detail
            } else {
                message = String(data: data, encoding: .utf8)?.prefix(300).description ?? "未知错误"
            }
            throw GPTConnectionError.http(http.statusCode, message)
        }
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
