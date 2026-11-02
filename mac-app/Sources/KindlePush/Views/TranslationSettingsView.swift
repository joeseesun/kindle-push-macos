import SwiftUI
import AppKit
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
    @State private var serviceID = "deepseek"
    @State private var models: [RemoteModel] = []
    @State private var manualModel = false
    @State private var loadingModels = false
    @State private var modelNote = ""
    @State private var modelNoteIsError = false
    @State private var savedBase = ""
    @State private var savedHasKey = false
    @State private var signingIn = false
    @State private var codexInstalled: Bool?
    @State private var codexLoggedIn = false
    @State private var codexPlan: String?
    @State private var codexEmail: String?

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
                    .buttonStyle(.ink).keyboardShortcut(.defaultAction)
                    .disabled(working || signingIn || model.isEmpty || (service.signIn != .chatgpt && trimmedBase.isEmpty)
                              || (service.signIn == .chatgpt && !codexLoggedIn))
            }
            .font(.callout).padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let response = await Bridge.call(["translation-settings"])
            base = response.base ?? ""; model = response.model ?? ""
            savedBase = base; savedHasKey = response.hasKey ?? false
            serviceID = ProviderCatalog.match(provider: response.provider ?? "", base: base).id
            workers = response.workers ?? 3; style = response.style ?? "natural"; glossary = response.glossary ?? ""
            ready = response.runtimeReady ?? false
            if !response.ok { message = response.message ?? "无法读取配置。" }
            await loadModels()
        }
        .onChange(of: base) { saved = false }
        .onChange(of: model) { saved = false }
        .onChange(of: style) { saved = false }
        .onChange(of: workers) { saved = false }
        .onChange(of: glossary) { saved = false }
        .onChange(of: serviceID) { saved = false }
        .onChange(of: key) { saved = false }
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
                Picker("同时翻译", selection: serviceID == "chatgpt" ? .constant(1) : $workers) {
                    Text("1 章（最稳）").tag(1)
                    Text("2 章").tag(2)
                    Text("3 章（推荐）").tag(3)
                    Text("4 章（最快）").tag(4)
                }
            } header: {
                Text("速度")
            } footer: {
                Text(serviceID == "chatgpt" ? "用 ChatGPT 账号翻译时一次只能翻一章。" : "多章并行可快 2–4 倍，费用不变。服务限流或频繁失败时调低；并行时点停止需要等当前各章收尾。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var service: ModelService { ProviderCatalog.service(serviceID) ?? ProviderCatalog.service("custom")! }

    private var serviceForm: some View {
        Form {
            Section {
                Picker("服务", selection: Binding(get: { serviceID }, set: { pick($0) })) {
                    ForEach(ModelService.Group.allCases, id: \.self) { group in
                        Section(group.rawValue) {
                            ForEach(ProviderCatalog.all.filter { $0.group == group }) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                    }
                }
                if service.signIn == .chatgpt {
                    chatgptRows
                } else {
                    if service.group == .custom || service.group == .local {
                        TextField("服务地址", text: $base, prompt: Text("https://example.com/v1"))
                            .textContentType(.URL)
                            .onSubmit { Task { await loadModels() } }
                    }
                    if service.needsKey || service.group == .custom {
                        SecureField("API Key", text: $key, prompt: Text(keySaved ? "已保存，留空则不变" : "粘贴 API Key"))
                            .onSubmit { Task { await loadModels() } }
                        if service.keyURL != nil || service.signIn == .key {
                        HStack(spacing: 14) {
                            if let url = service.keyURL.flatMap(URL.init(string:)) {
                                Link(destination: url) { Label("获取 API Key", systemImage: "arrow.up.right.square") }
                            }
                            if service.signIn == .key {
                                Button { Task { await signInForKey() } } label: {
                                    Label(signingIn ? "正在等待浏览器授权…" : "登录\(service.name)，自动填入 Key", systemImage: "person.badge.key")
                                }
                                .buttonStyle(.link).disabled(signingIn)
                            }
                            Spacer()
                        }
                        .font(.callout)
                        }
                    }
                }
            } header: {
                Text("翻译服务")
            } footer: {
                Text(serviceNote)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if !manualModel && !modelChoices.isEmpty {
                    HStack {
                        Picker("模型", selection: $model) {
                            let recommended = modelChoices.filter(isRecommended)
                            if !recommended.isEmpty {
                                Section("推荐") { ForEach(recommended) { Text($0.name).tag($0.id) } }
                            }
                            Section(recommended.isEmpty ? "" : "全部") {
                                ForEach(modelChoices.filter { !isRecommended($0) }) { Text($0.name).tag($0.id) }
                            }
                        }
                        Button { Task { await loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("重新读取模型列表").disabled(loadingModels)
                    }
                } else {
                    TextField("模型", text: $model, prompt: Text(service.popular.first ?? "模型 ID"))
                }
                HStack(spacing: 8) {
                    if loadingModels {
                        ProgressView().controlSize(.small)
                        Text("正在读取模型列表…").foregroundStyle(.secondary)
                    } else if !modelNote.isEmpty {
                        Text(modelNote).foregroundStyle(modelNoteIsError ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !modelChoices.isEmpty {
                        Button(manualModel ? "从列表选择" : "手动填写") { manualModel.toggle() }.buttonStyle(.link)
                    }
                }
                .font(.caption)
            } header: {
                Text("模型")
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

    private func pick(_ id: String) {
        guard id != serviceID else { return }
        serviceID = id
        base = service.base; key = ""; manualModel = false; modelNote = ""
        models = []; model = service.popular.first ?? ""
        Task { await loadModels() }
    }

    @ViewBuilder private var chatgptRows: some View {
        if codexInstalled == false {
            LabeledContent("Codex 命令行") { Text("还没有安装").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                Text("用 ChatGPT 账号翻译要借助 OpenAI 的 Codex 命令行工具。在「终端」运行下面一行安装：")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(installCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    }
                    Button("装好了，重新检测") { Task { await loadModels() } }
                }
            }
        } else if codexLoggedIn {
            LabeledContent("账号") {
                HStack(spacing: 10) {
                    Text([codexEmail, codexPlan.map { $0.capitalized + " 套餐" }].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Button("退出登录") { Task { await codexCall("codex-logout") } }.disabled(signingIn)
                }
            }
        } else {
            LabeledContent {
                Button(signingIn ? "正在等待浏览器登录…" : "用 ChatGPT 登录") { Task { await codexCall("codex-login") } }
                    .buttonStyle(.ink).disabled(signingIn || codexInstalled == nil)
            } label: {
                Text("账号")
                Text("会打开浏览器登录，Plus、Pro、Business 套餐都可以").font(.caption)
            }
        }
    }

    private let installCommand = "brew install --cask codex"

    private var serviceNote: String {
        switch service.group {
        case .account: "用 ChatGPT 套餐额度翻译，不按 API 计费，受套餐的 5 小时用量限制；一次翻译一章。书籍正文会发给 OpenAI。"
        case .local: "模型跑在这台 Mac 上，正文不出本机。先在 \(service.name) 里下载并运行模型。"
        default: "书籍正文会发给\(service.name == "自定义服务" ? "这个服务" : service.name)，按用量计费。API Key 存在 macOS 钥匙串里，换服务要填对应的 Key。"
        }
    }

    private var modelChoices: [RemoteModel] {
        var list = models.isEmpty ? service.popular.map { RemoteModel(id: $0, name: $0) } : models
        if !model.isEmpty && !list.contains(where: { $0.id == model }) { list.insert(RemoteModel(id: model, name: model), at: 0) }
        return list
    }

    private func isRecommended(_ item: RemoteModel) -> Bool {
        service.popular.contains(item.id) || item.default == true
    }

    private var keySaved: Bool { savedHasKey && trimmedBase == savedBase }
    private var trimmedBase: String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func loadModels() async {
        loadingModels = true; defer { loadingModels = false }
        modelNote = ""; modelNoteIsError = false
        if service.signIn == .chatgpt {
            let status = await Bridge.call(["codex-status"])
            codexInstalled = status.installed ?? false; codexLoggedIn = status.loggedIn ?? false
            codexPlan = status.plan; codexEmail = status.email
            models = status.models ?? []
            if model.isEmpty, let first = models.first(where: { $0.default == true }) ?? models.first {
                model = first.id
            }
            if let note = status.message, !note.isEmpty { modelNote = note }
            return
        }
        guard !trimmedBase.isEmpty else { models = []; return }
        if service.needsKey && key.isEmpty && !keySaved {
            models = []; modelNote = "填好 API Key 后按回车，会自动读取可用模型。"; return
        }
        let response = await Bridge.call(["models", trimmedBase] + (key.isEmpty ? [] : ["--key-stdin"]),
                                         input: key.isEmpty ? nil : key)
        if response.ok, let list = response.models {
            models = list
            if model.isEmpty || !list.contains(where: { $0.id == model }) && !service.popular.isEmpty && service.popular.first == model {
                model = list.first(where: isRecommended)?.id ?? list.first?.id ?? model
            }
            modelNote = "共 \(list.count) 个模型"
        } else {
            models = []; modelNote = response.message ?? "读不到模型列表，可以手动填写。"; modelNoteIsError = true
        }
    }

    private func codexCall(_ command: String) async {
        signingIn = true; defer { signingIn = false }
        let response = await Bridge.call([command])
        if !response.ok { message = response.message ?? "没有完成。" }
        await loadModels()
    }

    private func signInForKey() async {
        signingIn = true; defer { signingIn = false }
        let response = await Bridge.call(["sign-in-key", service.id])
        if response.ok, let value = response.key {
            key = value
            message = "已拿到 \(service.name) 的 Key，点保存后生效。"
            await loadModels()
        } else { message = response.message ?? "授权没有完成。" }
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
        if service.signIn == .chatgpt {
            await finishSave(base: ""); return
        }
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
        await finishSave(base: normalized)
    }

    private func finishSave(base normalized: String) async {
        let fields: [String: Any] = ["base": normalized, "model": model.trimmingCharacters(in: .whitespaces),
                                     "workers": String(workers), "style": style, "glossary": glossary, "provider": serviceID]
        let json = String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        let response = await Bridge.call(["translation-save", json])
        working = false
        if response.ok {
            message = ""
            savedBase = normalized; savedHasKey = response.hasKey ?? false
            store.translationProvider = serviceID
            withAnimation { saved = true }
        } else { message = response.message ?? "设置保存失败。" }
    }
}
