import SwiftUI
import AppKit

/// Pair a Kindle without the terminal: write the receiver over USB, then pair it over Wi-Fi.
struct AddKindleSheet: View {
    @ObservedObject var store: PushStore
    @Environment(\.dismiss) private var dismiss

    @State private var volumes: [KindleVolume] = []
    @State private var installing: String?
    @State private var usbError = ""
    @State private var found: [NewKindle] = []
    @State private var names: [String: String] = [:]
    @State private var searching = false
    @State private var searched = false
    @State private var searchError = ""
    @State private var manualHost = ""
    @State private var pairing: String?
    @State private var paired: [String] = []
    @State private var checking = false
    @State private var checked = false

    private var upgradeDone: Bool {
        guard let target = store.upgrading else { return false }
        return checked && store.devices.first { $0.id == target.id }?.outdated == false
            && store.devices.first { $0.id == target.id }?.online == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.upgrading.map { t("升级「\($0.name)」的接收端") } ?? t("添加 Kindle")).font(.title2.weight(.semibold))
                Text(store.upgrading == nil ? t("适用于已越狱、运行过 KOReader 的 Kindle。每台只需做一次，之后换 Wi‑Fi 也不用重来。")
                     : t("升级后才能发 MOBI、DjVu、漫画等格式。接收端在 Kindle 上受保护，只能通过 USB 更新。不用重新配对，书也不受影响。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Step(number: 1, title: t("用 USB 写入接收配置")) { usbStep }
            if store.upgrading == nil {
                Step(number: 2, title: t("在 Wi‑Fi 里配对")) { wifiStep }
            } else {
                Step(number: 2, title: t("拔线，确认升级成功")) { checkStep }
            }
            HStack {
                InkLink(url: URL(string: "https://github.com/joeseesun/kindle-push-macos/blob/main/docs/SETUP.md")!) {
                    Text(t("遇到问题？看配置说明"))
                }
                .font(.caption)
                Spacer()
                Button(paired.isEmpty && !upgradeDone ? t("取消") : t("完成")) { dismiss() }
                    .keyboardShortcut(paired.isEmpty && !upgradeDone ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await store.refreshDevices() }
        .task {
            // Notice a Kindle being plugged in or ejected while the sheet is open.
            while !Task.isCancelled {
                if installing == nil { volumes = await store.usbVolumes() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Step 1

    @ViewBuilder private var usbStep: some View {
        if volumes.isEmpty {
            if store.kindlePlugged {
                // The cable is fine; saying "connect it" here would send people in circles.
                Label(t("线已经连上了。还差一步：在 Kindle 的 KOReader 里选「退出」回到原生书库。显示「USB 驱动器模式」后，它会出现在这里。"), systemImage: "cable.connector")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("在 KOReader 里选「退出」回到原生书库，再用数据线连接 Mac。Kindle 显示「USB 驱动器模式」后，它会出现在这里。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.upgrading == nil {
                Text(t("这台 Kindle 已经写入过？直接做第 2 步。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(volumes) { volume in
            HStack(spacing: 10) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name).font(.callout.weight(.medium))
                    Text(volumeStatus(volume)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if volume.installed {
                    Button(t("推出")) { eject(volume) }
                } else if installing == volume.path {
                    ProgressView().controlSize(.small)
                } else {
                    Button(volume.outdated == true ? t("升级") : t("写入")) { Task { await install(volume) } }
                        .buttonStyle(.ink).disabled(!volume.ready || installing != nil)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        if !usbError.isEmpty {
            Text(t(usbError)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func volumeStatus(_ volume: KindleVolume) -> String {
        if !volume.ready { return t("没找到 KOReader 的 SSH 组件，请先在 Kindle 上运行一次 KOReader") }
        if volume.installed { return t("已写入。推出后拔线，进行第 2 步") }
        if volume.outdated == true { return t("接收端是旧版。点升级写入新版，原文件先备份") }
        return t("会写入接收脚本和本机公钥，原文件先备份")
    }

    private func install(_ volume: KindleVolume) async {
        installing = volume.path; usbError = ""
        if let error = await store.usbInstall(volume.path) { usbError = error }
        volumes = await store.usbVolumes()
        installing = nil
    }

    private func eject(_ volume: KindleVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
            volumes.removeAll { $0.path == volume.path }
            usbError = ""
        } catch {
            usbError = t("没能推出：\(error.localizedDescription) 请在访达里推出。")
        }
    }

    // MARK: Step 2 (upgrading)

    @ViewBuilder private var checkStep: some View {
        Text(t("拔线后在 Kindle 上打开 KOReader，连到和这台 Mac 相同的 Wi‑Fi，再点检查。"))
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { Task { await check() } } label: {
                Label(checking ? t("正在检查…") : t("检查"), systemImage: "checkmark.circle")
            }
            .disabled(checking)
            if checking { ProgressView().controlSize(.small) }
        }
        if upgradeDone {
            Label(t("升级成功，MOBI、DjVu、漫画现在都能发了"), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else if checked && !checking, let target = store.upgrading {
            let device = store.devices.first { $0.id == target.id }
            Text(device?.online == true ? t("它的接收端还是旧版。请确认刚才写入的是这台 Kindle，并已推出。")
                                        : t("还没连上这台 Kindle。确认 KOReader 已打开、Wi‑Fi 相同，再点检查。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check() async {
        checking = true
        await store.refreshDevices(scan: true)
        checked = true; checking = false
    }

    // MARK: Step 2

    @ViewBuilder private var wifiStep: some View {
        Text(t("拔线后在 Kindle 上打开 KOReader，连到和这台 Mac 相同的 Wi‑Fi。"))
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { Task { await search() } } label: {
                Label(searching ? t("正在寻找…") : t("寻找新的 Kindle"), systemImage: "magnifyingglass")
            }
            .disabled(searching)
            if searching { ProgressView().controlSize(.small) }
        }
        ForEach(found) { kindle in candidateRow(kindle) }
        if searched && !searching && found.isEmpty {
            Text(searchError.isEmpty ? t("没找到新的 Kindle。确认 KOReader 已打开、Wi‑Fi 相同；访客网络会隔离设备。也可以输入 Kindle 的 IP（KOReader › 网络 › 网络信息）：") : searchError)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(t("例如 192.168.1.43"), text: $manualHost).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search(at: manualHost) } }
                Button(t("查找")) { Task { await search(at: manualHost) } }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
        }
        ForEach(paired, id: \.self) { name in
            Label(t("已配对「\(name)」，书会发到它"), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }

    @ViewBuilder private func candidateRow(_ kindle: NewKindle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "ipad.gen1").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindle.host).font(.callout.weight(.medium))
                    Text(t("设备指纹 \(kindle.fingerprint.prefix(19))…")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .help(kindle.fingerprint).textSelection(.enabled)
                }
                Spacer()
            }
            if kindle.ready {
                HStack {
                    TextField(t("名字"), text: Binding(get: { names[kindle.key] ?? defaultName },
                                                    set: { names[kindle.key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    if pairing == kindle.key {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(t("配对")) { Task { await pair(kindle) } }.buttonStyle(.ink).disabled(pairing != nil)
                    }
                }
            } else if let reason = kindle.reason {
                Text(t(reason)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var defaultName: String {
        store.devices.isEmpty ? t("我的 Kindle") : "Kindle \(store.devices.count + 1)"
    }

    private func search(at host: String? = nil) async {
        searching = true; searchError = ""
        let result = await store.findNewKindles(at: host?.trimmingCharacters(in: .whitespaces))
        found = result.found; searchError = result.error ?? ""
        searching = false; searched = true
    }

    private func pair(_ kindle: NewKindle) async {
        pairing = kindle.key
        let name = (names[kindle.key] ?? defaultName).trimmingCharacters(in: .whitespaces)
        if let error = await store.pair(kindle, name: name) {
            searchError = error; found.removeAll { $0.key == kindle.key }; searched = true
        } else {
            paired.append(store.deviceName.isEmpty ? name : store.deviceName)
            found.removeAll { $0.key == kindle.key }
            searched = false   // not "nothing found": the one found was just paired
        }
        pairing = nil
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold)).foregroundStyle(Color.onInk)
                .frame(width: 22, height: 22).background(Color.ink, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
