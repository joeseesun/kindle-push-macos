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
                Text(t(store.connectionTitle)).font(.callout)
                if !store.outdatedKindles.isEmpty {
                    Image(systemName: "arrow.up.circle").font(.callout).foregroundStyle(.orange)
                        .accessibilityLabel(t("接收端可以升级"))
                }
            }
            .padding(.horizontal, 4)
        }
        .help(!store.outdatedKindles.isEmpty ? t("接收端可以升级：\(store.outdatedKindles.map(\.name).joined(separator: "、"))") : store.targets.isEmpty ? (store.connected ? t("已连接 \(store.host)") : t("连接 Kindle"))
              : t("书会发给 \(store.targets.map(\.name).joined(separator: "、"))"))
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
                    Text(t(store.connectionTitle)).font(.headline)
                    Text(t(detail)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if store.devices.count > 1 {
                DeviceList(store: store)
            }
            ReceiverNotice(store: store)
            if store.setupNeeded {
                Button { store.showConnection = false; store.showAddKindle = true } label: {
                    Label(t("添加 Kindle"), systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ink).controlSize(.large)
            } else {
                Button { Task { await store.connect(); await store.refreshDevices(scan: store.devices.count > 1) } } label: {
                    Label(store.searching ? t("正在寻找…") : t("重新寻找"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(store.searching)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(t("手动连接")).font(.subheadline.weight(.medium))
                HStack {
                    TextField(t("Kindle IP，例如 192.168.1.42"), text: $store.manualHost)
                        .textFieldStyle(.roundedBorder).focused($ipFocused)
                        .onSubmit { Task { await store.connect(manual: true) } }
                    Button(t("连接")) { Task { await store.connect(manual: true) } }
                        .disabled(store.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .disabled(store.searching)
                Text(t("IP 在 KOReader › 网络 › 网络信息 里。换 Wi‑Fi 后先试重新寻找；访客网络会隔离设备。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !store.setupNeeded {
                    Button { store.showConnection = false; store.showAddKindle = true } label: {
                        Label(t("添加另一台 Kindle…"), systemImage: "plus")
                    }
                    .buttonStyle(.inkLink).font(.caption)
                }
            }
        }
        .padding(18).frame(width: 330)
        .task { await store.refreshDevices() }
    }

    private var detail: String {
        if store.searching { return t("正在当前 Wi‑Fi 中寻找已配对的 Kindle") }
        if !store.targets.isEmpty {
            let away = store.targets.filter { $0.online == false }.count
            let names = store.targets.map(\.name).joined(separator: "、")
            return away > 0 ? t("\(names) · \(away) 台不在线") : names
        }
        if store.connected { return t("已连接 · \(store.host)") }
        return store.connectionIssue.isEmpty ? t("打开 KOReader，并连接同一个 Wi‑Fi") : store.connectionIssue
    }
}

/// A paired Kindle whose receiver is behind: what that means, and the way to fix it.
/// One Kindle or several, this is the only place a user would otherwise never learn it.
struct ReceiverNotice: View {
    @ObservedObject var store: PushStore

    var body: some View {
        let old = store.outdatedKindles
        if let first = old.first {
            VStack(alignment: .leading, spacing: 8) {
                Label(old.count == 1 ? t("「\(first.name)」的接收端是旧版") : t("\(old.count) 台 Kindle 的接收端是旧版"), systemImage: "arrow.up.circle")
                    .font(.callout.weight(.semibold))
                Text(t("EPUB、Word、TXT 照常能发，PDF 会转成图片版。MOBI、DjVu、漫画要升级后才能发。升级要插一次 USB，配对和书都不受影响。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(old) { device in
                    Button { store.startUpgrade(device) } label: {
                        Text(old.count == 1 ? t("用 USB 升级…") : t("升级「\(device.name)」…"))
                    }
                    .buttonStyle(.inkOutline).controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Every paired Kindle: tick the ones books go to.
struct DeviceList: View {
    @ObservedObject var store: PushStore
    @State private var renaming: KindleDevice?
    @State private var newName = ""
    @State private var forgetting: KindleDevice?

    private var caption: String {
        if store.busy { return t("正在发的书不受影响，改动从下一本开始。") }
        let count = store.targets.count
        return count > 0 ? t("每本书都会发给这 \(count) 台；不在线的那台，之后可以单独补发。") : t("可以勾选多台，一本书会发给每一台。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("发送到")).font(.subheadline.weight(.medium))
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
        .alert(t("重命名 Kindle"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(t("名字"), text: $newName)
            Button(t("取消"), role: .cancel) {}
            Button(t("保存")) {
                if let device = renaming { Task { await store.rename(device, to: newName) } }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog(t("取消配对「\(forgetting?.name ?? "")」？"), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button(t("取消配对"), role: .destructive) {
                if let device = forgetting { Task { await store.forget(device) } }
            }
        } message: {
            Text(t("这台 Kindle 上的书不受影响。以后要再发给它，需要重新配对。"))
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
            .help(lastOne ? t("至少要选一台") : chosen ? t("不再发到这台") : t("也发到这台"))
            .accessibilityAddTraits(chosen ? .isSelected : [])
            Menu {
                Button(t("重命名…"), action: rename)
                Button(t("取消配对…"), role: .destructive, action: forget)
            } label: {
                Image(systemName: "ellipsis").font(.callout).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovering ? 1 : 0.45)
            .help(t("重命名或取消配对"))
            .accessibilityLabel(t("管理 \(device.name)"))
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(chosen ? 0.07 : hovering ? 0.04 : 0),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var status: String {
        switch device.online {
        case true: return device.outdated == true ? t("在线 · 接收端旧版") : t("在线 · \(device.host)")
        case false: return device.host.isEmpty ? t("不在这个 Wi‑Fi") : t("不在线 · 上次 \(device.host)")
        default: return device.host
        }
    }
}
