import SwiftUI
import UIKit

@main
struct PodcastIOS15App: App {
    @UIApplicationDelegateAdaptor(PodcastAppDelegate.self) private var appDelegate
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

final class PodcastAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundDownloadCoordinator.shared.handleEvents(completionHandler: completionHandler)
    }
}

enum AppTheme {
    static let purple = Color(red: 0.345, green: 0.337, blue: 0.878)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let secondary = Color(uiColor: .secondaryLabel)
}
