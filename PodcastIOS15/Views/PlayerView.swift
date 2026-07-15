import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    @EnvironmentObject private var transcription: TranscriptionManager
    let episode: Episode
    @State private var segments: [TranscriptSegment] = []
    @State private var loadingText = true
    @State private var errorText: String?
    @State private var lookupRequest: WordLookupRequest?
    @State private var translatingAll = false
    @State private var preparingAudio = false
    @State private var followPlayback = true

    private var currentIndex: Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.start <= player.currentTime } ?? 0
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
                                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                                    SentenceRow(segment: segment, active: index == currentIndex,
                                                seek: { player.seek(to: segment.start) },
                                                translate: { translate(index) },
                                                learn: { selected in
                                                    lookupRequest = WordLookupRequest(segment: segment,
                                                                                      selectedText: selected,
                                                                                      previous: index > 0 ? segments[index - 1].text : nil,
                                                                                      next: index + 1 < segments.count ? segments[index + 1].text : nil)
                                                },
                                                favorite: { saveSentence(segment) },
                                                repeatLine: { player.repeatSegment = player.repeatSegment?.id == segment.id ? nil : segment })
                                        .id(segment.id)
                                }
                            }
                            .padding(.horizontal, 18).padding(.bottom, 16)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                followPlayback = true
                                if let index = currentIndex, segments.indices.contains(index) {
                                    withAnimation { proxy.scrollTo(segments[index].id, anchor: .center) }
                                }
                            } label: {
                                Label("回到当前播放", systemImage: "location.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .padding(14)
                        }
                        .onChange(of: currentIndex) { index in
                            guard followPlayback, let index, segments.indices.contains(index) else { return }
                            withAnimation { proxy.scrollTo(segments[index].id, anchor: .center) }
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
                    Button { translateAll() } label: { Label("翻译全文", systemImage: "character.bubble") }.disabled(translatingAll || segments.isEmpty)
                    Button { transcribeAudio() } label: { Label("用 Whisper 重新转写", systemImage: "waveform.badge.mic") }.disabled(transcription.state(for: episode).isRunning)
                    Button { store.importedTranscript = nil; loadTranscript() } label: { Label("重新载入文本", systemImage: "arrow.clockwise") }
                } label: { if translatingAll { ProgressView() } else { Image(systemName: "ellipsis.circle") } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { FullPlayerControls() }
        .sheet(item: $lookupRequest) { request in
            WordLearningView(episode: episode, request: request)
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
        .onAppear { prepareAudio(); if segments.isEmpty { loadTranscript() } }
        .onReceive(transcription.$jobs) { jobs in
            guard let state = jobs[episode.id] else { return }
            if !state.segments.isEmpty { segments = state.segments; loadingText = false }
            if let message = state.errorMessage { errorText = "转录失败：\(message)" }
        }
        .onChange(of: store.importedTranscript) { imported in if let imported { segments = imported; loadingText = false } }
    }

    private var noTranscript: some View {
        VStack(spacing: 15) {
            Image(systemName: "captions.bubble").font(.system(size: 55)).foregroundColor(AppTheme.purple)
            Text("这一集没有附带逐句文本").font(.title3.bold())
            Text("可以使用离线 Whisper 自动生成逐句稿，也可以在“更多”中导入 SRT、VTT 或 Podcasting 2.0 JSON 文稿。")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if transcription.state(for: episode).isRunning {
                VStack(spacing: 8) {
                    ProgressView(value: transcription.state(for: episode).progress)
                    Text("正在后台提前转录 \(Int(transcription.state(for: episode).progress * 100))% · 完整句生成后立即显示")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Button("自动生成逐句稿") { transcribeAudio() }.buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var audioStatusBanner: some View {
        switch downloads.state(for: episode) {
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
                    Text("正在后台提前转录 \(Int(transcription.state(for: episode).progress * 100))%").font(.caption)
                    ProgressView(value: transcription.state(for: episode).progress)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(AppTheme.purple.opacity(0.09))
            } else if preparingAudio { ProgressView("下载完成，正在准备播放…").font(.caption).padding(9) }
        case .idle:
            if preparingAudio { ProgressView("正在连接音频服务器…").font(.caption).padding(9) }
        }
    }

    private func prepareAudio(retry: Bool = false) {
        if player.episode?.id == episode.id { return }
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
                if !TranscriptCache.isComplete(episodeID: episode.id) { startAutomaticTranscription() }
            } else {
                do { segments = try await TranscriptService().load(for: episode) }
                catch TranscriptError.empty { segments = []; startAutomaticTranscription() }
                catch { segments = []; errorText = error.localizedDescription; startAutomaticTranscription() }
            }
            loadingText = false
        }
    }

    private func transcribeAudio() {
        loadingText = false
        Task {
            do {
                let audioURL = try await downloads.download(episode)
                segments = []
                transcription.retry(episode: episode, audioURL: audioURL)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func startAutomaticTranscription() {
        Task {
            do {
                let audioURL = try await downloads.download(episode)
                transcription.start(episode: episode, audioURL: audioURL)
            } catch { errorText = "自动转录准备失败：\(error.localizedDescription)" }
        }
    }

    private func translate(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        Task {
            do {
                let result = try await MicrosoftTranslator.shared.translateWithContext(
                    previous: index > 0 ? segments[index - 1].text : nil,
                    current: segments[index].text,
                    next: index + 1 < segments.count ? segments[index + 1].text : nil,
                    to: store.targetLanguage)
                segments[index].translation = result
            } catch { errorText = "翻译失败：\(error.localizedDescription)" }
        }
    }

    private func translateAll() {
        translatingAll = true
        Task {
            do {
                let contexts = segments.indices.map { index in
                    [index > 0 ? segments[index - 1].text : nil, segments[index].text, index + 1 < segments.count ? segments[index + 1].text : nil]
                        .compactMap { $0 }.joined(separator: "\n")
                }
                let values = try await MicrosoftTranslator.shared.translateBatch(contexts, to: store.targetLanguage)
                for index in segments.indices {
                    let lines = values[index].split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    let position = index > 0 ? 1 : 0
                    segments[index].translation = lines.indices.contains(position) ? lines[position] : values[index]
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
                if translated.isEmpty { translated = (try? await MicrosoftTranslator.shared.translate(segment.text, to: store.targetLanguage)) ?? "" }
                store.addVocabulary(VocabularyItem(id: itemID, word: "★ 收藏句子", sentence: segment.text, sentenceTranslation: translated, podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: segment.start, audioClipFilename: clip))
            } catch { errorText = "收藏原声句子失败：\(error.localizedDescription)" }
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
    let repeatLine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(segment.start.clockString, action: seek).font(.subheadline).foregroundColor(active ? AppTheme.purple : .secondary)
                Spacer()
                Menu {
                    Button(action: translate) { Label("翻译这句话", systemImage: "character.bubble") }
                    Button { learn("") } label: { Label("查词并加入生词", systemImage: "text.magnifyingglass") }
                    Button(action: favorite) { Label("收藏句子", systemImage: "bookmark") }
                    Button(action: repeatLine) { Label("循环这一句", systemImage: "repeat.1") }
                    Button(action: seek) { Label("从这里播放", systemImage: "play") }
                } label: { Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 34, height: 28) }
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
                Button { player.repeatSegment = nil } label: { Image(systemName: player.repeatSegment == nil ? "repeat" : "repeat.1").frame(width: 48) }.foregroundColor(player.repeatSegment == nil ? .secondary : AppTheme.purple)
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
    @State private var sentenceTranslation = ""
    @State private var frequency: WordFrequency?
    @State private var loading = false
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
                    }

                    if !translation.isEmpty {
                        resultCard(title: "在这里的意思", systemImage: "sparkles", color: AppTheme.purple) {
                            Text(translation).font(.title3.weight(.semibold)).foregroundColor(AppTheme.purple)
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
        Task {
            let result = try? await DictionaryService().lookup(selected)
            let resolvedSentenceTranslation = sentenceTranslation.isEmpty
                ? ((try? await MicrosoftTranslator.shared.translate(request.segment.text, to: store.targetLanguage)) ?? "")
                : sentenceTranslation
            let translatedWord = try? await ContextDefinitionService().meaning(
                of: selected,
                previous: request.previous,
                sentence: request.segment.text,
                next: request.next,
                dictionary: result,
                targetLanguage: store.targetLanguage,
                configuration: ContextDefinitionConfiguration(enabled: store.contextGPTEnabled,
                                                              baseURL: store.contextGPTBaseURL,
                                                              apiKey: store.contextGPTAPIKey,
                                                              model: store.contextGPTModel))
            phonetic = result?.phonetic ?? ""
            definition = result?.definition ?? ""
            translation = translatedWord ?? ""
            sentenceTranslation = resolvedSentenceTranslation
            frequency = WordFrequencyService().lookup(selected)
            if result == nil && translatedWord == nil { errorText = "未查询到结果，请检查网络或换用系统词典。" }
            loading = false
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
                        configuration: ContextDefinitionConfiguration(enabled: store.contextGPTEnabled,
                                                                      baseURL: store.contextGPTBaseURL,
                                                                      apiKey: store.contextGPTAPIKey,
                                                                      model: store.contextGPTModel))) ?? ""
                }
            }
            if savedFrequency == nil { savedFrequency = WordFrequencyService().lookup(selected) }
            var savedSentenceTranslation = sentenceTranslation
            if savedSentenceTranslation.isEmpty {
                savedSentenceTranslation = (try? await MicrosoftTranslator.shared.translate(request.segment.text, to: store.targetLanguage)) ?? ""
            }
            do {
                let itemID = UUID()
                let clip = try await AudioClipStore.create(from: sourceURL, itemID: itemID, start: request.segment.start, end: request.segment.end)
                store.addVocabulary(VocabularyItem(id: itemID, word: selected, phonetic: savedPhonetic, definition: savedDefinition, translation: savedMeaning, sentence: request.segment.text, sentenceTranslation: savedSentenceTranslation, podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: request.segment.start, audioClipFilename: clip, frequencyRank: savedFrequency?.rank))
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
}

private struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}

private struct SelectableSentenceView: UIViewRepresentable {
    let text: String
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
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
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        context.coordinator.onSelection = onSelection
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelection: (String) -> Void
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else { return }
            let value = (textView.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { onSelection(value) }
        }
    }
}
