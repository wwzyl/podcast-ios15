import SwiftUI

struct PodcastDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    let podcastID: String
    @State private var refreshing = false
    @State private var errorText: String?
    @State private var selectedEpisode: Episode?

    private var podcast: Podcast? { store.podcasts.first { $0.id == podcastID } }

    var body: some View {
        Group {
            if let podcast {
                List {
                    Section { header(podcast) }
                    Section("单集") {
                        ForEach(podcast.episodes) { episode in
                            Button { selectedEpisode = episode } label: { EpisodeRow(episode: episode) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { queueDownload(episode) } label: { Label("下载", systemImage: "arrow.down.circle") }
                                        .tint(AppTheme.purple)
                                }
                        }
                    }
                }.listStyle(.insetGrouped)
            } else { Text("播客已删除") }
        }
        .navigationTitle(podcast?.title ?? "播客").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedEpisode) { episode in
            NavigationView {
                PlayerView(episode: episode)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { selectedEpisode = nil } label: { Image(systemName: "chevron.down") }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { refresh() } label: { refreshing ? AnyView(ProgressView()) : AnyView(Image(systemName: "arrow.clockwise")) }.disabled(refreshing) } }
        .alert("刷新失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
    }

    private func header(_ podcast: Podcast) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CachedArtworkImage(url: podcast.artworkURL)
                .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(podcast.title).font(.title3.bold())
                Text(podcast.author).font(.subheadline).foregroundColor(.secondary)
                Text(podcast.summary).font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
        }.padding(.vertical, 6)
    }

    private func refresh() {
        guard let podcast else { return }
        refreshing = true
        Task {
            do { try await store.refresh(podcast) } catch { errorText = error.localizedDescription }
            refreshing = false
        }
    }

    private func queueDownload(_ episode: Episode) {
        Task { _ = try? await downloads.download(episode) }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(episode.title).font(.headline).lineLimit(2)
            Text(episode.summary).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
            HStack {
                if let date = episode.publishedAt { Text(date, style: .date) }
                if let duration = episode.duration { Text(duration.clockString) }
                if episode.transcriptURL != nil { Label("文本", systemImage: "captions.bubble") }
            }.font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 4)
    }
}
