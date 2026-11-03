import SwiftUI

struct ConnectionButton: View {
    @ObservedObject var store: PushStore

    private var dot: Color {
        if store.searching { return .yellow }
        return store.connected ? .green : .orange
    }

    var body: some View {
        Button { store.showConnection.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .shadow(color: dot.opacity(0.6), radius: store.connected ? 2 : 0)
                Text(store.connectionTitle).font(.callout)
            }
            .padding(.horizontal, 4)
        }
        .help(store.connected ? "已连接 \(store.host)" : "连接 Kindle")
        .popover(isPresented: $store.showConnection, arrowEdge: .bottom) {
            ConnectionPopover(store: store)
        }
    }
}

private struct ConnectionPopover: View {
    @ObservedObject var store: PushStore
    @FocusState private var ipFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "ipad.gen1")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(store.connected ? Color.ink : Color.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.connectionTitle).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if store.setupNeeded {
                InkLink(url: URL(string: "https://github.com/joeseesun/kindle-push-macos/blob/main/docs/SETUP.md")!) {
                    Label("查看首次配置指南", systemImage: "book")
                }
            } else {
                Button { Task { await store.connect() } } label: {
                    Label(store.searching ? "正在寻找…" : "重新寻找", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(store.busy || store.searching)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("手动连接").font(.subheadline.weight(.medium))
                HStack {
                    TextField("Kindle IP，例如 192.168.1.42", text: $store.manualHost)
                        .textFieldStyle(.roundedBorder).focused($ipFocused)
                        .onSubmit { Task { await store.connect(manual: true) } }
                    Button("连接") { Task { await store.connect(manual: true) } }
                        .disabled(store.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .disabled(store.busy || store.searching)
                Text("IP 在 KOReader › 网络 › 网络信息 里。换 Wi‑Fi 后先试重新寻找；访客网络会隔离设备。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(width: 330)
    }

    private var detail: String {
        if store.searching { return "正在当前 Wi‑Fi 中寻找已配对的 Kindle" }
        if store.connected { return "已连接 · \(store.host)" }
        return store.connectionIssue.isEmpty ? "打开 KOReader，并连接同一个 Wi‑Fi" : store.connectionIssue
    }
}
