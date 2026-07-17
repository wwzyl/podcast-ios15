import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    let episode: Episode
    @State private var activeEpisode: Episode
    @State private var isBoundToRequestedEpisode = false

    init(episode: Episode) {
        self.episode = episode
        _activeEpisode = State(initialValue: episode)
    }

    var body: some View {
        PlayerContentView(episode: activeEpisode)
            .id(activeEpisode.id)
            .onReceive(player.$episode) { value in
                guard let value else { return }
                if value.id == episode.id {
                    isBoundToRequestedEpisode = true
                    activeEpisode = value
                } else if isBoundToRequestedEpisode {
                    activeEpisode = value
                }
            }
    }
}

private struct PlayerContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    @EnvironmentObject private var transcription: TranscriptionManager
    let episode: Episode
    @State private var segments: [TranscriptSegment] = []
    @State private var loadingText = true
    @State private var errorText: String?
    @State private var lookupRequest: WordLookupRequest?
    @State private var analysisRequest: AIAnalysisRequest?
    @State private var translatingAll = false
    @State private var preparingAudio = false
    @State private var followPlayback = true
    @State private var searchText = ""
    @State private var bookmarkedTexts: Set<String> = []
    @State private var currentSentenceFrame: CGRect?
    @State private var transcriptViewportHeight: CGFloat = 0
    @State private var resumePlaybackAfterLookup = false
    @State private var sharePayload: SharePayload?
    @State private var editRequest: TranscriptEditRequest?

    private var currentIndex: Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.start <= player.currentTime } ?? 0
    }

    private var visibleIndices: [Int] {
        segments.indices.filter { index in
            return searchText.isEmpty || segments[index].text.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var currentSentenceIsVisible: Bool {
        guard transcriptViewportHeight > 0 else { return true }
        guard let frame = currentSentenceFrame else { return false }
        return frame.maxY > 0 && frame.minY < transcriptViewportHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                audioStatusBanner
                Group {
                    if loadingText { ProgressView("正在载入节目文本…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if segments.isEmpty { noTranscript }
                    else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(visibleIndices, id: \.self) { index in
                                    let segment = segments[index]
                                    SentenceRow(segment: segment, active: index == currentIndex,
                                                seek: { player.seek(to: segment.start) },
                                                translate: { translate(index) },
                                                learn: { selected in
                                                     beginLookup(segment: segment, selected: selected,
                                                                 previous: index > 0 ? segments[index - 1].text : nil,
                                                                 next: index + 1 < segments.count ? segments[index + 1].text : nil)
                                                 },
                                                 favorite: { saveSentence(segment) },
                                                 edit: { editRequest = TranscriptEditRequest(index: index, segment: segment) },
                                                 analyze: {
                                                     analysisRequest = AIAnalysisRequest(segment: segment,
                                                                                         previous: index > 0 ? segments[index - 1].text : nil,
                                                                                         next: index + 1 < segments.count ? segments[index + 1].text : nil)
                                                 },
                                                 bookmarked: bookmarkedTexts.contains(segment.text),
                                                 toggleBookmark: { toggleBookmark(segment) })
                                        .id(segment.id)
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: CurrentSentenceFramePreferenceKey.self,
                                                                   value: index == currentIndex ? geometry.frame(in: .named("transcriptScroll")) : nil)
                                        })
                                }
                            }
                            .padding(.horizontal, 18).padding(.bottom, 16)
                        }
                        .coordinateSpace(name: "transcriptScroll")
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 6).onChanged { _ in
                                if followPlayback { followPlayback = false }
                            }
                        )
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptViewportHeightPreferenceKey.self, value: geometry.size.height)
                        })
                        .onPreferenceChange(CurrentSentenceFramePreferenceKey.self) { currentSentenceFrame = $0 }
                        .onPreferenceChange(TranscriptViewportHeightPreferenceKey.self) { transcriptViewportHeight = $0 }
                        .overlay(alignment: .bottomTrailing) {
                            if !followPlayback || !currentSentenceIsVisible {
                                Button {
                                    followPlayback = true
                                    if let index = currentIndex, segments.indices.contains(index) {
                                        withAnimation { proxy.scrollTo(segments[index].id, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                                    }
                                } label: {
                                    Label("回到当前播放", systemImage: "location.fill")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                                .padding(14)
                            }
                        }
                        .onChange(of: currentIndex) { index in
                            if store.lockScreenShowsTranscript, let index, segments.indices.contains(index) {
                                player.updateNowPlayingSubtitle(segments[index].text)
                            } else if !store.lockScreenShowsTranscript {
                                player.updateNowPlayingSubtitle(nil)
                            }
                            if store.autoTranslateCurrentSentence, let index, segments.indices.contains(index),
                               (segments[index].translation ?? "").isEmpty {
                                translate(index)
                            }
                            guard followPlayback, let index, segments.indices.contains(index) else { return }
                            withAnimation { proxy.scrollTo(segments[index].id, anchor: UnitPoint(x: 0.5, y: 0.34)) }
                        }
                    }
                }
            }
        }
        .navigationTitle(episode.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { followPlayback.toggle() } label: { Label(followPlayback ? "停止跟随文本" : "跟随播放位置", systemImage: followPlayback ? "location.fill" : "location") }
                    Menu("调整字幕时间轴") {
                        Button("整体提前 0.5 秒") { shiftTranscript(by: -0.5) }
                        Button("整体延后 0.5 秒") { shiftTranscript(by: 0.5) }
                    }
                    Button { translateAll() } label: { Label("翻译全文", systemImage: "character.bubble") }.disabled(translatingAll || segments.isEmpty)
                    Button { exportTranscript() } label: { Label("导出文本", systemImage: "square.and.arrow.up") }.disabled(segments.isEmpty)
                    Menu("从头重新转写") {
                        Button("使用 Scribe v2") { transcribeAudio(using: .scribe) }
                        Menu("使用 Whisper") {
                            Button("极速") { transcribeAudio(using: .whisperFast) }
                            Button("均衡（更准确）") { transcribeAudio(using: .whisperBalanced) }
                            Button("英语极速") { transcribeAudio(using: .whisperFastEnglish) }
                            Button("英语均衡（更准确）") { transcribeAudio(using: .whisperBalancedEnglish) }
                        }
                    }.disabled(transcription.state(for: episode).isRunning)
                    Menu("从当前位置重新转写") {
                        Button("使用 Scribe v2") { retranscribeFromCurrent(using: .scribe) }
                        Menu("使用 Whisper") {
                            Button("极速") { retranscribeFromCurrent(using: .whisperFast) }
                            Button("均衡（更准确）") { retranscribeFromCurrent(using: .whisperBalanced) }
                            Button("英语极速") { retranscribeFromCurrent(using: .whisperFastEnglish) }
                            Button("英语均衡（更准确）") { retranscribeFromCurrent(using: .whisperBalancedEnglish) }
                        }
                    }.disabled(transcription.state(for: episode).isRunning)
                    Divider()
                    Button { player.playPrevious() } label: { Label("播放上一集", systemImage: "backward.end") }
                    Button { player.playNext() } label: { Label("播放下一集", systemImage: "forward.end") }
                    Menu("睡眠定时") {
                        ForEach([10, 20, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟") { player.setSleepTimer(minutes: minutes) } }
                        Button("关闭定时") { player.setSleepTimer(minutes: nil) }
                    }
                    Button { store.importedTranscript = nil; loadTranscript() } label: { Label("重新载入文本", systemImage: "arrow.clockwise") }
                } label: { if translatingAll { ProgressView() } else { Image(systemName: "ellipsis.circle") } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { FullPlayerControls() }
        .searchable(text: $searchText, prompt: "搜索文稿")
        .sheet(item: $lookupRequest, onDismiss: finishLookup) { request in
            WordLearningView(episode: episode, request: request)
        }
        .sheet(item: $analysisRequest) { request in
            AIAnalysisView(request: request)
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: [payload.text])
        }
        .sheet(item: $editRequest) { request in
            TranscriptEditView(request: request) { text, translation in
                guard segments.indices.contains(request.index) else { return }
                let old = segments[request.index]
                segments[request.index] = TranscriptSegment(id: old.id, start: old.start, end: old.end,
                                                             text: text, translation: translation.isEmpty ? nil : translation)
                try? TranscriptCache.save(segments, episodeID: episode.id)
            }
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
        .onAppear {
            if let podcast = store.podcasts.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) }) {
                player.setQueue(podcast.episodes, current: episode)
            }
            bookmarkedTexts = TranscriptBookmarkStore.load(episodeID: episode.id)
            prepareAudio()
            if segments.isEmpty { loadTranscript() }
        }
        .onReceive(transcription.$jobs) { jobs in
            guard let state = jobs[episode.id] else { return }
            if !state.segments.isEmpty { segments = state.segments; loadingText = false }
        }
        .onChange(of: store.importedTranscript) { imported in if let imported { segments = imported; loadingText = false } }
    }

    private var noTranscript: some View {
        VStack(spacing: 15) {
            Image(systemName: "captions.bubble").font(.system(size: 55)).foregroundColor(AppTheme.purple)
            Text("这一集没有附带逐句文本").font(.title3.bold())
            Text("请选择使用云端 Scribe v2，或本地 Whisper 极速/均衡模式生成逐句稿。")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if transcription.state(for: episode).isRunning {
                VStack(spacing: 8) {
                    ProgressView(value: transcription.state(for: episode).progress)
                    Text(transcription.state(for: episode).statusText ?? "\(transcription.state(for: episode).engine.title) 正在转录 \(Int(transcription.state(for: episode).progress * 100))% · 完整句生成后立即显示")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else if transcription.state(for: episode).errorMessage != nil {
                EmptyView()
            } else {
                HStack {
                    Button("Scribe v2") { transcribeAudio(using: .scribe) }
                        .buttonStyle(.borderedProminent)
                    Menu("Whisper") {
                        Button("极速") { transcribeAudio(using: .whisperFast) }
                        Button("均衡（更准确）") { transcribeAudio(using: .whisperBalanced) }
                        Button("英语极速") { transcribeAudio(using: .whisperFastEnglish) }
                        Button("英语均衡（更准确）") { transcribeAudio(using: .whisperBalancedEnglish) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var audioStatusBanner: some View {
        switch downloads.state(for: episode) {
        case .queued:
            HStack { ProgressView(); Text("已加入下载队列") }
                .font(.caption).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.purple.opacity(0.09))
        case .downloading(let progress, _, _):
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(downloads.state(for: episode).statusText ?? "正在下载音频"); Spacer(); Text("\(Int(progress * 100))%") }
                    .font(.caption)
                ProgressView(value: progress)
            }.padding(.horizontal, 16).padding(.vertical, 9).background(AppTheme.purple.opacity(0.09))
        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text(message).font(.caption).lineLimit(2)
                Spacer()
                Button("重试") { prepareAudio(retry: true) }
            }.padding(10).background(Color.orange.opacity(0.12))
        case .ready:
            if transcription.state(for: episode).isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    Text(transcription.state(for: episode).statusText ?? "\(transcription.state(for: episode).engine.title) 正在转录 \(Int(transcription.state(for: episode).progress * 100))%").font(.caption)
                    ProgressView(value: transcription.state(for: episode).progress)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(AppTheme.purple.opacity(0.09))
            } else if let message = transcription.state(for: episode).errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(transcription.state(for: episode).engine.title) 转录失败：\(message)", systemImage: "exclamationmark.triangle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("重试 Scribe") { retryTranscription(using: .scribe) }
                            .buttonStyle(.borderedProminent)
                        Menu("改用 Whisper") {
                            Button("极速") { retryTranscription(using: .whisperFast) }
                            Button("均衡（更准确）") { retryTranscription(using: .whisperBalanced) }
                            Button("英语极速") { retryTranscription(using: .whisperFastEnglish) }
                            Button("英语均衡（更准确）") { retryTranscription(using: .whisperBalancedEnglish) }
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            } else if preparingAudio { ProgressView("下载完成，正在准备播放…").font(.caption).padding(9) }
        case .idle:
            if preparingAudio { ProgressView("正在连接音频服务器…").font(.caption).padding(9) }
        }
    }

    private func prepareAudio(retry: Bool = false) {
        if player.episode?.id == episode.id {
            if downloads.localURL(for: episode) == nil {
                Task {
                    _ = try? await downloads.download(episode)
                }
            }
            return
        }
        preparingAudio = true
        Task {
            do {
                let url = retry ? try await downloads.retry(episode) : try await downloads.download(episode)
                player.load(episode, sourceURL: url)
            } catch {
                errorText = "音频准备失败：\(error.localizedDescription)"
            }
            preparingAudio = false
        }
    }

    private func loadTranscript() {
        loadingText = true
        Task {
            if let local = store.importedTranscript ?? TranscriptCache.load(episodeID: episode.id), !local.isEmpty {
                segments = local
            } else {
                do { segments = try await TranscriptService().load(for: episode) }
                catch TranscriptError.empty { segments = [] }
                catch { segments = []; errorText = error.localizedDescription }
            }
            loadingText = false
        }
    }

    private func transcribeAudio(using engine: TranscriptionEngine) {
        loadingText = false
        Task {
            do {
                let audioURL = try await downloads.download(episode)
                segments = []
                transcription.restart(episode: episode, audioURL: audioURL, engine: engine)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func retryTranscription(using engine: TranscriptionEngine) {
        Task {
            do {
                let audioURL = try await downloads.download(episode)
                transcription.retry(episode: episode, audioURL: audioURL, engine: engine)
            } catch { errorText = "重试转录失败：\(error.localizedDescription)" }
        }
    }

    private func retranscribeFromCurrent(using engine: TranscriptionEngine) {
        Task {
            do {
                let audioURL = try await downloads.download(episode)
                transcription.retranscribe(episode: episode, audioURL: audioURL, from: player.currentTime, engine: engine)
            } catch { errorText = "重新转录失败：\(error.localizedDescription)" }
        }
    }

    private func toggleBookmark(_ segment: TranscriptSegment) {
        if bookmarkedTexts.contains(segment.text) { bookmarkedTexts.remove(segment.text) }
        else { bookmarkedTexts.insert(segment.text) }
        TranscriptBookmarkStore.save(bookmarkedTexts, episodeID: episode.id)
    }

    private func beginLookup(segment: TranscriptSegment, selected: String, previous: String?, next: String?) {
        let value = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.lookupAutoCopy, !value.isEmpty { UIPasteboard.general.string = value }
        if store.lookupPausePlayback, player.isPlaying {
            resumePlaybackAfterLookup = store.lookupResumePlayback
            player.toggle()
        } else {
            resumePlaybackAfterLookup = false
        }
        if store.lookupOpenEudicDirectly, !value.isEmpty {
            EudicService.open(value)
            finishLookup()
            return
        }
        lookupRequest = WordLookupRequest(segment: segment, selectedText: value, previous: previous, next: next)
    }

    private func finishLookup() {
        if resumePlaybackAfterLookup, !player.isPlaying { player.toggle() }
        resumePlaybackAfterLookup = false
    }

    private func exportTranscript() {
        let text = segments.map { segment -> String in
            var lines: [String] = []
            if store.exportIncludeTimestamps { lines.append("[\(segment.start.clockString)]") }
            lines.append(segment.text)
            if store.exportIncludeTranslations, let translation = segment.translation, !translation.isEmpty {
                lines.append(translation)
            }
            return lines.joined(separator: " ")
        }.joined(separator: "\n\n")
        sharePayload = SharePayload(text: text)
    }

    private func shiftTranscript(by offset: TimeInterval) {
        guard !segments.isEmpty, !transcription.state(for: episode).isRunning else { return }
        segments = segments.map {
            TranscriptSegment(id: $0.id,
                              start: max(0, $0.start + offset),
                              end: $0.end.map { max(0, $0 + offset) },
                              text: $0.text,
                              translation: $0.translation)
        }
        try? TranscriptCache.save(segments, episodeID: episode.id)
        try? TranscriptCache.markComplete(episodeID: episode.id)
    }

    private func translate(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        Task {
            do {
                let result = try await TranslationService.shared.translate(
                    segments[index].text,
                    to: store.targetLanguage,
                    configuration: store.translationConfiguration)
                segments[index].translation = result
            } catch { errorText = "翻译失败：\(error.localizedDescription)" }
        }
    }

    private func translateAll() {
        translatingAll = true
        Task {
            do {
                for index in segments.indices {
                    segments[index].translation = try await TranslationService.shared.translate(
                        segments[index].text,
                        to: store.targetLanguage,
                        configuration: store.translationConfiguration)
                }
            } catch { errorText = "全文翻译失败：\(error.localizedDescription)" }
            translatingAll = false
        }
    }

    private func saveSentence(_ segment: TranscriptSegment) {
        guard let sourceURL = downloads.localURL(for: episode) else {
            errorText = "音频尚未下载完成，不能保存原声句子。"
            return
        }
        Task {
            do {
                let itemID = UUID()
                let clip = try await AudioClipStore.create(from: sourceURL, itemID: itemID, start: segment.start, end: segment.end)
                var translated = segment.translation ?? ""
                if translated.isEmpty { translated = (try? await TranslationService.shared.translate(segment.text, to: store.targetLanguage, configuration: store.translationConfiguration)) ?? "" }
                store.addVocabulary(VocabularyItem(id: itemID, word: "★ 收藏句子", sentence: segment.text, sentenceTranslation: translated, podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: segment.start, audioClipFilename: clip))
            } catch { errorText = "收藏原声句子失败：\(error.localizedDescription)" }
        }
    }
}

private struct CurrentSentenceFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct TranscriptViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AIAnalysisRequest: Identifiable {
    let id = UUID()
    let segment: TranscriptSegment
    let previous: String?
    let next: String?
}

private struct TranscriptEditRequest: Identifiable {
    let id = UUID()
    let index: Int
    let segment: TranscriptSegment
}

private struct TranscriptEditView: View {
    @Environment(\.dismiss) private var dismiss
    let request: TranscriptEditRequest
    let save: (String, String) -> Void
    @State private var text: String
    @State private var translation: String

    init(request: TranscriptEditRequest, save: @escaping (String, String) -> Void) {
        self.request = request
        self.save = save
        _text = State(initialValue: request.segment.text)
        _translation = State(initialValue: request.segment.translation ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("文本") { TextEditor(text: $text).frame(minHeight: 140) }
                Section("翻译") { TextEditor(text: $translation).frame(minHeight: 120) }
            }
            .navigationTitle("编辑段落").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        save(value, translation.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AIAnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    let request: AIAnalysisRequest
    @State private var result = ""
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.segment.text)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if loading {
                        HStack { ProgressView(); Text("正在分析…") }.frame(maxWidth: .infinity)
                    } else if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    } else {
                        MarkdownText(result)
                    }
                }.padding(18)
            }
            .navigationTitle("AI 分析").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("重新分析") { analyze() }.disabled(loading) }
            }
            .onAppear { analyze() }
        }
    }

    private func analyze() {
        loading = true
        errorText = nil
        Task {
            do {
                let stream = AIAnalysisService().analyzeStream(
                    kind: .sentence,
                    previous: request.previous,
                    sentence: request.segment.text,
                    next: request.next,
                    outputLanguage: store.aiOutputLanguage,
                    style: store.resolvedAIExplanationStyle,
                    configuration: ContextDefinitionConfiguration(enabled: true,
                                                                  baseURL: store.contextGPTBaseURL,
                                                                  apiKey: store.contextGPTAPIKey,
                                                                  model: store.contextGPTModel))
                for try await partial in stream { result = partial }
            } catch { errorText = "分析失败：\(error.localizedDescription)" }
            loading = false
        }
    }
}

private struct SentenceRow: View {
    let segment: TranscriptSegment
    let active: Bool
    let seek: () -> Void
    let translate: () -> Void
    let learn: (String) -> Void
    let favorite: () -> Void
    let edit: () -> Void
    let analyze: () -> Void
    let bookmarked: Bool
    let toggleBookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(segment.start.clockString, action: seek).font(.subheadline).foregroundColor(active ? AppTheme.purple : .secondary)
                Spacer()
                Menu {
                    Button(action: translate) { Label("翻译这句话", systemImage: "character.bubble") }
                    Button(action: analyze) { Label("AI 分析", systemImage: "sparkles") }
                    Button(action: edit) { Label("编辑文本和翻译", systemImage: "pencil") }
                    Button { learn("") } label: { Label("查词并加入生词", systemImage: "text.magnifyingglass") }
                    Button(action: favorite) { Label("收藏句子", systemImage: "bookmark") }
                    Button(action: toggleBookmark) { Label(bookmarked ? "移除书签" : "添加书签", systemImage: bookmarked ? "bookmark.slash" : "bookmark.fill") }
                    Button(action: seek) { Label("从这里播放", systemImage: "play") }
                } label: { Image(systemName: bookmarked ? "bookmark.fill" : "ellipsis").foregroundColor(bookmarked ? AppTheme.purple : .secondary).frame(width: 34, height: 28) }
            }
            SelectableTranscriptText(text: segment.text, active: active, onTap: seek, onSelection: learn)
            if let translation = segment.translation, !translation.isEmpty {
                Text(translation).font(.system(size: 16)).foregroundColor(AppTheme.purple).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, active ? 10 : 0)
        .background(active ? AppTheme.purple.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct FullPlayerControls: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(spacing: 5) {
            if let status = player.playbackStatus {
                HStack(spacing: 7) { ProgressView(); Text(status) }
                    .font(.caption).foregroundColor(.secondary)
            }
            if let end = player.sleepTimerEnd {
                Label("睡眠定时：\(end, style: .timer)", systemImage: "moon.zzz")
                    .font(.caption).foregroundColor(.secondary)
            }
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
            HStack { Text(player.currentTime.clockString); Spacer(); Text("−" + max(0, player.duration - player.currentTime).clockString) }
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            HStack {
                Menu { ForEach([0.5,0.75,1,1.25,1.5,2], id: \.self) { value in Button("\(value, specifier: "%g")×") { player.rate = Float(value) } } } label: { Text("\(player.rate, specifier: "%g")×").frame(width: 48) }
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 35)).frame(width: 48, height: 44) }
                Spacer()
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Button { player.playNext() } label: { Image(systemName: "forward.end.fill").frame(width: 48) }
            }.font(.title2).foregroundColor(AppTheme.purple)
        }
        .padding(.horizontal, 18).padding(.top, 5).padding(.bottom, 5)
        .background(.ultraThinMaterial).overlay(alignment: .top) { Divider() }
    }
}

private struct WordLookupRequest: Identifiable {
    let id = UUID()
    let segment: TranscriptSegment
    let selectedText: String
    let previous: String?
    let next: String?
}

private struct WordLearningView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    let episode: Episode
    let request: WordLookupRequest
    @State private var word = ""
    @State private var phonetic = ""
    @State private var definition = ""
    @State private var translation = ""
    @State private var aiExplanation = ""
    @State private var sentenceTranslation = ""
    @State private var contextMeaningSource = ""
    @State private var frequency: WordFrequency?
    @State private var loading = false
    @State private var aiExplaining = false
    @State private var showSystemDictionary = false
    @State private var errorText: String?

    init(episode: Episode, request: WordLookupRequest) {
        self.episode = episode
        self.request = request
        _word = State(initialValue: request.selectedText)
        _sentenceTranslation = State(initialValue: request.segment.translation ?? "")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("原句").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        SelectableSentenceView(text: request.segment.text) { selection in
                        word = selection
                        phonetic = ""
                        definition = ""
                        translation = ""
                        aiExplanation = ""
                        contextMeaningSource = ""
                        frequency = nil
                    }
                    .frame(minHeight: 80)
                    Text("长按单词或拖动选择词组；播放页也可以直接长按。")
                        .font(.caption).foregroundColor(.secondary)
                    if !sentenceTranslation.isEmpty {
                        Divider()
                        Text(sentenceTranslation).foregroundColor(AppTheme.purple)
                    }
                    }
                    .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                    Text("所选单词或词组").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    TextField("输入或粘贴单词", text: $word).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.title2.weight(.semibold))
                    Button { lookup() } label: {
                        HStack { Spacer(); if loading { ProgressView() }; Text(loading ? "正在结合上下文查询…" : "查询语境词义"); Spacer() }
                    }
                    .buttonStyle(.borderedProminent).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    Button { explainWithAI() } label: {
                        HStack { Spacer(); if aiExplaining { ProgressView() }; Label(aiExplaining ? "正在解释…" : "AI 解释", systemImage: "sparkles"); Spacer() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiExplaining)
                    }

                    if !translation.isEmpty {
                        resultCard(title: contextMeaningSource.isEmpty ? "在这里的意思" : contextMeaningSource,
                                   systemImage: "sparkles", color: AppTheme.purple) {
                            MarkdownText(translation, color: AppTheme.purple)
                        }
                    }
                    if !aiExplanation.isEmpty {
                        resultCard(title: "AI 解释", systemImage: "sparkles", color: AppTheme.purple) {
                            MarkdownText(aiExplanation)
                        }
                    }
                    if !phonetic.isEmpty || frequency != nil {
                        resultCard(title: "词汇信息", systemImage: "textformat.abc", color: .blue) {
                            if !phonetic.isEmpty { Text(phonetic).font(.title3).foregroundColor(.secondary) }
                            if let frequency {
                                Label("COCA #\(frequency.rank) · \(frequency.level)\(frequency.partOfSpeech.isEmpty ? "" : " · \(frequency.partOfSpeech)")", systemImage: "chart.bar.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if !definition.isEmpty {
                        resultCard(title: "英文词典释义", systemImage: "book.closed", color: .orange) {
                            Text(definition).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !word.isEmpty {
                        resultCard(title: "更多词典", systemImage: "globe", color: .green) {
                            HStack {
                                Button("欧路词典") { openEudic() }
                                Spacer()
                                Button("系统词典") { showSystemDictionary = true }
                                Spacer()
                                Link("Cambridge", destination: dictionaryURL("https://dictionary.cambridge.org/dictionary/english-chinese-simplified/"))
                                Spacer()
                                Link("Collins", destination: dictionaryURL("https://www.collinsdictionary.com/dictionary/english/"))
                            }.font(.subheadline)
                        }
                    }
                    Button { save() } label: {
                        Label("收藏单词、例句翻译与原声", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
                .padding(18)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("上下文释义").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("收藏") { save() }.disabled(word.isEmpty || loading) }
            }
            .sheet(isPresented: $showSystemDictionary) { SystemDictionaryView(term: word) }
            .alert("查询失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
            .onAppear { if !word.isEmpty { lookup() } }
        }
    }

    private func resultCard<Content: View>(title: String, systemImage: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage).font(.headline).foregroundColor(color)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func lookup() {
        let selected = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        loading = true
        translation = ""
        contextMeaningSource = ""
        errorText = nil
        Task {
            let result = try? await DictionaryService().lookup(selected)
            let resolvedSentenceTranslation = sentenceTranslation.isEmpty
                ? ((try? await TranslationService.shared.translate(request.segment.text, to: store.targetLanguage, configuration: store.translationConfiguration)) ?? "")
                : sentenceTranslation
            let configuration = ContextDefinitionConfiguration(enabled: true,
                                                               baseURL: store.contextGPTBaseURL,
                                                               apiKey: store.contextGPTAPIKey,
                                                               model: store.contextGPTModel,
                                                               style: store.resolvedAIExplanationStyle)
            var translatedWord: String?
            do {
                translatedWord = try await ContextDefinitionService().meaning(
                    of: selected,
                    previous: request.previous,
                    sentence: request.segment.text,
                    next: request.next,
                    dictionary: result,
                    targetLanguage: store.targetLanguage,
                    configuration: configuration)
                contextMeaningSource = configuration.shouldUseAIProvider ? "GPT 上下文释义" : "上下文释义"
            } catch {
                errorText = error.localizedDescription
            }
            phonetic = result?.phonetic ?? ""
            definition = result?.definition ?? ""
            translation = translatedWord ?? ""
            sentenceTranslation = resolvedSentenceTranslation
            frequency = WordFrequencyService().lookup(selected)
            if result == nil && translatedWord == nil && errorText == nil {
                errorText = "未查询到结果，请检查网络或换用系统词典。"
            }
            loading = false
        }
    }

    private func explainWithAI() {
        let selected = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        aiExplaining = true
        errorText = nil
        Task {
            do {
                let stream = AIAnalysisService().analyzeStream(
                    kind: .expression(selected),
                    previous: request.previous,
                    sentence: request.segment.text,
                    next: request.next,
                    outputLanguage: store.aiOutputLanguage,
                    style: store.resolvedAIExplanationStyle,
                    configuration: ContextDefinitionConfiguration(enabled: true,
                                                                  baseURL: store.contextGPTBaseURL,
                                                                  apiKey: store.contextGPTAPIKey,
                                                                  model: store.contextGPTModel))
                for try await partial in stream { aiExplanation = partial }
            } catch { errorText = "AI 解释失败：\(error.localizedDescription)" }
            aiExplaining = false
        }
    }

    private func save() {
        loading = true
        Task {
            guard let sourceURL = downloads.localURL(for: episode) else {
                errorText = "整集音频尚未下载完成，暂时无法保存独立原声例句。"
                loading = false
                return
            }
            let selected = word.trimmingCharacters(in: .whitespacesAndNewlines)
            var savedPhonetic = phonetic
            var savedDefinition = definition
            var savedMeaning = translation
            var savedFrequency = frequency
            if savedMeaning.isEmpty || savedDefinition.isEmpty {
                let dictionary = try? await DictionaryService().lookup(selected)
                if savedPhonetic.isEmpty { savedPhonetic = dictionary?.phonetic ?? "" }
                if savedDefinition.isEmpty { savedDefinition = dictionary?.definition ?? "" }
                if savedMeaning.isEmpty {
                    savedMeaning = (try? await ContextDefinitionService().meaning(
                        of: selected,
                        previous: request.previous,
                        sentence: request.segment.text,
                        next: request.next,
                        dictionary: dictionary,
                        targetLanguage: store.targetLanguage,
                        configuration: ContextDefinitionConfiguration(enabled: true,
                                                                       baseURL: store.contextGPTBaseURL,
                                                                      apiKey: store.contextGPTAPIKey,
                                                                      model: store.contextGPTModel,
                                                                      style: store.resolvedAIExplanationStyle))) ?? ""
                }
            }
            if savedFrequency == nil { savedFrequency = WordFrequencyService().lookup(selected) }
            var savedSentenceTranslation = sentenceTranslation
            if savedSentenceTranslation.isEmpty {
                savedSentenceTranslation = (try? await TranslationService.shared.translate(request.segment.text, to: store.targetLanguage, configuration: store.translationConfiguration)) ?? ""
            }
            do {
                let itemID = UUID()
                let clip = try await AudioClipStore.create(from: sourceURL, itemID: itemID, start: request.segment.start, end: request.segment.end)
                store.addVocabulary(VocabularyItem(id: itemID, word: selected, phonetic: savedPhonetic, definition: savedDefinition, translation: savedMeaning, aiExplanation: aiExplanation.isEmpty ? nil : aiExplanation, sentence: request.segment.text, sentenceTranslation: savedSentenceTranslation, podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: request.segment.start, audioClipFilename: clip, frequencyRank: savedFrequency?.rank))
                loading = false
                dismiss()
            } catch {
                errorText = "保存原声例句失败：\(error.localizedDescription)"
                loading = false
            }
        }
    }

    private func dictionaryURL(_ base: String) -> URL {
        let encoded = word.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        return URL(string: base + encoded)!
    }

    private func openEudic() {
        EudicService.open(word)
    }
}

private struct MarkdownText: View {
    let source: String
    var color: Color = .primary

    init(_ source: String, color: Color = .primary) {
        self.source = source
        self.color = color
    }

    var body: some View {
        Text(attributed)
            .foregroundColor(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: source,
                               options: .init(interpretedSyntax: .full,
                                              failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(source)
    }
}

private struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SelectableSentenceView: UIViewRepresentable {
    let text: String
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIView(context: Context) -> UITextView {
        let view = LookupSentenceTextView()
        context.coordinator.textView = view
        view.delegate = context.coordinator
        view.text = text
        view.font = UIFont.systemFont(ofSize: 20)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        let selectionPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                           action: #selector(Coordinator.selectionGestureEnded(_:)))
        selectionPress.minimumPressDuration = 0.35
        selectionPress.cancelsTouchesInView = false
        selectionPress.delegate = context.coordinator
        view.addGestureRecognizer(selectionPress)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.invalidateIntrinsicContentSize()
        context.coordinator.onSelection = onSelection
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onSelection: (String) -> Void
        weak var textView: UITextView?
        private var pendingValue: String?
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else {
                pendingValue = nil
                return
            }
            let value = (textView.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingValue = value.isEmpty ? nil : value
        }

        @objc func selectionGestureEnded(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let range = textView.selectedRange
                guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else { return }
                let current = TranscriptSelection.expandedValue(in: textView) ?? ""
                let value = current.isEmpty ? self.pendingValue : current
                guard let value, !value.isEmpty else { return }
                self.pendingValue = nil
                self.onSelection(value)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

private final class LookupSentenceTextView: UITextView {
    private var lastWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 80) }
        return sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
