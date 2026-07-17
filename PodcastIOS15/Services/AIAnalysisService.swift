import Foundation

enum AIAnalysisKind {
    case sentence
    case expression(String)
}

enum AIExplanationStyle: String, CaseIterable, Identifiable {
    case concise
    case detailed
    case grammar

    var id: String { rawValue }
    var title: String {
        switch self {
        case .concise: return "简洁"
        case .detailed: return "详细"
        case .grammar: return "语法学习"
        }
    }
}

enum GPTConnectionError: LocalizedError {
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "GPT HTTP \(status)：\(message)"
        case .emptyResponse: return "GPT 返回了空内容"
        }
    }

    var retryable: Bool {
        switch self {
        case .http(let status, _): return status == 408 || status == 409 || status == 429 || status >= 500
        case .emptyResponse: return true
        }
    }
}

struct AIAnalysisService {
    func analyze(kind: AIAnalysisKind,
                 previous: String?,
                 sentence: String,
                 next: String?,
                 outputLanguage: String,
                 style: AIExplanationStyle,
                 configuration: ContextDefinitionConfiguration) async throws -> String {
        var latest = ""
        for try await value in analyzeStream(kind: kind, previous: previous, sentence: sentence, next: next,
                                             outputLanguage: outputLanguage, style: style, configuration: configuration) {
            latest = value
        }
        guard !latest.isEmpty else { throw URLError(.cannotParseResponse) }
        return latest
    }

    func analyzeStream(kind: AIAnalysisKind,
                       previous: String?,
                       sentence: String,
                       next: String?,
                       outputLanguage: String,
                       style: AIExplanationStyle,
                       configuration: ContextDefinitionConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = URLError(.unknown)
                for attempt in 0..<3 {
                    do {
                        let request = try await makeRequest(kind: kind, previous: previous, sentence: sentence, next: next,
                                                            outputLanguage: outputLanguage, style: style,
                                                            configuration: configuration, stream: true)
                        try await perform(request: request, continuation: continuation)
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                        lastError = error
                        guard attempt < 2, isRetryable(error) else { break }
                        try? await Task.sleep(nanoseconds: UInt64(700_000_000 * (1 << attempt)))
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(request: URLRequest,
                         continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw GPTConnectionError.http(http.statusCode, serverMessage(data))
        }
        if contentType.lowercased().contains("text/event-stream") {
            var accumulated = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(AIStreamResponse.self, from: data),
                      let delta = event.choices.first?.delta.content else { continue }
                accumulated += delta
                continuation.yield(accumulated)
            }
            guard !accumulated.isEmpty else { throw GPTConnectionError.emptyResponse }
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let decoded = try JSONDecoder().decode(AIAnalysisResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else { throw GPTConnectionError.emptyResponse }
            continuation.yield(content)
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let error = error as? GPTConnectionError { return error.retryable }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff].contains(error.code)
        }
        return false
    }

    private func serverMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(data: data, encoding: .utf8)?.prefix(300).description ?? "未知错误"
    }

    private func makeRequest(kind: AIAnalysisKind,
                             previous: String?,
                             sentence: String,
                             next: String?,
                             outputLanguage: String,
                             style: AIExplanationStyle,
                             configuration: ContextDefinitionConfiguration,
                             stream: Bool) async throws -> URLRequest {
        let resolvedConfiguration = try await BuiltInAIConfigurationProvider.shared.resolvedConfiguration(from: configuration)
        let endpoint = try chatEndpoint(resolvedConfiguration.baseURL)
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
        let styleInstruction: String
        switch style {
        case .concise: styleInstruction = "Keep the answer concise and focus only on the most useful learning points."
        case .detailed: styleInstruction = "Give a detailed explanation with clear reasoning and examples."
        case .grammar: styleInstruction = "Prioritize grammar, syntax, word function, collocations, and reusable sentence patterns."
        }
        let body: [String: Any] = [
            "model": resolvedConfiguration.model,
            "temperature": 0.15,
            "stream": stream,
            "messages": [
                ["role": "system", "content": "You are a precise podcast language-learning tutor. Answer in language code \(outputLanguage)."],
                ["role": "user", "content": styleInstruction + "\n\n" + task + "\n\nContext:\n" + context]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func chatEndpoint(_ source: String) throws -> URL {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value = trimmed.hasSuffix("chat/completions") ? trimmed : (trimmed.hasSuffix("/v1") ? trimmed + "/chat/completions" : trimmed + "/v1/chat/completions")
        guard let url = URL(string: value) else { throw URLError(.badURL) }
        return url
    }
}

private struct AIStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct AIAnalysisResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
