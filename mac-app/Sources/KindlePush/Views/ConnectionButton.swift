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
        .help(store.targets.isEmpty ? (store.connected ? "已连接 \(store.host)" : "连接 Kindle")
              : "书会发给 " + store.targets.map(\.name).joined(separator: "、"))
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
            if store.devices.count > 1 {
                DeviceList(store: store)
            }
            if store.setupNeeded {
                Button { store.showConnection = false; store.showAddKindle = true } label: {
                    Label("添加 Kindle", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ink).controlSize(.large)
            } else {
                Button { Task { await store.connect(); await store.refreshDevices(scan: store.devices.count > 1) } } label: {
                    Label(store.searching ? "正在寻找…" : "重新寻找", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(store.searching)
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
                .disabled(store.searching)
                Text("IP 在 KOReader › 网络 › 网络信息 里。换 Wi‑Fi 后先试重新寻找；访客网络会隔离设备。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !store.setupNeeded {
                    Button { store.showConnection = false; store.showAddKindle = true } label: {
                        Label("添加另一台 Kindle…", systemImage: "plus")
                    }
                    .buttonStyle(.inkLink).font(.caption)
                }
            }
        }
        .padding(18).frame(width: 330)
        .task { await store.refreshDevices() }
    }

    private var detail: String {
        if store.searching { return "正在当前 Wi‑Fi 中寻找已配对的 Kindle" }
        if !store.targets.isEmpty {
            let away = store.targets.filter { $0.online == false }.count
            let names = store.targets.map(\.name).joined(separator: "、")
            return away > 0 ? "\(names) · \(away) 台不在线" : names
        }
        if store.connected { return "已连接 · \(store.host)" }
        return store.connectionIssue.isEmpty ? "打开 KOReader，并连接同一个 Wi‑Fi" : store.connectionIssue
    }
}

/// Every paired Kindle: tick the ones books go to.
struct DeviceList: View {
    @ObservedObject var store: PushStore
    @State private var renaming: KindleDevice?
    @State private var newName = ""
    @State private var forgetting: KindleDevice?

    private var caption: String {
        if store.busy { return "正在发的书不受影响，改动从下一本开始。" }
        let count = store.targets.count
        return count > 0 ? "每本书都会发给这 \(count) 台；不在线的那台，之后可以单独补发。" : "可以勾选多台，一本书会发给每一台。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("发送到").font(.subheadline.weight(.medium))
                Spacer()
                if store.checkingDevices { ProgressView().controlSize(.mini) }
            }
            VStack(spacing: 2) {
                ForEach(store.devices) { device in
                    DeviceRow(device: device, chosen: device.selected == true,
                              // The last ticked one stays ticked (toggle ignores it): books have to go somewhere.
                              locked: store.searching,
                              lastOne: device.selected == true && store.devices.filter { $0.selected == true }.count == 1,
                              choose: { Task { await store.toggle(device) } },
                              rename: { newName = device.name; renaming = device },
                              forget: { forgetting = device })
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .alert("重命名 Kindle", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let device = renaming { Task { await store.rename(device, to: newName) } }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog("取消配对「\(forgetting?.name ?? "")」？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("取消配对", role: .destructive) {
                if let device = forgetting { Task { await store.forget(device) } }
            }
        } message: {
            Text("这台 Kindle 上的书不受影响。以后要再发给它，需要重新配对。")
        }
    }
}

private struct DeviceRow: View {
    let device: KindleDevice
    let chosen: Bool
    let locked: Bool
    let lastOne: Bool
    let choose: () -> Void
    let rename: () -> Void
    let forget: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: choose) {
                HStack(spacing: 10) {
                    Image(systemName: chosen ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15)).foregroundStyle(chosen ? Color.ink : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout.weight(chosen ? .semibold : .regular))
                        HStack(spacing: 5) {
                            Circle()
                                .fill(device.online == true ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .help(lastOne ? "至少要选一台" : chosen ? "不再发到这台" : "也发到这台")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            Menu {
                Button("重命名…", action: rename)
                Button("取消配对…", role: .destructive, action: forget)
            } label: {
                Image(systemName: "ellipsis").font(.callout).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovering ? 1 : 0.45)
            .help("重命名或取消配对")
            .accessibilityLabel("管理 \(device.name)")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(chosen ? 0.07 : hovering ? 0.04 : 0),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var status: String {
        switch device.online {
        case true: return "在线 · \(device.host)"
        case false: return device.host.isEmpty ? "不在这个 Wi‑Fi" : "不在线 · 上次 \(device.host)"
        default: return device.host
        }
    }
}
