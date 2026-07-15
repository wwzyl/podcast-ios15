import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    let episode: Episode
    @State private var segments: [TranscriptSegment] = []
    @State private var loadingText = true
    @State private var errorText: String?
    @State private var selectedSegment: TranscriptSegment?
    @State private var translatingAll = false
    @State private var transcribing = false
    @State private var followPlayback = true

    private var currentIndex: Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.start <= player.currentTime } ?? 0
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                                            learn: { selectedSegment = segment },
                                            favorite: { saveSentence(segment) },
                                            repeatLine: { player.repeatSegment = player.repeatSegment?.id == segment.id ? nil : segment })
                                    .id(segment.id)
                            }
                        }.padding(.horizontal, 18).padding(.bottom, 16)
                    }
                    .onChange(of: currentIndex) { index in
                        guard followPlayback, let index, segments.indices.contains(index) else { return }
                        withAnimation { proxy.scrollTo(segments[index].id, anchor: .center) }
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
                    Button { transcribeAudio() } label: { Label("用 Whisper 重新转写", systemImage: "waveform.badge.mic") }.disabled(transcribing)
                    Button { store.importedTranscript = nil; loadTranscript() } label: { Label("重新载入文本", systemImage: "arrow.clockwise") }
                } label: { if translatingAll { ProgressView() } else { Image(systemName: "ellipsis.circle") } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { FullPlayerControls() }
        .sheet(item: $selectedSegment) { segment in WordLearningView(episode: episode, segment: segment) }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
        .onAppear { player.load(episode); if segments.isEmpty { loadTranscript() } }
        .onChange(of: store.importedTranscript) { imported in if let imported { segments = imported; loadingText = false } }
    }

    private var noTranscript: some View {
        VStack(spacing: 15) {
            Image(systemName: "captions.bubble").font(.system(size: 55)).foregroundColor(AppTheme.purple)
            Text("这一集没有附带逐句文本").font(.title3.bold())
            Text("可以使用离线 Whisper 自动生成逐句稿，也可以在“更多”中导入 SRT、VTT 或 Podcasting 2.0 JSON 文稿。")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if transcribing {
                ProgressView("首次使用会下载约 60 MB 模型；长节目转写需要一些时间。")
                    .multilineTextAlignment(.center)
            } else {
                Button("自动生成逐句稿") { transcribeAudio() }.buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadTranscript() {
        loadingText = true
        Task {
            if let local = store.importedTranscript ?? TranscriptCache.load(episodeID: episode.id) {
                segments = local
            } else {
                do { segments = try await TranscriptService().load(for: episode) }
                catch TranscriptError.empty { segments = [] }
                catch { segments = []; errorText = error.localizedDescription }
            }
            loadingText = false
        }
    }

    private func transcribeAudio() {
        transcribing = true
        loadingText = false
        Task {
            do { segments = try await WhisperTranscriber.shared.transcribe(episode: episode) }
            catch { errorText = error.localizedDescription }
            transcribing = false
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
        store.addVocabulary(VocabularyItem(word: "★ 收藏句子", sentence: segment.text, sentenceTranslation: segment.translation ?? "", podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: segment.start))
    }
}

private struct SentenceRow: View {
    let segment: TranscriptSegment
    let active: Bool
    let seek: () -> Void
    let translate: () -> Void
    let learn: () -> Void
    let favorite: () -> Void
    let repeatLine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(segment.start.clockString, action: seek).font(.subheadline).foregroundColor(active ? AppTheme.purple : .secondary)
                Spacer()
                Menu {
                    Button(action: translate) { Label("结合上下文翻译", systemImage: "character.bubble") }
                    Button(action: learn) { Label("查词并加入生词", systemImage: "text.magnifyingglass") }
                    Button(action: favorite) { Label("收藏句子", systemImage: "bookmark") }
                    Button(action: repeatLine) { Label("循环这一句", systemImage: "repeat.1") }
                    Button(action: seek) { Label("从这里播放", systemImage: "play") }
                } label: { Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 34, height: 28) }
            }
            Text(segment.text)
                .font(.system(size: 21, weight: active ? .medium : .regular, design: .serif))
                .foregroundColor(active ? .primary : .primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(perform: seek)
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
    private let bars: [CGFloat] = [9,18,12,26,17,22,10,28,16,20,12,25,18,11,22,14,27,12,19,24,11,18,28,15,21,10,25,18,13,22]

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { index in Capsule().fill(index < Int(progress * Double(bars.count)) ? AppTheme.purple : Color.secondary.opacity(0.25)).frame(height: bars[index]) }
            }.frame(height: 30)
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
        .padding(.horizontal, 18).padding(.top, 9).padding(.bottom, 8)
        .background(.ultraThinMaterial).overlay(alignment: .top) { Divider() }
    }

    private var progress: Double { player.duration > 0 ? min(1, player.currentTime / player.duration) : 0 }
}

private struct WordLearningView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    let episode: Episode
    let segment: TranscriptSegment
    @State private var word = ""
    @State private var phonetic = ""
    @State private var definition = ""
    @State private var translation = ""
    @State private var loading = false
    @State private var showSystemDictionary = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                Section("当前句子") { Text(segment.text); if let value = segment.translation { Text(value).foregroundColor(AppTheme.purple) } }
                Section("要查询的单词或短语") {
                    TextField("输入或粘贴单词", text: $word).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("查询词义") { lookup() }.disabled(word.isEmpty || loading)
                        Spacer()
                        Button("系统词典") { showSystemDictionary = true }.disabled(word.isEmpty)
                    }
                }
                if loading { ProgressView("正在查询…") }
                if !phonetic.isEmpty || !definition.isEmpty || !translation.isEmpty {
                    Section("释义") {
                        if !phonetic.isEmpty { Text(phonetic).foregroundColor(.secondary) }
                        if !translation.isEmpty { Text(translation).foregroundColor(AppTheme.purple) }
                        if !definition.isEmpty { Text(definition) }
                    }
                }
                Section { Button("加入生词库") { save() }.disabled(word.isEmpty) }
            }
            .navigationTitle("查词").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $showSystemDictionary) { SystemDictionaryView(term: word) }
            .alert("查询失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
        }
    }

    private func lookup() {
        loading = true
        Task {
            async let dictionary = try? DictionaryService().lookup(word)
            async let translated = try? MicrosoftTranslator.shared.translateWithContext(previous: nil, current: word, next: segment.text, to: store.targetLanguage)
            let (result, translatedWord) = await (dictionary, translated)
            phonetic = result?.phonetic ?? ""
            definition = result?.definition ?? ""
            translation = translatedWord ?? ""
            if result == nil && translatedWord == nil { errorText = "未查询到结果，请检查网络或换用系统词典。" }
            loading = false
        }
    }

    private func save() {
        store.addVocabulary(VocabularyItem(word: word.trimmingCharacters(in: .whitespacesAndNewlines), definition: definition, translation: translation, sentence: segment.text, sentenceTranslation: segment.translation ?? "", podcastTitle: episode.podcastTitle, episodeTitle: episode.title, timestamp: segment.start))
        dismiss()
    }
}

private struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
