import SwiftUI

struct AudioHomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showingAdd = false

    var body: some View {
        Group {
            if store.podcasts.isEmpty { emptyView }
            else {
                List {
                    ForEach(store.podcasts) { podcast in
                        NavigationLink(destination: PodcastDetailView(podcastID: podcast.id)) {
                            PodcastRow(podcast: podcast)
                        }
                        .swipeActions { Button(role: .destructive) { store.remove(podcast) } label: { Label("删除", systemImage: "trash") } }
                    }
                }.listStyle(.plain)
            }
        }
        .navigationTitle("音频")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showingAdd = true } label: { Image(systemName: "plus.circle") } } }
        .sheet(isPresented: $showingAdd) { AddPodcastView() }
    }

    private var emptyView: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 72)).foregroundColor(AppTheme.purple)
            Text("开始学习一档播客").font(.title2.bold())
            Text("搜索播客，或粘贴 RSS 地址订阅。\n带 Podcasting 2.0 文稿的节目可直接逐句学习。")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Button("添加播客") { showingAdd = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(28)
    }
}

private struct PodcastRow: View {
    let podcast: Podcast
    var body: some View {
        HStack(spacing: 13) {
            AsyncImage(url: podcast.artworkURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }
                .frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(podcast.title).font(.headline).lineLimit(2)
                Text(podcast.author).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                Text("\(podcast.episodes.count) 集").font(.caption).foregroundColor(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

private struct AddPodcastView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var feedText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                Section("RSS 地址") {
                    TextField("https://example.com/feed.xml", text: $feedText).textInputAutocapitalization(.never).keyboardType(.URL)
                    Button("订阅 RSS") { subscribe(feedText) }.disabled(URL(string: feedText) == nil || loading)
                }
                Section("搜索 Apple Podcasts") {
                    HStack {
                        TextField("播客名称", text: $query).onSubmit(search)
                        Button { search() } label: { Image(systemName: "magnifyingglass") }.disabled(query.isEmpty || loading)
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(results) { item in
                        Button { subscribe(item.feedUrl) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: item.artworkUrl600 ?? "")) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }
                                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading) {
                                    Text(item.collectionName).foregroundColor(.primary).font(.headline).lineLimit(2)
                                    Text(item.artistName).foregroundColor(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加播客").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
        }
    }

    private func search() {
        loading = true
        Task {
            do { results = try await PodcastSearchService().search(query) }
            catch { errorText = error.localizedDescription }
            loading = false
        }
    }
    private func subscribe(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        loading = true
        Task {
            do { try await store.subscribe(feedURL: url); dismiss() }
            catch { errorText = error.localizedDescription }
            loading = false
        }
    }
}

