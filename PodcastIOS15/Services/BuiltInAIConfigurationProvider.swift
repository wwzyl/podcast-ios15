import Foundation

enum BuiltInAIConfigurationError: LocalizedError {
    case unavailable
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Built-in AI API is unavailable"
        case .invalidManifest: return "Built-in AI API configuration is invalid"
        }
    }
}

actor BuiltInAIConfigurationProvider {
    static let shared = BuiltInAIConfigurationProvider()

    private let manifestURLs = [
        "https://vip.123pan.cn/1836303614/dl/new-api/model.json",
        "https://cdn.u1162561.nyat.app:43836/d/cdn/mnaddonStore/model.json",
        "https://qiniu.feliks.top/model.json"
    ]
    private var cachedConfiguration: ContextDefinitionConfiguration?

    func resolvedConfiguration(from configuration: ContextDefinitionConfiguration) async throws -> ContextDefinitionConfiguration {
        if configuration.hasUserAPI {
            return configuration
        }
        if let cachedConfiguration {
            return cachedConfiguration.withStyle(configuration.style)
        }
        let builtIn = try await loadBuiltInConfiguration()
        cachedConfiguration = builtIn
        return builtIn.withStyle(configuration.style)
    }

    private func loadBuiltInConfiguration() async throws -> ContextDefinitionConfiguration {
        var lastError: Error?
        for urlString in manifestURLs {
            do {
                guard let url = URL(string: urlString) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw BuiltInAIConfigurationError.unavailable
                }
                return try parseBuiltInConfiguration(from: data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? BuiltInAIConfigurationError.unavailable
    }

    private func parseBuiltInConfiguration(from data: Data) throws -> ContextDefinitionConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let share = root["share"] as? [String: Any] else {
            throw BuiltInAIConfigurationError.invalidManifest
        }
        let orderedKeys = share.keys.filter { $0.hasPrefix("key") }.sorted { lhs, rhs in
            let left = Int(lhs.dropFirst(3)) ?? Int.max
            let right = Int(rhs.dropFirst(3)) ?? Int.max
            return left < right
        }
        guard let keyName = orderedKeys.first,
              let keyInfo = share[keyName] as? [String: Any],
              let url = keyInfo["url"] as? String,
              let model = keyInfo["model"] as? String,
              let apiKeys = keyInfo["keys"] as? [String],
              let apiKey = apiKeys.first,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuiltInAIConfigurationError.invalidManifest
        }
        return ContextDefinitionConfiguration(enabled: true, baseURL: url, apiKey: apiKey, model: model)
    }
}
