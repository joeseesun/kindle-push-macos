import SwiftUI
import Security
import CryptoKit

struct TranslationSettingsView: View {
    @ObservedObject var store: PushStore
    @State private var base = ""
    @State private var model = ""
    @State private var key = ""
    @State private var message = ""
    @State private var working = false
    @State private var ready = false

    @State private var saved = false
    @State private var workers = 3
    @State private var style = "natural"
    @State private var glossary = ""

    private let styles: [(id: String, name: String, note: String)] = [
        ("natural", "自然流畅", "翻译引擎默认风格，适合大多数书。"),
        ("faithful", "忠实准确", "不增删信息，保留原文层次与语气，适合非虚构、历史、传记。"),
        ("literary", "文学润色", "更地道有文采，保留人物口吻，减少翻译腔，适合小说、散文。"),
        ("technical", "技术学术", "术语准确统一，首次出现保留英文原词，代码和公式不动。"),
    ]

    var body: some View {
        TabView {
            serviceForm.tabItem { Label("翻译服务", systemImage: "network") }
            qualityForm.tabItem { Label("质量与速度", systemImage: "wand.and.stars") }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if saved {
                    Label("已保存", systemImage: "checkmark").foregroundStyle(.green).transition(.opacity)
                } else if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || base.isEmpty || model.isEmpty)
            }
            .font(.callout).padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let response = await Bridge.call(["translation-settings"])
            base = response.base ?? ""; model = response.model ?? ""
            workers = response.workers ?? 3; style = response.style ?? "natural"; glossary = response.glossary ?? ""
            ready = response.runtimeReady ?? false
            if !response.ok { message = response.message ?? "无法读取配置。" }
        }
        .onChange(of: base) { saved = false }
        .onChange(of: model) { saved = false }
        .onChange(of: style) { saved = false }
        .onChange(of: workers) { saved = false }
        .onChange(of: glossary) { saved = false }
    }

    private var qualityForm: some View {
        Form {
            Section {
                Picker("译文风格", selection: $style) {
                    ForEach(styles, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("质量")
            } footer: {
                Text((styles.first { $0.id == style }?.note ?? "") + "改风格后会重新翻译，原有进度不会被覆盖。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                TextEditor(text: $glossary)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 96).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if glossary.isEmpty {
                            Text("Hari Seldon -> 哈里·谢顿\nPsychohistory -> 心理史学\n# 以 # 开头的行是备注")
                                .font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("术语表")
            } footer: {
                Text("每行一条「原文 -> 译名」，人名、地名、专有名词全书统一。只有出现这些词的段落才会带上术语，不增加其他段落的费用。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("同时翻译", selection: $workers) {
                    Text("1 章（最稳）").tag(1)
                    Text("2 章").tag(2)
                    Text("3 章（推荐）").tag(3)
                    Text("4 章（最快）").tag(4)
                }
            } header: {
                Text("速度")
            } footer: {
                Text("多章并行可快 2–4 倍，费用不变。服务限流或频繁失败时调低；并行时点停止需要等当前各章收尾。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var serviceForm: some View {
        Form {
            Section {
                TextField("服务地址", text: $base, prompt: Text("https://api.deepseek.com"))
                    .textContentType(.URL)
                TextField("模型", text: $model, prompt: Text("deepseek-chat"))
                SecureField("API Key", text: $key, prompt: Text("留空则保留现有密钥"))
            } header: {
                Text("翻译服务")
            } footer: {
                Text("兼容 OpenAI 接口的服务均可。书籍正文会发送到这里，按用量计费；密钥保存在 macOS 钥匙串，换地址需要填写对应的新密钥。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("翻译组件") {
                LabeledContent {
                    if ready {
                        Label("已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if working && message.hasPrefix("正在下载") {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("安装") { Task { await install() } }.disabled(working)
                    }
                } label: {
                    Text("中英对照引擎")
                    Text("基于开源 bilingual_book_maker，首次安装需要几分钟").font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }


    private func install() async {
        working = true; message = "正在下载并安装，首次可能需要几分钟…"
        let response = await Bridge.call(["translation-install"])
        ready = response.runtimeReady ?? false
        store.translationReady = ready
        message = ready ? "" : response.message ?? "安装未完成，请重试。"
        working = false
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
        let response = await Bridge.call(["translation-save", normalized, model, String(workers), style, glossary])
        working = false
        if response.ok {
            message = ""
            withAnimation { saved = true }
        } else { message = response.message ?? "设置保存失败。" }
    }
}
