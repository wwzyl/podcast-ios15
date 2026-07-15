import Foundation
import CryptoKit
import UIKit

enum EpisodeDownloadState: Equatable {
    case idle
    case queued
    case downloading(progress: Double, received: Int64, total: Int64)
    case ready(URL)
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle: return nil
        case .queued: return "已加入后台下载队列"
        case .downloading(let progress, let received, let total):
            if total > 0 { return "正在后台下载音频 \(Int(progress * 100))%（\(received.byteString) / \(total.byteString)）" }
            return "正在后台下载音频（已下载 \(received.byteString)）"
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

    private typealias Waiter = CheckedContinuation<URL, Error>
    private var waiters: [String: [Waiter]] = [:]
    private var activeTokens: [String: String] = [:]
    private let coordinator = BackgroundDownloadCoordinator.shared

    init() {
        let saved = UserDefaults.standard.object(forKey: "audioCachePolicy") as? Int ?? AudioCachePolicy.fifteenDays.rawValue
        cachePolicy = AudioCachePolicy(rawValue: saved) ?? .fifteenDays
        cleanupExpired()
        configureCoordinator()
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
        return try await withCheckedThrowingContinuation { continuation in
            waiters[episode.id, default: []].append(continuation)
            if activeTokens[episode.id] == nil {
                let token = UUID().uuidString
                activeTokens[episode.id] = token
                states[episode.id] = .queued
                updateQueuedCount()
                coordinator.start(episodeID: episode.id,
                                  token: token,
                                  remoteURL: episode.audioURL,
                                  destinationURL: destination(for: episode))
            }
        }
    }

    func retry(_ episode: Episode) async throws -> URL {
        if let oldToken = activeTokens.removeValue(forKey: episode.id) {
            coordinator.cancel(episodeID: episode.id, token: oldToken)
        }
        resumeWaiters(for: episode.id, result: .failure(CancellationError()))
        try? FileManager.default.removeItem(at: destination(for: episode))
        states[episode.id] = .idle
        updateQueuedCount()
        return try await download(episode)
    }

    func cleanupExpired() {
        guard cachePolicy != .never else { refreshCacheSize(); return }
        let cutoff = Date().addingTimeInterval(-Double(cachePolicy.rawValue) * 24 * 60 * 60)
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        refreshCacheSize()
    }

    func clearEpisodeCache() {
        coordinator.cancelAll()
        activeTokens.removeAll()
        for episodeID in Array(waiters.keys) { resumeWaiters(for: episodeID, result: .failure(CancellationError())) }
        states.removeAll()
        try? FileManager.default.removeItem(at: audioRoot)
        cacheSize = 0
        updateQueuedCount()
    }

    func refreshCacheSize() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        cacheSize = urls.reduce(0) { result, url in
            result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func configureCoordinator() {
        coordinator.onProgress = { [weak self] episodeID, token, received, total in
            Task { @MainActor in
                guard let self, self.activeTokens[episodeID] == token else { return }
                let progress = total > 0 ? min(1, Double(received) / Double(total)) : 0
                self.states[episodeID] = .downloading(progress: progress, received: received, total: total)
            }
        }
        coordinator.onCompletion = { [weak self] episodeID, token, result in
            Task { @MainActor in
                guard let self, self.activeTokens[episodeID] == token else { return }
                self.activeTokens[episodeID] = nil
                switch result {
                case .success(let url):
                    self.markAccess(url)
                    self.states[episodeID] = .ready(url)
                    self.refreshCacheSize()
                    self.resumeWaiters(for: episodeID, result: .success(url))
                case .failure(let error):
                    self.states[episodeID] = .failed(error.localizedDescription)
                    self.resumeWaiters(for: episodeID, result: .failure(error))
                }
                self.updateQueuedCount()
            }
        }
        coordinator.restoreTasks { [weak self] descriptors in
            Task { @MainActor in
                guard let self else { return }
                for descriptor in descriptors {
                    self.activeTokens[descriptor.episodeID] = descriptor.token
                    self.states[descriptor.episodeID] = .queued
                }
                self.updateQueuedCount()
            }
        }
    }

    private func resumeWaiters(for episodeID: String, result: Result<URL, Error>) {
        let values = waiters.removeValue(forKey: episodeID) ?? []
        for waiter in values { waiter.resume(with: result) }
    }

    private func updateQueuedCount() { queuedCount = activeTokens.count }

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

struct BackgroundDownloadDescriptor: Codable {
    let episodeID: String
    let token: String
    let destinationPath: String

    var encoded: String? {
        try? JSONEncoder().encode(self).base64EncodedString()
    }
    static func decode(_ value: String?) -> BackgroundDownloadDescriptor? {
        guard let value, let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

final class BackgroundDownloadCoordinator: NSObject, URLSessionDownloadDelegate, URLSessionDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloadCoordinator()
    static let sessionIdentifier = "com.podcastios15.app.episode-downloads"

    var onProgress: ((String, String, Int64, Int64) -> Void)?
    var onCompletion: ((String, String, Result<URL, Error>) -> Void)?
    private var movedURLs: [Int: URL] = [:]
    private var moveErrors: [Int: Error] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func start(episodeID: String, token: String, remoteURL: URL, destinationURL: URL) {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 60 * 60
        request.setValue("PodcastIOS15/1.3", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.taskDescription = BackgroundDownloadDescriptor(episodeID: episodeID, token: token, destinationPath: destinationURL.path).encoded
        task.resume()
    }

    func restoreTasks(completion: @escaping ([BackgroundDownloadDescriptor]) -> Void) {
        session.getAllTasks { tasks in
            completion(tasks.compactMap { BackgroundDownloadDescriptor.decode($0.taskDescription) })
        }
    }

    func cancel(episodeID: String, token: String) {
        session.getAllTasks { tasks in
            tasks.filter {
                let value = BackgroundDownloadDescriptor.decode($0.taskDescription)
                return value?.episodeID == episodeID && value?.token == token
            }.forEach { $0.cancel() }
        }
    }

    func cancelAll() { session.getAllTasks { $0.forEach { $0.cancel() } } }

    func handleEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let descriptor = BackgroundDownloadDescriptor.decode(downloadTask.taskDescription) else { return }
        onProgress?(descriptor.episodeID, descriptor.token, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor = BackgroundDownloadDescriptor.decode(downloadTask.taskDescription) else { return }
        let destination = URL(fileURLWithPath: descriptor.destinationPath)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            movedURLs[downloadTask.taskIdentifier] = destination
        } catch {
            moveErrors[downloadTask.taskIdentifier] = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let descriptor = BackgroundDownloadDescriptor.decode(task.taskDescription) else { return }
        let result: Result<URL, Error>
        if let error { result = .failure(error) }
        else if let moveError = moveErrors.removeValue(forKey: task.taskIdentifier) { result = .failure(moveError) }
        else if let url = movedURLs.removeValue(forKey: task.taskIdentifier) { result = .success(url) }
        else { result = .failure(URLError(.cannotCreateFile)) }
        onCompletion?(descriptor.episodeID, descriptor.token, result)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }
}

private extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
