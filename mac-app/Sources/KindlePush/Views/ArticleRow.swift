import SwiftUI
import AppKit

struct ArticleRow: View {
    let article: Article
    @ObservedObject var store: PushStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            BookCover(article: article)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(article.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        .help(article.path)
                    if article.bilingual == true {
                        Text("中英对照").font(.caption2.weight(.semibold)).foregroundStyle(Color.ink)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Color.ink.opacity(0.08), in: Capsule())
                    }
                }
                Text(metaLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if article.phase == .working, let progress = article.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(.ink)
                        .frame(maxWidth: 240).padding(.top, 3)
                }
                if !article.details.isEmpty {
                    Text(article.details).font(.caption)
                        .foregroundStyle(article.phase == .failed ? Color.orange : Color.secondary)
                        .lineLimit(2).help(article.details)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if [.failed, .stopped].contains(article.phase) {
                    iconButton("arrow.clockwise", help: "再次发送") { store.retry(article.id) }
                }
                iconButton("magnifyingglass", help: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: article.path)])
                }
                iconButton("xmark", help: "从列表移除（不删除原文）") { store.remove(article.id) }
            }
            .opacity(hovering && !store.busy ? 1 : 0)
            StatusChip(article: article)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.3), value: article.progress)
    }

    /// Author, format and folder: what tells two books apart at a glance.
    private var metaLine: String {
        let label = FileBadge(format: article.format, sent: false).label
        return [article.author, label, article.author == nil || article.author?.isEmpty == true ? article.folder : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
        .accessibilityLabel(help)
    }
}

/// The book's own cover when there is one, else the format badge, sized like a small book.
private struct BookCover: View {
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
        .overlay(alignment: .bottomTrailing) {
            if article.phase == .done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color(nsColor: .textBackgroundColor)).padding(-1.5))
                    .offset(x: 6, y: 5)
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
    }

    private var label: String { article.status == "等待发送" ? "待发送" : article.status }

    private var tint: Color {
        switch article.phase {
        case .done: .green
        case .working, .ready: .primary
        case .failed: .orange
        case .waiting, .stopped: .secondary
        }
    }
}
