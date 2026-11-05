import SwiftUI

/// What the app keeps on this Mac, and clearing what can safely go.
struct StorageView: View {
    @ObservedObject var store: PushStore
    @State private var usage: BridgeResponse?
    @State private var asking: Item?
    @State private var message = ""

    private enum Item: String, Identifiable {
        case jobs, covers, runtime
        var id: String { rawValue }
        var question: String {
            switch self {
            case .jobs: "清理翻译工作文件？"
            case .covers: "清理封面缓存？"
            case .runtime: "卸载翻译组件？"
            }
        }
        var note: String {
            switch self {
            case .jobs: "只清已译完的书，生成的译本不动，没译完的进度也不动。之后如果删了译本再翻译，要重新计费。"
            case .covers: "列表里还在用的封面会留下。"
            case .runtime: "翻译前要在翻译服务里重新安装，需要联网。设置和 Key 都保留。"
            }
        }
        var action: String {
            switch self {
            case .jobs, .covers: "清理"
            case .runtime: "卸载"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                row("已转换的书", usage?.outputBytes, "译本和转换好的文件，都是你的，不会自动删") {
                    Button("在访达中显示") { store.revealOutput() }
                }
                row("翻译工作文件", usage?.jobsBytes, jobsNote) {
                    Button("清理…") { asking = .jobs }.disabled((usage?.jobs ?? 0) == 0)
                }
                row("封面缓存", usage?.coversBytes, "列表里显示的封面") {
                    Button("清理…") { asking = .covers }.disabled((usage?.coversBytes ?? 0) == 0)
                }
                row("翻译组件", usage?.runtimeBytes, usage?.running == true ? "还有书在翻译，译完才能卸载" : "翻译时用的引擎，可以随时重新安装") {
                    Button("卸载…") { asking = .runtime }.disabled((usage?.runtimeBytes ?? 0) == 0 || usage?.running == true)
                }
            } footer: {
                if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
        .task { usage = await Bridge.call(["data-usage"]) }
        .confirmationDialog(asking?.question ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { item in
            Button(item.action, role: .destructive) { Task { await clean(item) } }
        } message: { Text($0.note) }
    }

    private var jobsNote: String {
        let count = usage?.jobs ?? 0
        return count > 0 ? "\(count) 本已译完的书留下的中间文件" : "没有可以清理的"
    }

    private func clean(_ item: Item) async {
        let keep = store.articles.compactMap(\.cover)
        let data = (try? JSONEncoder().encode(["keep": keep])).flatMap { String(data: $0, encoding: .utf8) }
        let response = await Bridge.call(["data-clean", item.rawValue], input: data)
        if response.ok { usage = response; message = "" } else { message = response.message ?? "没能清理。" }
        if item == .runtime { await store.refreshTranslationStatus() }
    }

    private func row(_ title: String, _ bytes: Int64?, _ note: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            action().controlSize(.small)
        }
    }
}
