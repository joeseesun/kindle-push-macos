import SwiftUI
import Security
import CryptoKit

struct TranslationSettingsView: View {
    @ObservedObject var store: PushStore
    @Environment(\.dismiss) private var dismiss
    @State private var base = ""
    @State private var model = ""
    @State private var key = ""
    @State private var message = ""
    @State private var working = false
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("翻译设置").font(.title2.bold())
            Text("默认使用 DeepSeek Flash，生成原文与简体中文逐段对照的 EPUB。原书保留。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("服务地址", text: $base).textContentType(.URL)
                TextField("模型名称", text: $model)
                SecureField("API Key（留空保留现有密钥）", text: $key)
            }.textFieldStyle(.roundedBorder)
            Text("书籍正文会发送至上述模型服务，可能产生 API 费用。密钥保存在 macOS 钥匙串；更换地址需要对应的新密钥。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(ready ? "翻译组件已就绪" : "需要安装翻译组件", systemImage: ready ? "checkmark.circle" : "arrow.down.circle")
                    .font(.callout)
                Spacer()
                if !ready {
                    Button("安装翻译组件") {
                        working = true; message = "正在下载并安装，首次可能需要几分钟…"
                        Task {
                            let response = await Bridge.call(["translation-install"])
                            ready = response.runtimeReady ?? false
                            message = ready ? "安装完成" : response.message ?? "安装未完成，请重试。"
                            working = false
                        }
                    }.disabled(working)
                }
            }
            if working { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || base.isEmpty || model.isEmpty)
            }
        }
        .padding(24).frame(width: 520)
        .task {
            let response = await Bridge.call(["translation-settings"])
            base = response.base ?? ""; model = response.model ?? ""
            ready = response.runtimeReady ?? false
            if !response.ok { message = response.message ?? "无法读取配置。" }
        }
    }

    private func save() async {
        working = true
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Validate before associating any credential with the destination.
        guard let url = URL(string: normalized), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            message = "请填写 HTTPS 服务地址，本机服务可使用 HTTP。"; working = false; return
        }
        if !key.isEmpty {
            let account = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "local.chase.KindlePush.translation",
                                       kSecAttrAccount as String: account]
            let data = Data(key.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                message = "无法保存密钥，请解锁 macOS 钥匙串后重试。"; working = false; return
            }
            key = ""
        }
        let response = await Bridge.call(["translation-save", normalized, model])
        working = false
        if response.ok { dismiss() }
        else { message = response.message ?? "设置保存失败。" }
    }
}
