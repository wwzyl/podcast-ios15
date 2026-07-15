import SwiftUI

@main
struct PodcastIOS15App: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var downloads = EpisodeDownloadManager()
    @StateObject private var transcription = TranscriptionManager()

    init() {
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 34, weight: .bold)]
        UITabBar.appearance().backgroundColor = UIColor.systemBackground
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(transcription)
                .tint(AppTheme.purple)
                .onOpenURL { url in store.importFile(url) }
        }
    }
}

enum AppTheme {
    static let purple = Color(red: 0.345, green: 0.337, blue: 0.878)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let secondary = Color(uiColor: .secondaryLabel)
}
