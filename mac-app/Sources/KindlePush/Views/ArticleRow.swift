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
                        Text(article.chineseOnly == true ? "中文译本" : "中英对照").font(.caption2.weight(.semibold)).foregroundStyle(Color.ink)
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
                    iconButton("arrow.clockwise", help: "再次发送") { store.retry(article.id) }
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
            StatusChip(article: article)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.3), value: article.progress)
    }

    private var revealHelp: String {
        article.madeFile != nil ? "在访达中显示\(article.madeFileLabel)（双击行用默认程序打开）"
            : "在访达中显示（双击行用默认程序打开）"
    }

    /// Something the status chip does not already say: where the file went, a hint, or why it failed.
    private var detail: String? {
        switch article.phase {
        case .done:
            if article.details.contains("提示：") { return article.details }
            return "Kindle › 我的文章 › " + article.preferredURL.lastPathComponent
        case .ready where article.status == "已保存":
            let url = article.preferredURL
            return "本机 › " + url.deletingLastPathComponent().lastPathComponent + " › " + url.lastPathComponent
        default:
            return article.details.isEmpty ? nil : article.details
        }
    }

    /// Author, format and folder: what tells two books apart at a glance.
    private var metaLine: String {
        let label = FileBadge(format: article.format, sent: false).label
        return [article.author, label, article.author == nil || article.author?.isEmpty == true ? article.folder : nil]
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
