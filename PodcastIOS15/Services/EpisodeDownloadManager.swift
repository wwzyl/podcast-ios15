import Foundation
import CryptoKit

enum EpisodeDownloadState: Equatable {
    case idle
    case queued
    case downloading(progress: Double, received: Int64, total: Int64)
    case ready(URL)
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle: return nil
        case .queued: return "已加入下载队列"
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
    @Published private(set) var queuedCount = 0
    @Published var cachePolicy: AudioCachePolicy {
        didSet {
            UserDefaults.standard.set(cachePolicy.rawValue, forKey: "audioCachePolicy")
            cleanupExpired()
        }
    }

    private var running: [String: Task<URL, Error>] = [:]
    private var activeTokens: [String: String] = [:]

    init() {
        let saved = UserDefaults.standard.object(forKey: "audioCachePolicy") as? Int ?? AudioCachePolicy.fifteenDays.rawValue
        cachePolicy = AudioCachePolicy(rawValue: saved) ?? .fifteenDays
        cleanupExpired()
        LegacyBackgroundDownloadCleaner.shared.cancelOutstandingTasks()
    }

    func state(for episode: Episode) -> EpisodeDownloadState {
        if let state = states[episode.id] { return state }
        if let url = localURL(for: episode) { return .ready(url) }
        return .idle
    }

    func localURL(for episode: Episode) -> URL? {
        let url = destination(for: episode)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return url }

        // RSS 有时会在刷新后把同一 enclosure 从 mp3 改成无扩展名或 m4a。
        // 缓存主键仍是稳定的 episode id，因此也复用同一摘要前缀下的旧文件。
        let prefix = episodeAudioFilenamePrefix + cacheStem(for: episode) + "."
        if let current = cachedAudioURLs.first(where: {
            guard $0.lastPathComponent.hasPrefix(prefix),
                  let size = try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size > 0
        }) { return current }

        return nil
    }

    func download(_ episode: Episode) async throws -> URL {
        if let local = localURL(for: episode) {
            markAccess(local)
            states[episode.id] = .ready(local)
            return local
        }
        if let task = running[episode.id] {
            return try await task.value
        }

        let token = UUID().uuidString
        activeTokens[episode.id] = token
        states[episode.id] = .queued
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performDownload(episode, token: token)
        }
        running[episode.id] = task
        updateQueuedCount()

        do {
            let url = try await task.value
            if activeTokens[episode.id] == token {
                activeTokens[episode.id] = nil
                running[episode.id] = nil
                markAccess(url)
                states[episode.id] = .ready(url)
                refreshCacheSize()
                updateQueuedCount()
            }
            return url
        } catch {
            if activeTokens[episode.id] == token {
                activeTokens[episode.id] = nil
                running[episode.id] = nil
                states[episode.id] = .failed(error.localizedDescription)
                updateQueuedCount()
            }
            throw error
        }
    }

    func retry(_ episode: Episode) async throws -> URL {
        running.removeValue(forKey: episode.id)?.cancel()
        activeTokens[episode.id] = nil
        if let local = localURL(for: episode) { try? FileManager.default.removeItem(at: local) }
        try? FileManager.default.removeItem(at: destination(for: episode))
        removePartialFiles(for: episode)
        states[episode.id] = .idle
        updateQueuedCount()
        return try await download(episode)
    }

    func cleanupExpired() {
        guard cachePolicy != .never else { refreshCacheSize(); return }
        let cutoff = Date().addingTimeInterval(-Double(cachePolicy.rawValue) * 24 * 60 * 60)
        let urls = cachedAudioURLs
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        refreshCacheSize()
    }

    func clearEpisodeCache() {
        for task in running.values { task.cancel() }
        running.removeAll()
        activeTokens.removeAll()
        states.removeAll()
        for url in episodeAudioURLs { try? FileManager.default.removeItem(at: url) }
        cacheSize = 0
        updateQueuedCount()
    }

    func refreshCacheSize() {
        let urls = cachedAudioURLs
        cacheSize = urls.reduce(0) { result, url in
            result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func performDownload(_ episode: Episode, token: String) async throws -> URL {
        let destination = destination(for: episode)
        var request = URLRequest(url: episode.audioURL)
        request.timeoutInterval = 60 * 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("PodcastIOS15/1.6.1", forHTTPHeaderField: "User-Agent")

        let downloader = StreamingAudioDownloader(destination: destination) { [weak self] received, total in
            Task { @MainActor in
                guard let self, self.activeTokens[episode.id] == token else { return }
                let progress = total > 0 ? min(1, Double(received) / Double(total)) : 0
                self.states[episode.id] = .downloading(progress: progress, received: received, total: total)
            }
        }
        return try await withTaskCancellationHandler {
            try await downloader.download(request)
        } onCancel: {
            downloader.cancel()
        }
    }

    private func updateQueuedCount() { queuedCount = activeTokens.count }

    private func destination(for episode: Episode) -> URL {
        let ext = episode.audioURL.pathExtension.isEmpty ? "m4a" : episode.audioURL.pathExtension
        return audioRoot.appendingPathComponent("\(episodeAudioFilenamePrefix)\(cacheStem(for: episode)).\(ext)")
    }

    private func cacheStem(for episode: Episode) -> String {
        episodeAudioDigest(episode.id)
    }

    private var audioRoot: URL {
        // 不再创建 EpisodeAudio 子目录，直接使用系统保证可写的 Caches 根目录。
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    private var cachedAudioURLs: [URL] {
        episodeAudioURLs.filter { !$0.lastPathComponent.hasSuffix(".partial") }
    }

    private var episodeAudioURLs: [URL] {
        let values = (try? FileManager.default.contentsOfDirectory(at: audioRoot,
                                                                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                                  options: [])) ?? []
        return values.filter {
            $0.lastPathComponent.contains(episodeAudioFilenamePrefix) &&
            ($0.lastPathComponent.hasPrefix(episodeAudioFilenamePrefix) || $0.lastPathComponent.hasPrefix("." + episodeAudioFilenamePrefix))
        }
    }

    private func removePartialFiles(for episode: Episode) {
        let marker = episodeAudioFilenamePrefix + cacheStem(for: episode)
        for url in episodeAudioURLs where url.lastPathComponent.contains(marker) && url.lastPathComponent.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func markAccess(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

private final class StreamingAudioDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let staging: URL
    private let progressHandler: (Int64, Int64) -> Void
    private let stateLock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelRequested = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var output: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var writeError: Error?
    private var finished = false
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PodcastIOS15.AudioStreamingPersistence"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    init(destination: URL, progressHandler: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        self.progressHandler = progressHandler
    }

    func download(_ request: URLRequest) async throws -> URL {
        try prepareOutput()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.dataTask(with: request)
            stateLock.lock()
            self.task = task
            let shouldCancel = cancelRequested
            stateLock.unlock()
            if shouldCancel { task.cancel() } else { task.resume() }
        }
    }

    func cancel() {
        stateLock.lock()
        cancelRequested = true
        let task = task
        stateLock.unlock()
        task?.cancel()
    }

    private func prepareOutput() throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        output = try FileHandle(forWritingTo: staging)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            writeError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        total = max(0, response.expectedContentLength)
        progressHandler(0, total)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard writeError == nil, let output else { return }
        do {
            try output.write(contentsOf: data)
            received += Int64(data.count)
            progressHandler(received, total)
        } catch {
            writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let writeError {
            finish(.failure(writeError))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        guard received > 0 else {
            finish(.failure(URLError(.zeroByteResource)))
            return
        }
        do {
            try output?.synchronize()
            try output?.close()
            output = nil
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: destination.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var persistedURL = destination
            try? persistedURL.setResourceValues(values)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        try? output?.close()
        output = nil
        if case .failure = result { try? FileManager.default.removeItem(at: staging) }
        continuation?.resume(with: result)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

final class LegacyBackgroundDownloadCleaner: NSObject, URLSessionDownloadDelegate, URLSessionDelegate, @unchecked Sendable {
    static let shared = LegacyBackgroundDownloadCleaner()
    static let sessionIdentifier = "com.podcastios15.app.episode-downloads"

    private var backgroundCompletionHandler: (() -> Void)?
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PodcastIOS15.LegacyBackgroundDownloadCleanup"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    func cancelOutstandingTasks() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Legacy tasks are deliberately discarded. New downloads never use CFNetwork temp files.
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }
}

private let episodeAudioFilenamePrefix = "PodcastEpisodeAudio-"

private func episodeAudioDigest(_ episodeID: String) -> String {
    SHA256.hash(data: Data(episodeID.utf8)).map { String(format: "%02x", $0) }.joined()
}

private extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
