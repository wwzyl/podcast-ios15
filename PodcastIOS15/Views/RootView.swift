import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        TabView {
            NavigationView { AudioHomeView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("音频", systemImage: "waveform") }
            NavigationView { VocabularyView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("生词", systemImage: "book.fill") }
            NavigationView { MoreView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("更多", systemImage: "ellipsis") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let episode = player.episode { MiniPlayerView(episode: episode) }
        }
    }
}

private struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: episode.artworkURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(player.currentTime.clockString).font(.caption).foregroundColor(.secondary)
            }
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

