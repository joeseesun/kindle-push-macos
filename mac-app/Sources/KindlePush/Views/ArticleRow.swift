import SwiftUI
import AppKit

struct ArticleRow: View {
    let article: Article
    @ObservedObject var store: PushStore
    var selected = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            BookCover(article: article)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(article.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        .help(article.path)
                    if article.bilingual == true {
                        Text(translatedLabel).font(.caption2.weight(.semibold)).foregroundStyle(Color.ink)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Color.ink.opacity(0.08), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(metaLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if article.phase == .working, let progress = article.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(.ink)
                        .frame(maxWidth: 240).padding(.top, 3)
                }
                if let detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(article.phase == .failed ? Color.orange : Color.secondary)
                        .lineLimit(2).truncationMode(.middle).help(detail)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if [.failed, .stopped].contains(article.phase) {
                    // In words and acting at once: an icon that only moved the book back to waiting read as broken.
                    Button("重试") { Task { await store.retryNow(article.id) } }
                        .buttonStyle(.inkOutline).controlSize(.small).fixedSize().padding(.trailing, 4)
                        .help(store.mode(of: article) == .original ? "再发一次这本书" : "接着处理这本书：已经译好的部分不会重新翻译，只补没完成的")
                }
                // Always there: the way back to the file is the most common next step.
                iconButton("folder", help: revealHelp) { store.reveal([article.id]) }
                    .opacity(hovering || selected ? 1 : 0.55)
                Menu {
                    ArticleActions(store: store, ids: [article.id])
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary).help("更多操作：打开、再次发送、从列表移除…")
                .accessibilityLabel("更多操作")
                .opacity(hovering || selected ? 1 : 0)
            }
            if showsChoice { TranslationChoice(article: article, store: store) }
            StatusChip(article: article)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.3), value: article.progress)
    }

    /// The menu tag: foreign EPUBs that can still be changed. Books in the target language get none.
    private var showsChoice: Bool {
        store.translatable(article) && article.status != "已发送" && article.status != "排队中" && article.phase != .working
            && !store.active.contains(article.id)
    }

    private var translatedLabel: String {
        let goal = article.translatedTo ?? "zh"
        return article.chineseOnly == true ? Lang.name(goal) + "译本" : Lang.pairLabel(article.language ?? "", goal)
    }

    private var revealHelp: String {
        article.madeFile != nil ? "在访达中显示\(article.madeFileLabel)（双击行用默认程序打开）"
            : "在访达中显示（双击行用默认程序打开）"
    }

    /// Something the status chip does not already say: where the file went, a hint, or why it failed.
    private var detail: String? {
        switch article.phase {
        case .done:
            // Several Kindles: which ones got it matters more than the folder, which is the same on each.
            if article.details.contains("提示：") || article.details.hasPrefix("已送达") { return article.details }
            return "Kindle › 我的文章 › " + article.preferredURL.lastPathComponent
        case .ready where article.status == "已保存":
            let url = article.preferredURL
            return "本机 › " + url.deletingLastPathComponent().lastPathComponent + " › " + url.lastPathComponent
        default:
            return article.details.isEmpty ? nil : article.details
        }
    }

    /// Author, language, format and folder: what tells two books apart at a glance.
    private var metaLine: String {
        let label = FileBadge(format: article.format, sent: false).label
        let language = article.language.flatMap { $0.isEmpty ? nil : Lang.name($0) }
        return [article.author, language, label, article.author == nil || article.author?.isEmpty == true ? article.folder : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
        .accessibilityLabel(help)
    }
}

/// One set of actions for a book, used by the row's ⋯ menu and the list's right-click menu.
struct ArticleActions: View {
    @ObservedObject var store: PushStore
    let ids: Set<UUID>

    private var items: [Article] { store.articles.filter { ids.contains($0.id) } }
    private var single: Article? { items.count == 1 ? items.first : nil }

    var body: some View {
        Button("打开") { store.open(ids) }
        if let single, single.madeFile != nil {
            Button("在访达中显示\(single.madeFileLabel)") { store.reveal(ids) }
            Button("在访达中显示原文件") { store.revealOriginal(ids) }
        } else {
            Button("在访达中显示") { store.reveal(ids) }
        }
        if let single, store.translatable(single), single.language != store.goal(of: single) {
            Divider()
            Button("先试译 3 段") { Task { await store.preview(single.id) } }
                .disabled(store.translation.running || single.phase == .working || single.status == "排队中")
                .help("只翻译 3 段正文，在访达里打开给你检查；不发送")
        }
        if let single, store.translatable(single), single.bilingual == true || store.mode(of: single) != .original {
            Button("重新翻译…") { store.confirmRetranslate = single.id }
                .disabled(single.phase == .working || single.status == "排队中" || store.active.contains(single.id))
                .help("丢弃这本书已有的译文和进度，从头翻译")
        }
        Divider()
        if items.contains(where: { $0.status == "排队中" }) {
            Button("移出队列") { store.unqueue(ids) }
        }
        Button("放回待发送") { ids.forEach(store.retry) }
            .disabled(items.allSatisfy { $0.phase == .working || $0.status == "排队中" })
        Button("整理文件名…") { store.tidyNames(ids) }
        Divider()
        Button("从列表移除（不删除文件）") { store.remove(ids) }
            .disabled(items.allSatisfy { store.busy && $0.phase == .working })
    }
}

/// The book's own cover when there is one, else the format badge, sized like a small book.
struct BookCover: View {
    let article: Article
    private static var cache: [String: NSImage] = [:]

    private var image: NSImage? {
        guard let path = article.cover else { return nil }
        if let hit = Self.cache[path] { return hit }
        let loaded = NSImage(contentsOfFile: path)
        Self.cache[path] = loaded
        return loaded
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            } else {
                FileBadge(format: article.format, sent: false)
            }
        }
    }
}

private struct FileBadge: View {
    let format: String
    let sent: Bool
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
            Text(label).font(.system(size: 7.5, weight: .bold)).kerning(0.3)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.secondary)
        .frame(width: 40, height: 56)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

    }
}

extension FileBadge {
    var label: String {
        switch format {
        case "MD", "MARKDOWN", "MD.ZIP": "MD"
        case "HTM", "XHTML", "HTML.ZIP", "HTM.ZIP", "HTMLZ": "HTML"
        case "JPEG": "JPG"
        case "TIFF": "TIF"
        default: format.replacingOccurrences(of: ".ZIP", with: "")
        }
    }
    var symbol: String {
        switch format {
        case "EPUB", "MOBI", "AZW", "AZW3", "PRC", "PDB", "TCR", "FB2", "FB3", "FB2.ZIP": "book.closed"
        case "PDF", "XPS", "DJVU", "DJV", "CHM": "doc.richtext"
        case "CBZ", "CBR", "CBT": "book.pages"
        case "PNG", "JPG", "JPEG", "GIF", "WEBP", "TIF", "TIFF": "photo"
        case "TXT", "TXT.ZIP": "doc.plaintext"
        case "HTML", "HTM", "XHTML", "HTMLZ", "HTML.ZIP", "HTM.ZIP": "globe"
        case "DOC", "DOCX", "DOCM", "ODT", "RTF", "RTF.ZIP": "doc.text"
        default: "text.alignleft"
        }
    }
}

private struct StatusChip: View {
    let article: Article
    var body: some View {
        HStack(spacing: 5) {
            if article.phase == .working { ProgressView().controlSize(.mini) }
            Text(label)
        }
        .font(.caption.weight(.medium)).foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(article.phase == .waiting ? 0.08 : 0.12), in: Capsule())
        .fixedSize()
        .help(article.phase == .done ? "已读回 Kindle 上的文件，校验一致" : article.details)
    }

    private var label: String {
        switch article.status {
        case "等待发送": "待发送"
        case "已发送": "已送达"
        case "失败" where article.deliveredTo?.isEmpty == false: "部分送达"
        default: article.status
        }
    }

    private var tint: Color {
        switch article.phase {
        case .done: .green
        case .working, .ready: .primary
        case .failed: .orange
        case .waiting, .stopped: .secondary
        }
    }
}

/// "中英对照 ▾": what this book becomes. Two questions in one menu: which version, and into which language.
private struct TranslationChoice: View {
    let article: Article
    @ObservedObject var store: PushStore

    /// Four languages at hand: the preference, this book's, the last few picked, then the common ones;
    /// never the book's own language.
    private var quick: [String] {
        var codes: [String] = []
        for code in [store.targetLanguage, store.goal(of: article)] + store.recentTargets + ["en", "zh", "ja", "zh-hant"]
        where !codes.contains(code) && code != article.language { codes.append(code) }
        return Array(codes.prefix(4))
    }

    var body: some View {
        let current = store.mode(of: article)
        let goal = store.goal(of: article)
        let sameLanguage = article.language == goal
        Menu {
            Section("版本") {
                Button { store.choose(.original, for: [article.id]) } label: {
                    check(current == .original, "原文，不翻译")
                }
                if !sameLanguage {
                    ForEach([OutputMode.bilingual, .targetOnly], id: \.self) { mode in
                        Button { store.choose(mode, for: [article.id]) } label: {
                            check(current == mode, store.title(mode, for: article))
                        }
                    }
                }
            }
            Section("翻译成") {
                ForEach(quick, id: \.self) { code in
                    Button { store.translate([article.id], into: code) } label: {
                        check(current != .original && goal == code,
                              Lang.picker(code) + (code == store.targetLanguage ? "（偏好）" : ""))
                    }
                }
                Menu("更多语言") {
                    ForEach(Lang.targets.filter { !quick.contains($0.code) && $0.code != article.language }, id: \.code) { target in
                        Button(target.picker) { store.translate([article.id], into: target.code) }
                    }
                }
            }
            if current != .original {
                Divider()
                Button("先试译 3 段") { Task { await store.preview(article.id) } }
                    .disabled(store.translation.running)
            }
        } label: {
            HStack(spacing: 3) {
                Text(store.title(current, for: article))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(current == .original ? Color.secondary : Color.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(current == .original ? 0 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(current == .original ? 0.14 : 0.2), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        // .button + .plain keeps the label as drawn; .borderlessButton drops the capsule and moves the chevron.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(current == .original ? "发送原文。点开可以翻译成任意语言" : "翻译成\(Lang.name(goal))后再发送或保存。点开可以换版本或语言")
        .accessibilityLabel("输出：\(store.title(current, for: article))")
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
