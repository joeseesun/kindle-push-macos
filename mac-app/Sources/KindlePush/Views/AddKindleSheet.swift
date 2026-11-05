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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加 Kindle").font(.title2.weight(.semibold))
                Text("适用于已越狱、运行过 KOReader 的 Kindle。每台只需做一次，之后换 Wi‑Fi 也不用重来。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Step(number: 1, title: "用 USB 写入接收配置") { usbStep }
            Step(number: 2, title: "在 Wi‑Fi 里配对") { wifiStep }
            HStack {
                InkLink(url: URL(string: "https://github.com/joeseesun/kindle-push-macos/blob/main/docs/SETUP.md")!) {
                    Text("遇到问题？看配置说明")
                }
                .font(.caption)
                Spacer()
                Button(paired.isEmpty ? "取消" : "完成") { dismiss() }
                    .keyboardShortcut(paired.isEmpty ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
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
            Text("在 KOReader 里选「退出」回到原生书库，再用数据线连接 Mac。Kindle 显示「USB 驱动器模式」后，它会出现在这里。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("这台 Kindle 已经写入过？直接做第 2 步。").font(.caption).foregroundStyle(.secondary)
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
                    Button("推出") { eject(volume) }
                } else if installing == volume.path {
                    ProgressView().controlSize(.small)
                } else {
                    Button("写入") { Task { await install(volume) } }
                        .buttonStyle(.ink).disabled(!volume.ready || installing != nil)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        if !usbError.isEmpty {
            Text(usbError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func volumeStatus(_ volume: KindleVolume) -> String {
        if !volume.ready { return "没找到 KOReader 的 SSH 组件，请先在 Kindle 上运行一次 KOReader" }
        if volume.installed { return "已写入。推出后拔线，进行第 2 步" }
        return "会写入接收脚本和本机公钥，原文件先备份"
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
            usbError = "没能推出：\(error.localizedDescription) 请在访达里推出。"
        }
    }

    // MARK: Step 2

    @ViewBuilder private var wifiStep: some View {
        Text("拔线后在 Kindle 上打开 KOReader，连到和这台 Mac 相同的 Wi‑Fi。")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { Task { await search() } } label: {
                Label(searching ? "正在寻找…" : "寻找新的 Kindle", systemImage: "magnifyingglass")
            }
            .disabled(searching)
            if searching { ProgressView().controlSize(.small) }
        }
        ForEach(found) { kindle in candidateRow(kindle) }
        if searched && !searching && found.isEmpty {
            Text(searchError.isEmpty ? "没找到新的 Kindle。确认 KOReader 已打开、Wi‑Fi 相同；访客网络会隔离设备。也可以输入 Kindle 的 IP（KOReader › 网络 › 网络信息）：" : searchError)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("例如 192.168.1.43", text: $manualHost).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search(at: manualHost) } }
                Button("查找") { Task { await search(at: manualHost) } }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
        }
        ForEach(paired, id: \.self) { name in
            Label("已配对「\(name)」，书会发到它", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }

    @ViewBuilder private func candidateRow(_ kindle: NewKindle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "ipad.gen1").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindle.host).font(.callout.weight(.medium))
                    Text("设备指纹 \(kindle.fingerprint.prefix(19))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        .help(kindle.fingerprint).textSelection(.enabled)
                }
                Spacer()
            }
            if kindle.ready {
                HStack {
                    TextField("名字", text: Binding(get: { names[kindle.key] ?? defaultName },
                                                    set: { names[kindle.key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    if pairing == kindle.key {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("配对") { Task { await pair(kindle) } }.buttonStyle(.ink).disabled(pairing != nil)
                    }
                }
            } else if let reason = kindle.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var defaultName: String {
        store.devices.isEmpty && paired.isEmpty ? "我的 Kindle" : "Kindle \(store.devices.count + 1)"
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
