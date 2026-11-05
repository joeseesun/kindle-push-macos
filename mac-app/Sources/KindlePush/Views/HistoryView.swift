import SwiftUI

/// Toolbar button and panel: every book sent to a Kindle, to find and send again after the list is cleared.
struct HistoryButton: View {
    @ObservedObject var store: PushStore

    var body: some View {
        Button { store.showHistory.toggle() } label: {
            Label("发送历史", systemImage: "clock.arrow.circlepath")
        }
        .help("发送历史：找回发过的书，再发一次")
        .popover(isPresented: $store.showHistory, arrowEdge: .bottom) { HistoryPanel(store: store) }
    }
}

private struct HistoryPanel: View {
    @ObservedObject var store: PushStore
    @State private var query = ""
    @State private var confirmClear = false

    private var shown: [SendRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.history }
        return store.history.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.author ?? "").localizedCaseInsensitiveContains(q)
                || $0.device.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("发送历史").font(.headline)
                Spacer()
                Text("\(store.history.count) 本").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            TextField("搜索书名、作者或设备", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            if store.history.isEmpty {
                empty("还没有发送记录", "发到 Kindle 的书会记在这里。清除列表后，也能从这里找回再发。")
            } else if shown.isEmpty {
                empty("没有匹配的书", "换个关键词试试。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { HistoryRow(entry: $0, store: store) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Text("清除列表不会清掉这里的记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空历史…") { confirmClear = true }
                    .buttonStyle(.inkLink).font(.caption).disabled(store.history.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 400)
        .confirmationDialog("清空全部发送历史？", isPresented: $confirmClear) {
            Button("清空历史", role: .destructive) { store.clearHistory() }
        } message: {
            Text("只删除这里的记录，Kindle 和本机上的书都不受影响。")
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "clock").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 24)
    }
}

private struct HistoryRow: View {
    let entry: SendRecord
    @ObservedObject var store: PushStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                    .foregroundStyle(entry.exists ? Color.primary : Color.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.exists {
                Button { store.resend([entry]) } label: {
                    Label("再发", systemImage: "arrow.uturn.up")
                }
                .controlSize(.small)
                .help("放回待发送列表")
                Button { store.revealHistory(entry) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("在访达中显示原文件")
            } else {
                Text("原文件已不在").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            if entry.exists {
                Button("再发一次") { store.resend([entry]) }
                Button("在访达中显示") { store.revealHistory(entry) }
                Divider()
            }
            Button("从历史中删除") { store.forgetHistory([entry.id]) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.device.isEmpty { parts.append(entry.device) }
        parts.append(entry.earlier == true ? "更早" : entry.date.formatted(.relative(presentation: .named)))
        parts.append(entry.translated ? "中英对照" : entry.format)
        return parts.joined(separator: " · ")
    }
}
