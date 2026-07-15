import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var downloads: EpisodeDownloadManager
    @State private var importing = false
    @State private var showClear = false
    @State private var showClearCache = false

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
                HStack(alignment: .top) {
                    Image(systemName: "character.bubble")
                    Text("整句翻译使用 Microsoft Edge Translator；所选词的语境义可在下方启用与官方相同思路的 GPT 上下文释义。")
                }.font(.caption).foregroundColor(.secondary)
                NavigationLink("上下文释义服务") { ContextDefinitionSettingsView() }
            }
            Section("播放") {
                Label("支持后台与锁屏播放", systemImage: "lock.iphone")
                Label("支持倍速、15 秒跳转和逐句循环", systemImage: "goforward.15")
            }
            Section("缓存管理") {
                HStack {
                    Label("后台下载队列", systemImage: "arrow.down.circle")
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
            Section("数据") {
                Button(role: .destructive) { showClear = true } label: { Label("清空生词库", systemImage: "trash") }
            }
            Section("关于") {
                HStack { Text("版本"); Spacer(); Text("1.4.0 (7) · iOS 15").foregroundColor(.secondary) }
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
        .onAppear { downloads.refreshCacheSize() }
    }
}

private struct ContextDefinitionSettingsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Form {
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
        }
        .navigationTitle("上下文释义")
        .navigationBarTitleDisplayMode(.inline)
    }
}
