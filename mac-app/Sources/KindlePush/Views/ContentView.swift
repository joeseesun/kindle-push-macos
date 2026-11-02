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
                List(selection: $selection) {
                    ForEach(store.articles) { article in
                        ArticleRow(article: article, store: store).tag(article.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("在访达中显示") { store.reveal(ids) }
                    Button("再次发送") { ids.forEach(store.retry) }.disabled(store.busy)
                    Divider()
                    Button("从列表移除") { store.remove(ids) }.disabled(store.busy)
                } primaryAction: { store.reveal($0) }
                .onDeleteCommand { store.remove(selection); selection.removeAll() }
            }
            FooterBar(store: store)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if targeted && !store.articles.isEmpty { DropOverlay() } }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.busy else { return false }; store.add(urls); return true
        } isTargeted: { targeted = $0 && !store.busy }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("Kindle 推送")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ConnectionButton(store: store)
                Button { store.showPicker = true } label: { Label("添加文章", systemImage: "plus") }
                    .help("添加文章或电子书（⌘O）").disabled(store.busy)
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
        .task { await store.start() }
    }

    private var subtitle: String {
        if store.busy && store.total > 0 { return "\(store.completed) / \(store.total) 已完成" }
        if store.pendingCount > 0 { return "\(store.pendingCount) 篇待发送" }
        return store.articles.isEmpty ? "" : "全部已送达"
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Text("文章").font(.headline)
            Text("待发送 \(store.pendingCount) · 已送达 \(store.sentCount)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if store.sentCount > 0 {
                Button("清除已送达") { store.clearSent() }
                    .buttonStyle(.borderless).controlSize(.small).disabled(store.busy)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.07))
            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .overlay {
                Label("松手，加入发送列表", systemImage: "arrow.down.doc")
                    .font(.headline).foregroundStyle(Color.accentColor)
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
            Text("拖入文章或电子书，自动排版，经 Wi‑Fi 送到 Kindle。")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            Text("EPUB · PDF · MOBI · AZW3 · FB2 · DjVu · CBZ · TXT · Word · HTML · Markdown")
                .help("KOReader 能打开的格式都支持：EPUB、PDF、XPS、DjVu、CBZ/CBR/CBT、MOBI/AZW/AZW3/PRC/PDB、FB2/FB3、CHM、DOC/DOCX/ODT/RTF、TXT、HTML、Markdown、图片")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
            Button("选择文件…") { store.showPicker = true }
                .controlSize(.large).padding(.top, 22).disabled(store.busy)
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
                .fill(targeted ? Color.accentColor.opacity(0.06) : Color.clear)
                .strokeBorder(targeted ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18),
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
                .font(.system(size: 22, weight: .medium)).foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(lifted ? -8 : 0))
                .offset(x: lifted ? 30 : 22, y: lifted ? -22 : -14)
        }
        .scaleEffect(lifted ? 1.05 : 1)
    }
}
