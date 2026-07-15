import Foundation
import AVFoundation

enum AudioClipError: LocalizedError {
    case cannotCreateExporter, exportFailed
    var errorDescription: String? {
        switch self {
        case .cannotCreateExporter: return "无法创建原声例句片段"
        case .exportFailed: return "原声例句片段导出失败"
        }
    }
}

enum AudioClipStore {
    static func create(from sourceURL: URL, itemID: UUID, start: TimeInterval, end: TimeInterval?) async throws -> String {
        let filename = "sentence-\(itemID.uuidString).m4a"
        let destination = url(for: filename)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioClipError.cannotCreateExporter
        }
        let assetDuration = asset.duration.seconds
        let clipStart = max(0, start - 0.35)
        let requestedEnd = min(end ?? (start + 6), start + 18) + 0.35
        let clipEnd = assetDuration.isFinite ? min(assetDuration, requestedEnd) : requestedEnd
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: clipStart, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.5, clipEnd - clipStart), preferredTimescale: 600)
        )
        exporter.shouldOptimizeForNetworkUse = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .failed, .cancelled: continuation.resume(throwing: exporter.error ?? AudioClipError.exportFailed)
                default: continuation.resume(throwing: AudioClipError.exportFailed)
                }
            }
        }
        return filename
    }

    static func url(for filename: String) -> URL {
        rootURL.appendingPathComponent(filename)
    }

    static func remove(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VocabularyAudioClips", isDirectory: true)
    }
}
