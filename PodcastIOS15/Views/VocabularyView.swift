import SwiftUI
import UIKit
import AVFoundation

struct VocabularyView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var errorText: String?
    @State private var showAnkiExport = false
    @State private var deckName = "Podcast iOS15"
    @State private var ankiTemplate: AnkiTemplateType = .questionAnswer

    var body: some View {
        List {
            Section { VocabularyStats(items: store.vocabulary) }
            Section {
                HStack { Label("生词", systemImage: "tray"); Spacer(); Text("\(store.vocabulary.filter { $0.word != "★ 收藏句子" }.count)").foregroundColor(.secondary) }
                HStack { Label("收藏的句子", systemImage: "bookmark"); Spacer(); Text("\(store.vocabulary.filter { $0.word == "★ 收藏句子" }.count)").foregroundColor(.secondary) }
            }
            Section("词汇和句子") {
                if store.vocabulary.isEmpty {
                    Text("播放节目时，在句子右侧菜单中选择“查词并加入生词”。").foregroundColor(.secondary)
                }
                ForEach(store.vocabulary) { item in NavigationLink(destination: VocabularyDetailView(item: item)) { VocabularyRow(item: item) } }
                    .onDelete(perform: store.removeVocabulary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("生词")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { exportCSV() } label: { Label("导出 CSV", systemImage: "tablecells") }
                    Button { showAnkiExport = true } label: { Label("导出 Anki (.apkg)", systemImage: "square.and.arrow.up") }
                } label: {
                    if exporting { ProgressView() }
                    else { Image(systemName: "ellipsis.circle") }
                }
                .disabled(store.vocabulary.isEmpty || exporting)
            }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(activityItems: [exportURL]) }
        }
        .sheet(isPresented: $showAnkiExport) {
            NavigationView {
                Form {
                    Section("牌组") {
                        TextField("牌组名称", text: $deckName)
                    }
                    Section("卡片模板") {
                        Picker("模板", selection: $ankiTemplate) {
                            ForEach(AnkiTemplateType.allCases) { template in Text(template.title).tag(template) }
                        }.pickerStyle(.inline)
                    }
                    Section {
                        Text("卡片包含：生词、所在句子、句子原声、句子释义、该词在上下文中的释义。不会导出系统词典释义或播客来源。")
                            .font(.caption).foregroundColor(.secondary)
                        Text("同一牌组再次导入时使用稳定的卡片标识；Anki 会保留已有卡片的学习进度，并加入新的生词卡。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .navigationTitle("导出到 Anki").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showAnkiExport = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导出") { showAnkiExport = false; exportAnki(ankiTemplate, deckName: deckName) }
                            .disabled(deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.navigationViewStyle(.stack)
        }
        .alert("导出失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好") {} } message: { Text(errorText ?? "") }
    }

    private func exportCSV() {
        exporting = true
        do { exportURL = try VocabularyExporter().csv(store.vocabulary) } catch { errorText = error.localizedDescription }
        exporting = false
    }
    private func exportAnki(_ template: AnkiTemplateType, deckName: String) {
        let items = store.vocabulary.filter { $0.word != "★ 收藏句子" }
        guard !items.isEmpty else {
            errorText = "当前没有可导出的生词；收藏的整句不会作为生词卡导出。"
            return
        }
        exporting = true
        Task.detached {
            do {
                let url = try VocabularyExporter().apkg(items, template: template, deckName: deckName)
                await MainActor.run { exportURL = url; exporting = false }
            } catch { await MainActor.run { errorText = error.localizedDescription; exporting = false } }
        }
    }
}

private struct VocabularyStats: View {
    let items: [VocabularyItem]
    private var counts: [Int] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
            return items.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }.count
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本周新增").font(.subheadline).foregroundColor(.secondary)
            Text("\(counts.reduce(0, +))").font(.system(size: 42, weight: .medium, design: .rounded))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(counts.indices, id: \.self) { index in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3).fill(AppTheme.purple).frame(height: max(4, CGFloat(counts[index]) * 9))
                        Text(shortWeekday(index)).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }.frame(height: 105)
        }.padding(.vertical, 8)
    }
    private func shortWeekday(_ index: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "E"
        let date = Calendar.current.date(byAdding: .day, value: index - 6, to: Date())!
        return formatter.string(from: date)
    }
}

private struct VocabularyRow: View {
    let item: VocabularyItem
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(item.word).font(.headline); Spacer(); Text(item.createdAt, style: .date).font(.caption).foregroundColor(.secondary) }
            if !item.translation.isEmpty { Text(item.translation).foregroundColor(AppTheme.purple) }
            if let rank = item.frequencyRank { Text("COCA #\(rank)").font(.caption).foregroundColor(.secondary) }
            Text(item.sentence).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
        }.padding(.vertical, 4)
    }
}

private struct VocabularyDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    let item: VocabularyItem
    @State private var showDictionary = false
    @State private var audioPlayer: AVAudioPlayer?
    var body: some View {
        List {
            Section {
                Text(item.word).font(.largeTitle.bold())
                if let phonetic = item.phonetic, !phonetic.isEmpty { Text(phonetic).foregroundColor(.secondary) }
                if !item.translation.isEmpty { Text(item.translation).font(.title3).foregroundColor(AppTheme.purple) }
                if let rank = item.frequencyRank { Label("COCA 词频排名 #\(rank)", systemImage: "chart.bar.fill").foregroundColor(.secondary) }
                if !item.definition.isEmpty { Text(item.definition) }
                if item.word != "★ 收藏句子" { Button("打开系统词典") { showDictionary = true } }
            }
            Section("原句") {
                Button { playOriginalSentence() } label: {
                    HStack(alignment: .top) {
                        Text(item.sentence).font(.title3).foregroundColor(.primary)
                        Spacer()
                        if store.audioClipURL(for: item) != nil { Image(systemName: "speaker.wave.2.fill").foregroundColor(AppTheme.purple) }
                    }
                }.disabled(store.audioClipURL(for: item) == nil)
                if !item.sentenceTranslation.isEmpty { Text(item.sentenceTranslation).foregroundColor(AppTheme.purple) }
            }
            Section("来源") { Text("\(item.podcastTitle)\n\(item.episodeTitle) · \(item.timestamp.clockString)") }
        }
        .navigationTitle("生词详情").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDictionary) { SystemDictionaryHost(term: item.word) }
    }

    private func playOriginalSentence() {
        guard let url = store.audioClipURL(for: item) else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
    }
}

private struct SystemDictionaryHost: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
