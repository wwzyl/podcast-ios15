import Foundation
import CryptoKit

enum EpisodeDownloadState: Equatable {
    case idle
    case downloading(progress: Double, received: Int64, total: Int64)
    case ready(URL)
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle: return nil
        case .downloading(let progress, let received, let total):
            if total > 0 { return "正在下载音频 \(Int(progress * 100))%（\(received.byteString) / \(total.byteString)）" }
            return "正在下载音频（已下载 \(received.byteString)）"
        case .ready: return "音频下载完成"
        case .failed(let message): return "音频下载失败：\(message)"
        }
    }
}

enum AudioCachePolicy: Int, CaseIterable, Identifiable {
    case oneWeek = 7
    case fifteenDays = 15
    case oneMonth = 30
    case never = 0

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneWeek: return "1周后"
        case .fifteenDays: return "15天后"
        case .oneMonth: return "1个月后"
        case .never: return "不删除"
        }
    }
}

@MainActor
final class EpisodeDownloadManager: ObservableObject {
    @Published private(set) var states: [String: EpisodeDownloadState] = [:]
    @Published private(set) var cacheSize: Int64 = 0
    @Published var cachePolicy: AudioCachePolicy {
        didSet {
            UserDefaults.standard.set(cachePolicy.rawValue, forKey: "audioCachePolicy")
            cleanupExpired()
        }
    }
    private var running: [String: Task<URL, Error>] = [:]

    init() {
        let saved = UserDefaults.standard.object(forKey: "audioCachePolicy") as? Int ?? AudioCachePolicy.fifteenDays.rawValue
        cachePolicy = AudioCachePolicy(rawValue: saved) ?? .fifteenDays
        cleanupExpired()
    }

    func state(for episode: Episode) -> EpisodeDownloadState {
        if let state = states[episode.id] { return state }
        if let url = localURL(for: episode) { return .ready(url) }
        return .idle
    }

    func localURL(for episode: Episode) -> URL? {
        let url = destination(for: episode)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        return url
    }

    func download(_ episode: Episode) async throws -> URL {
        if let local = localURL(for: episode) {
            markAccess(local)
            states[episode.id] = .ready(local)
            return local
        }
        if let task = running[episode.id] { return try await task.value }

        let task = Task<URL, Error> {
            try await performDownload(episode)
        }
        running[episode.id] = task
        do {
            let url = try await task.value
            states[episode.id] = .ready(url)
            markAccess(url)
            refreshCacheSize()
            running[episode.id] = nil
            return url
        } catch {
            states[episode.id] = .failed(error.localizedDescription)
            running[episode.id] = nil
            throw error
        }
    }

    func retry(_ episode: Episode) async throws -> URL {
        running[episode.id]?.cancel()
        running[episode.id] = nil
        try? FileManager.default.removeItem(at: destination(for: episode))
        states[episode.id] = .idle
        return try await download(episode)
    }

    func cleanupExpired() {
        guard cachePolicy != .never else { refreshCacheSize(); return }
        let cutoff = Date().addingTimeInterval(-Double(cachePolicy.rawValue) * 24 * 60 * 60)
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension != "part" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        refreshCacheSize()
    }

    func clearEpisodeCache() {
        for task in running.values { task.cancel() }
        running.removeAll()
        states.removeAll()
        try? FileManager.default.removeItem(at: audioRoot)
        cacheSize = 0
    }

    func refreshCacheSize() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        cacheSize = urls.reduce(0) { result, url in
            result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func performDownload(_ episode: Episode) async throws -> URL {
        let destination = destination(for: episode)
        let partial = destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        var request = URLRequest(url: episode.audioURL)
        request.timeoutInterval = 60 * 30
        request.setValue("PodcastIOS15/1.0", forHTTPHeaderField: "User-Agent")
        let loader = DownloadEventLoader()
        var received: Int64 = 0
        var total: Int64 = 0
        do {
            for try await event in loader.events(for: request) {
                try Task.checkCancellation()
                switch event {
                case .response(let expected):
                    total = max(0, expected)
                    states[episode.id] = .downloading(progress: 0, received: 0, total: total)
                case .data(let data):
                    try handle.write(contentsOf: data)
                    received += Int64(data.count)
                    let progress = total > 0 ? min(1, Double(received) / Double(total)) : 0
                    states[episode.id] = .downloading(progress: progress, received: received, total: total)
                }
            }
            guard received > 0 else { throw URLError(.zeroByteResource) }
            try handle.synchronize()
            try handle.close()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func destination(for episode: Episode) -> URL {
        let digest = SHA256.hash(data: Data(episode.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = episode.audioURL.pathExtension.isEmpty ? "m4a" : episode.audioURL.pathExtension
        return audioRoot.appendingPathComponent("\(digest).\(ext)")
    }

    private var audioRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EpisodeAudio", isDirectory: true)
    }

    private func markAccess(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

private enum DownloadEvent {
    case response(Int64)
    case data(Data)
}

private final class DownloadEventLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation?
    private var session: URLSession?

    func events(for request: URLRequest) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 30
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            continuation.onTermination = { [weak self] _ in self?.session?.invalidateAndCancel() }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        continuation?.yield(.response(response.expectedContentLength))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}

private extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
