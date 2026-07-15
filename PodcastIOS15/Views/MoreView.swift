import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var importing = false
    @State private var showClear = false

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
                    Text("使用 Microsoft Edge Translator。翻译单句时会同时提交前后文，不调用 iOS 16 Translation 框架。")
                }.font(.caption).foregroundColor(.secondary)
            }
            Section("播放") {
                Label("支持后台与锁屏播放", systemImage: "lock.iphone")
                Label("支持倍速、15 秒跳转和逐句循环", systemImage: "goforward.15")
            }
            Section("数据") {
                Button(role: .destructive) { showClear = true } label: { Label("清空生词库", systemImage: "trash") }
            }
            Section("关于") {
                HStack { Text("版本"); Spacer(); Text("1.0.0 (iOS 15)").foregroundColor(.secondary) }
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
    }
}
