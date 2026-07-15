import SwiftUI
import UIKit
import CryptoKit

struct CachedArtworkImage: View {
    let url: URL?
    @StateObject private var loader = ArtworkImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "mic.fill").resizable().scaledToFit().padding(16).foregroundColor(.secondary.opacity(0.45))
                }
            }
        }
        .task(id: url) { await loader.load(url) }
    }
}

@MainActor
private final class ArtworkImageLoader: ObservableObject {
    @Published var image: UIImage?
    private static let memoryCache = NSCache<NSURL, UIImage>()

    func load(_ url: URL?) async {
        image = nil
        guard let url else { return }
        if let cached = Self.memoryCache.object(forKey: url as NSURL) { image = cached; return }
        let diskURL = Self.diskURL(for: url)
        if let data = try? Data(contentsOf: diskURL), let cached = UIImage(data: data) {
            Self.memoryCache.setObject(cached, forKey: url as NSURL)
            image = cached
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let downloaded = UIImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        Self.memoryCache.setObject(downloaded, forKey: url as NSURL)
        image = downloaded
        try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: diskURL, options: .atomic)
    }

    private static func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        return root.appendingPathComponent(digest + ".image")
    }
}
