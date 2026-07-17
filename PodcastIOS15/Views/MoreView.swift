import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    @State private var importing = false
    @State private var showClear = false
    @State private var showClearCache = false
    @State private var whisperModelCacheSize: Int64 = 0
    @State private var showClearWhisperModels = false

    var body: some View {
        List {
            Section("文本") {
                Button { importing = true } label: { Label("导入 SRT / VTT / JSON 文稿", systemImage: "doc.badge.plus") }
                if let message = store.importMessage { Text(message).font(.caption).foregroundColor(.secondary) }
            }
            Section("翻译") {
                Picker("目标语言", selection: $store.targetLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Español").tag("es")
                }
                Picker("翻译服务", selection: $store.translationProvider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.title).tag(provider.rawValue)
                    }
                }
                Toggle("服务失败时自动回退", isOn: $store.translationFallbackEnabled)
                Toggle("播放时自动翻译当前句", isOn: $store.autoTranslateCurrentSentence)
                HStack(alignment: .top) {
                    Image(systemName: "character.bubble")
                    Text("可选择 DeepL、GPT 或 Microsoft；关闭自动回退后不会静默切换翻译服务。")
                }.font(.caption).foregroundColor(.secondary)
                NavigationLink("翻译与上下文释义设置") { ContextDefinitionSettingsView() }
            }
            Section("播放") {
                Label("支持后台与锁屏播放", systemImage: "lock.iphone")
                Label("支持倍速、15 秒跳转和逐句循环", systemImage: "goforward.15")
                Toggle("锁屏播放信息显示当前字幕", isOn: $store.lockScreenShowsTranscript)
            }
            Section("查词设置") {
                Toggle("查词时暂停播放", isOn: $store.lookupPausePlayback)
                Toggle("查词结束继续播放", isOn: $store.lookupResumePlayback)
                Toggle("查词自动复制单词", isOn: $store.lookupAutoCopy)
                Toggle("点击查词直接打开欧路词典", isOn: $store.lookupOpenEudicDirectly)
            }
            Section("导出文本") {
                Toggle("携带时间戳", isOn: $store.exportIncludeTimestamps)
                Toggle("携带已有翻译", isOn: $store.exportIncludeTranslations)
            }
            Section("缓存管理") {
                HStack {
                    Label("下载队列", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(downloads.queuedCount)").foregroundColor(.secondary)
                }
                Picker("自动删除已听过音频缓存文件", selection: $downloads.cachePolicy) {
                    ForEach(AudioCachePolicy.allCases) { policy in Text(policy.title).tag(policy) }
                }
                HStack {
                    Label("音频下载缓存文件", systemImage: "internaldrive")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: downloads.cacheSize, countStyle: .file)).foregroundColor(.secondary)
                }
                Button(role: .destructive) { showClearCache = true } label: { Label("删除音频下载缓存", systemImage: "trash") }
                Text("这里只清理整集音频。转录文本、生词数据和生词的独立原声例句不会被删除。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Whisper 模型") {
                HStack {
                    Label("已下载的均衡/英语模型", systemImage: "waveform.badge.magnifyingglass")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: whisperModelCacheSize, countStyle: .file)).foregroundColor(.secondary)
                }
                Button(role: .destructive) { showClearWhisperModels = true } label: {
                    Label("删除按需下载模型", systemImage: "trash")
                }.disabled(whisperModelCacheSize == 0)
                Text("内置的极速模型和 Core ML 编码器不会被删除。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("转录分段") {
                Toggle("生成词级时间戳", isOn: $store.transcriptionWordTimestamps)
                Toggle("转写时翻译为英语", isOn: $store.transcriptionTranslateToEnglish)
                Toggle("转录期间保持屏幕常亮", isOn: $store.transcriptionKeepScreenOn)
                Toggle("自动检测音频语言", isOn: $store.transcriptionAutoDetectLanguage)
                if !store.transcriptionAutoDetectLanguage {
                    Picker("音频语言", selection: $store.transcriptionSourceLanguage) {
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                        Text("Español").tag("es")
                        Text("Français").tag("fr")
                        Text("Deutsch").tag("de")
                    }
                }
                Toggle("允许在逗号处分段", isOn: $store.transcriptionSplitOnComma)
                HStack {
                    Text("最短句段")
                    Spacer()
                    Stepper("\(store.transcriptionMinimumSegmentDuration, specifier: "%.1f") 秒",
                            value: $store.transcriptionMinimumSegmentDuration, in: 0.5...4, step: 0.5)
                }
                HStack {
                    Text("最长句段")
                    Spacer()
                    Stepper("\(store.transcriptionMaximumSegmentDuration, specifier: "%.0f") 秒",
                            value: $store.transcriptionMaximumSegmentDuration, in: 12...30, step: 2)
                }
                Stepper("中文建议长度：\(store.transcriptionChineseSegmentCount) 字",
                        value: $store.transcriptionChineseSegmentCount, in: 12...60, step: 2)
            }
            Section("数据") {
                Button(role: .destructive) { showClear = true } label: { Label("清空生词库", systemImage: "trash") }
            }
            Section("关于") {
                HStack { Text("版本"); Spacer(); Text("1.6.3 (13) · iOS 15").foregroundColor(.secondary) }
                Text("这是面向 iOS 15 重新实现的播客语言学习工具，界面和主要学习流程参考 Aisten 6.3.5；未使用其不兼容的可执行代码。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped).navigationTitle("更多")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { store.importFile(url) }
        }
        .confirmationDialog("确定清空全部生词和收藏句子？", isPresented: $showClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { store.clearVocabulary() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定删除全部整集音频缓存？", isPresented: $showClearCache, titleVisibility: .visible) {
            Button("删除", role: .destructive) { downloads.clearEpisodeCache() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确定删除已下载的 Whisper 模型？", isPresented: $showClearWhisperModels, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                WhisperModelCacheManager.removeDownloadedModels()
                whisperModelCacheSize = WhisperModelCacheManager.cacheSize()
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            downloads.refreshCacheSize()
            whisperModelCacheSize = WhisperModelCacheManager.cacheSize()
        }
    }
}

private struct ContextDefinitionSettingsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Form {
            Section("DeepL") {
                SecureField("DeepL API Key", text: $store.deeplAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Toggle("使用 GPT 上下文释义", isOn: $store.contextGPTEnabled)
            } footer: {
                Text("官方 6.3.5 也包含 GPT 开关、API Key、Base URL 和模型设置。未启用时使用官方词典释义与微软翻译做本地语境匹配。")
            }
            Section("OpenAI 兼容接口") {
                TextField("Base URL", text: $store.contextGPTBaseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $store.contextGPTAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型", text: $store.contextGPTModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("AI 分析和 AI 解释") {
                Picker("AI 返回语言", selection: $store.aiOutputLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                Picker("上下文释义风格", selection: $store.aiExplanationStyle) {
                    ForEach(AIExplanationStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                }
            }
        }
        .navigationTitle("上下文释义")
        .navigationBarTitleDisplayMode(.inline)
    }
}
