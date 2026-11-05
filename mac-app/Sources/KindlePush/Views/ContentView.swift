import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: PushStore
    @State private var targeted = false
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if store.articles.isEmpty {
                EmptyStateView(store: store, targeted: targeted)
            } else {
                listHeader
                if !store.undecided.isEmpty {
                    TranslationPrompt(store: store)
                        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                List(selection: $selection) {
                    ForEach(store.articles) { article in
                        ArticleRow(article: article, store: store, selected: selection.contains(article.id)).tag(article.id)
                    }
                    AddMoreRow(store: store)
                        .listRowSeparator(.hidden).selectionDisabled()
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if !ids.isEmpty { ArticleActions(store: store, ids: ids) }
                } primaryAction: { store.open($0) }
                .onDeleteCommand { store.remove(selection); selection.removeAll() }
            }
            FooterBar(store: store)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if targeted && !store.articles.isEmpty { DropOverlay() } }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls); return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.2), value: store.undecided.map(\.id))
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("乔木 Kindle 助手")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ConnectionButton(store: store)
                HistoryButton(store: store)
                Button { store.showPicker = true } label: { Label("添加文章", systemImage: "plus") }
                    .help("添加文章或电子书（⌘O）")
                SettingsLink { Label("翻译设置", systemImage: "gearshape") }.help("翻译设置（⌘,）")
            }
        }
        .fileImporter(isPresented: $store.showPicker,
                      allowedContentTypes: Article.extensions.compactMap { UTType(filenameExtension: $0) } + [.zip],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): store.add(urls)
            case .failure(let error): store.notice = error.localizedDescription; store.isError = true
            }
        }
        .sheet(isPresented: Binding(get: { !store.renameIDs.isEmpty }, set: { if !$0 { store.renameIDs = [] } })) {
            RenameSheet(store: store, ids: store.renameIDs)
        }
        .sheet(isPresented: $store.showAddKindle) { AddKindleSheet(store: store) }
        .task { await store.start() }
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.translation.running {
            let working = store.articles.first { $0.status == "翻译中" }
            parts.append(store.translation.total <= 1
                ? working?.progress.map { "正在翻译 · \(Int(($0 * 100).rounded()))%" } ?? "正在翻译"
                : "翻译 \(store.translation.completed) / \(store.translation.total)")
        }
        if store.quick.running { parts.append("发送 \(store.quick.completed) / \(store.quick.total)") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if store.pendingCount > 0 { return "\(store.pendingCount) 篇待发送" }
        return store.articles.isEmpty ? "" : "全部已送达"
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Text("文章").font(.headline)
            Text("待发送 \(store.pendingCount) · 已送达 \(store.sentCount)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if store.sentCount > 0 {
                // Right beside the count it clears; a word, not an icon that could read as "delete".
                Text("·").font(.callout).foregroundStyle(.tertiary)
                Button("清除") { store.clearSent() }
                    .buttonStyle(.inkLink).font(.callout)
                    .help("把 \(store.sentCount) 本已送达的书移出列表，不删除文件；发送历史里还能找到")
            }
            Spacer()
            Button { store.tidyNames(selection) } label: {
                Label(selection.count > 1 ? "整理 \(selection.count) 个文件名" : "整理文件名", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(.tool)
            .help(selection.count > 1 ? "整理选中的 \(selection.count) 个文件名：去掉来源标记、杂乱分隔符和版本后缀，预览后再改名"
                                      : "整理文件名：去掉来源标记、杂乱分隔符和版本后缀，预览后再改名")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }
}

/// "有 2 本英文书，要翻译成中文吗？": one decision for every foreign book that has none yet.
private struct TranslationPrompt: View {
    @ObservedObject var store: PushStore

    var body: some View {
        let books = store.undecided
        let languages = Set(books.compactMap(\.language))
        let source = languages.count == 1 ? languages.first! : ""
        let ids = Set(books.map(\.id))
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed").foregroundStyle(.secondary)
            Text("有 \(books.count) 本\(source.isEmpty ? "外文" : Lang.name(source))书，要翻译成\(Lang.name(store.targetLanguage))吗？")
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button(OutputMode.bilingual.title(from: source, to: store.targetLanguage)) { store.choose(.bilingual, for: ids) }
                .buttonStyle(.inkOutline).controlSize(.small)
                .help("原文和译文逐段对照")
            Button(OutputMode.targetOnly.title(from: source, to: store.targetLanguage)) { store.choose(.targetOnly, for: ids) }
                .buttonStyle(.inkOutline).controlSize(.small)
                .help("只保留译文")
            Button("不用，发原文") { store.choose(.original, for: ids) }
                .buttonStyle(.inkLink).font(.callout)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("每本书行尾的标签可以单独改。想以后不再问，在翻译设置 › 语言里选「外文书默认」")
    }
}

/// The end of the list: where more books go, so a short list does not end in blank space.
private struct AddMoreRow: View {
    @ObservedObject var store: PushStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("拖入更多文章或电子书").font(.callout.weight(.medium))
                Text("拖到窗口任意位置，或用右上角 ＋（⌘O）。右键一本书可打开、在访达中显示或放回待发送。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("选择文件…") { store.showPicker = true }.buttonStyle(.inkLink).font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.showPicker = true }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.ink.opacity(0.07))
            .strokeBorder(Color.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .overlay {
                Label("松手，加入发送列表", systemImage: "arrow.down.doc")
                    .font(.headline).foregroundStyle(Color.ink)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10).allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct EmptyStateView: View {
    @ObservedObject var store: PushStore
    let targeted: Bool
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ReaderGlyph(lifted: targeted)
            Text(targeted ? "松手，交给 Kindle" : "把文章留给慢读")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .padding(.top, 26)
                .contentTransition(.opacity)
            Text("拖入文章或电子书：翻译成任意语言，保存到本机，或经 Wi‑Fi 送到 Kindle。")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            Text("EPUB · PDF · MOBI · AZW3 · FB2 · DjVu · CBZ · TXT · Word · HTML · Markdown")
                .help("KOReader 能打开的格式都支持：EPUB、PDF、XPS、DjVu、CBZ/CBR/CBT、MOBI/AZW/AZW3/PRC/PDB、FB2/FB3、CHM、DOC/DOCX/ODT/RTF、TXT、HTML、Markdown、图片")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
            Button("选择文件…") { store.showPicker = true }.buttonStyle(.ink)
                .controlSize(.large).padding(.top, 22)
            Spacer(minLength: 24)
            HStack(spacing: 10) {
                Step(number: 1, text: "拖入文章")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Step(number: 2, text: "本机排版")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Step(number: 3, text: "在「我的文章」阅读")
            }
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? Color.ink.opacity(0.06) : Color.clear)
                .strokeBorder(targeted ? Color.ink.opacity(0.6) : Color.secondary.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(16)
        }
        .animation(.spring(duration: 0.3), value: targeted)
    }
}

private struct Step: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)").font(.caption2.weight(.semibold)).monospacedDigit()
                .frame(width: 16, height: 16).background(.quaternary, in: Circle())
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

/// A small e-reader with a page of text and a paper plane arriving.
private struct ReaderGlyph: View {
    let lifted: Bool
    private let lines: [CGFloat] = [44, 52, 50, 30, 0, 52, 46, 52, 24]
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                .shadow(color: .black.opacity(lifted ? 0.14 : 0.06), radius: lifted ? 14 : 6, y: lifted ? 8 : 3)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines.indices, id: \.self) { i in
                    Capsule().fill(Color.primary.opacity(lines[i] == 0 ? 0 : 0.2))
                        .frame(width: lines[i], height: 2.5)
                }
            }
            .frame(width: 54, alignment: .leading).offset(y: -5)
        }
        .frame(width: 86, height: 114)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(Color.ink)
                .rotationEffect(.degrees(lifted ? -8 : 0))
                .offset(x: lifted ? 30 : 22, y: lifted ? -22 : -14)
        }
        .scaleEffect(lifted ? 1.05 : 1)
    }
}
