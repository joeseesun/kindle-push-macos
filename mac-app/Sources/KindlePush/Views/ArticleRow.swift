import SwiftUI
import AppKit

struct ArticleRow: View {
    let article: Article
    @ObservedObject var store: PushStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: article.status == "已发送" ? "checkmark.circle.fill" : "doc.text")
                .font(.title2).foregroundStyle(article.status == "已发送" ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).fontWeight(.medium).lineLimit(1).help(article.path)
                Text(article.details.isEmpty ? article.format + " · " + article.status : article.details)
                    .font(.caption).foregroundStyle(article.status == "失败" ? Color.orange : Color.secondary)
                    .lineLimit(2).help(article.details)
            }
            Spacer()
            if ["发送中", "翻译中", "试译中"].contains(article.status) { ProgressView().controlSize(.small) }
            else { Text(article.status).font(.caption).foregroundStyle(.secondary) }
            Button { store.remove(article.id) } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless).help("从列表移除，不删除原文").disabled(store.busy)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: article.path)]) }
            Button("再次发送") { store.retry(article.id) }.disabled(store.busy)
            Button("从列表移除") { store.remove(article.id) }.disabled(store.busy)
        }
    }
}
