import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    @EnvironmentObject private var transcription: TranscriptionManager

    var body: some View {
        TabView {
            NavigationView { AudioHomeView().miniPlayerInset() }
                .navigationViewStyle(.stack)
                .tabItem { Label("音频", systemImage: "waveform") }
            NavigationView { VocabularyView().miniPlayerInset() }
                .navigationViewStyle(.stack)
                .tabItem { Label("生词", systemImage: "book.fill") }
            NavigationView { MoreView().miniPlayerInset() }
                .navigationViewStyle(.stack)
                .tabItem { Label("更多", systemImage: "ellipsis") }
        }
        // 下载和转录的衔接放在 App 根视图，不能依赖播放页仍然存在。
        .onReceive(downloads.$states) { states in
            for podcast in store.podcasts {
                for episode in podcast.episodes where episode.transcriptURL == nil {
                    guard case .ready(let audioURL) = states[episode.id] else { continue }
                    transcription.start(episode: episode, audioURL: audioURL)
                }
            }
        }
        .task { await store.repairMissingArtwork() }
    }
}

private struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    let episode: Episode
    let openPlayer: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openPlayer) {
                HStack(spacing: 12) {
                    CachedArtworkImage(url: episode.artworkURL)
                        .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundColor(.primary)
                        Text(player.playbackStatus ?? player.currentTime.clockString).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 30) }
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
        }
        .padding(.horizontal).frame(height: 58)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MiniPlayerInsetModifier: ViewModifier {
    @EnvironmentObject private var player: PlayerManager
    @State private var showingPlayer = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let episode = player.episode {
                    MiniPlayerView(episode: episode) { showingPlayer = true }
                }
            }
            .fullScreenCover(isPresented: $showingPlayer) {
                if let episode = player.episode { PresentedPlayerView(episode: episode) }
            }
    }
}

private struct PresentedPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    var body: some View {
        NavigationView {
            PlayerView(episode: episode)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

private extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInsetModifier()) }
}
