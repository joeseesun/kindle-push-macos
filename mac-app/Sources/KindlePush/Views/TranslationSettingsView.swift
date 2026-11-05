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
    @State private var workers = 16
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
    @State private var savedKey: String?
    @State private var editingKey = false
    @State private var revealKey = false
    @State private var keyCheck = KeyCheck.idle
    @State private var choosingService = false
    @State private var savedService = ""
    @State private var savedModel = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var verifyTask: Task<Void, Never>?

    private enum KeyCheck: Equatable { case idle, checking, ok, failed(String) }

    private let styles: [(id: String, name: String, note: String)] = [
        ("natural", t("自然流畅"), t("读起来像中文原创。适合大多数书。")),
        ("faithful", t("忠实准确"), t("贴着原文译，不增不减。适合历史、传记等非虚构。")),
        ("literary", t("文学润色"), t("更有文采，留住人物的语气。适合小说、散文。")),
        ("technical", t("技术学术"), t("术语准确统一，代码和公式不动。适合技术书、论文。")),
    ]

    /// Everything saves itself; this line only says that it did, or why it could not.
    @ViewBuilder private var statusBar: some View {
        if saved || !message.isEmpty {
            HStack(spacing: 8) {
                if saved && message.isEmpty {
                    Label(t("已保存"), systemImage: "checkmark").foregroundStyle(.green).transition(.opacity)
                } else {
                    Text(t(message)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
            }
            .font(.callout).padding(.horizontal, 20).padding(.bottom, 14)
        }
    }

    var body: some View {
        TabView(selection: $store.settingsTab) {
            languageForm.tabItem { Label(t("语言"), systemImage: "character.book.closed") }.tag(SettingsTab.language)
            serviceForm.tabItem { Label(t("翻译服务"), systemImage: "network") }.tag(SettingsTab.service)
            qualityForm.tabItem { Label(t("质量与速度"), systemImage: "wand.and.stars") }.tag(SettingsTab.quality)
            StorageView(store: store).tabItem { Label(t("存储"), systemImage: "internaldrive") }.tag(SettingsTab.storage)
            AboutView().tabItem { Label(t("关于"), systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .safeAreaInset(edge: .bottom) {
            if store.settingsTab == .service || store.settingsTab == .quality { statusBar }
        }
        // The gear opens translation settings next time, not the About tab the menu left open.
        .onDisappear { if store.settingsTab == .about || store.settingsTab == .storage { store.settingsTab = .service } }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let response = await Bridge.call(["translation-settings"])
            base = response.base ?? ""; model = response.model ?? ""
            savedBase = base; savedHasKey = response.hasKey ?? false
            serviceID = ProviderCatalog.match(provider: response.provider ?? "", base: base).id
            savedService = serviceID; savedModel = model
            workers = response.workers ?? 16; style = response.style ?? "natural"; glossary = response.glossary ?? ""
            ready = response.runtimeReady ?? false
            if !response.ok { message = response.message ?? t("无法读取配置。") }
            refreshKey()
            await loadModels()
            loaded = true
        }
        .sheet(isPresented: $choosingService) { ServicePicker(current: serviceID) { pick($0) } }
        .onChange(of: model) { autosave() }
        .onChange(of: style) { autosave() }
        .onChange(of: workers) { autosave() }
        .onChange(of: glossary) { autosave(after: 0.8) }
        .onChange(of: base) { if service.group == .custom || service.group == .local { refreshKey() } }
        .onChange(of: key) { verifySoon() }
    }

    @AppStorage("interfaceLanguage") private var interfaceLanguage = ""

    /// Takes effect at once, like the rest of the main window; the service settings have their own Save.
    private var languageForm: some View {
        Form {
            Section {
                Picker(t("偏好翻译语言"), selection: $store.targetLanguage) {
                    ForEach(Lang.targets, id: \.code) { target in
                        Text(target.picker).tag(target.code)
                    }
                }
                Picker(t("外文书默认"), selection: $store.foreignDefault) {
                    ForEach(ForeignDefault.allCases, id: \.self) { Text($0.title(into: store.targetLanguage)).tag($0) }
                }
            } footer: {
                Text(languageNote)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker(t("界面语言"), selection: $interfaceLanguage) {
                    Text(t("跟随系统")).tag("")
                    Text(verbatim: "简体中文").tag("zh")
                    Text(verbatim: "English").tag("en")
                }
            } footer: {
                Text(t("重新打开应用后生效。")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var languageNote: String {
        let name = Lang.name(store.targetLanguage)
        let rule = t("拖进来的书会自动识别语言。")
        let choice = store.foreignDefault == .ask
            ? t("不是\(name)的书，会在列表上方问你要不要翻译。")
            : t("不是\(name)的书，拖进来就标为「\(store.foreignDefault.title(into: store.targetLanguage))」。")
        let tag = t("每本书行尾的标签可以单独改。")
        return [rule, choice, tag].filter { !$0.isEmpty }.joined(separator: I18n.sentenceGap)
    }

    private var qualityForm: some View {
        Form {
            Section {
                Picker(t("译文风格"), selection: $style) {
                    ForEach(styles, id: \.id) { Text(t($0.name)).tag($0.id) }
                }
            } header: {
                Text(t("质量"))
            } footer: {
                Text(t(styles.first { $0.id == style }?.note ?? "") + I18n.sentenceGap + t("换了风格，书会从头再译一遍。"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                TextEditor(text: $glossary)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 96).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if glossary.isEmpty {
                            Text(t("Hari Seldon -> 哈里·谢顿\nPsychohistory -> 心理史学\n# 以 # 开头的行是备注"))
                                .font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text(t("术语表"))
            } footer: {
                Text(t("每行一条：原文 -> 译名。整本书都按这里的译名翻。"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(t("同时翻译")) {
                    HStack(spacing: 6) {
                        TextField("", value: serviceID == "chatgpt" ? .constant(1) : $workers, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 52).monospacedDigit()
                            .disabled(serviceID == "chatgpt")
                        Stepper("", value: serviceID == "chatgpt" ? .constant(1) : $workers, in: 1...64)
                            .labelsHidden().disabled(serviceID == "chatgpt")
                        Text(t("路")).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: workers) { _, value in if value < 1 || value > 64 { workers = min(64, max(1, value)) } }
            } header: {
                Text(t("速度"))
            } footer: {
                Text(serviceID == "chatgpt" ? t("用 ChatGPT 账号时，一次只能翻一章。") : t("一次同时翻几段。越大越快，费用不变。经常报错或被限流，就调小一点。默认 16。"))
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
                HStack(spacing: 12) {
                    ProviderTile(service: service, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t(service.name)).font(.body.weight(.medium))
                        Text(t(service.hostLabel.isEmpty ? service.note : service.hostLabel)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t("更换服务…")) { choosingService = true }
                }
                .padding(.vertical, 2)
                if service.signIn == .chatgpt {
                    chatgptRows
                } else {
                    if service.group == .custom || service.group == .local {
                        TextField(t("服务地址"), text: $base, prompt: Text("https://example.com/v1"))
                            .textContentType(.URL)
                            .onSubmit { Task { await loadModels() } }
                    }
                    if service.needsKey || service.group == .custom { keyRows }
                }
            } header: {
                Text(t("翻译服务"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if pendingSwitch {
                        Text(t("现在还在用\(gapped(savedServiceName))。这个 Key 能用后，才换成\(gapped(t(service.name), before: true))。"))
                            .foregroundStyle(.orange)
                    }
                    Text(serviceNote).foregroundStyle(.secondary)
                }
                .font(.caption).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if !manualModel && !modelChoices.isEmpty {
                    HStack {
                        Picker(t("模型"), selection: $model) {
                            let recommended = modelChoices.filter(isRecommended)
                            if !recommended.isEmpty {
                                Section(t("推荐")) { ForEach(recommended) { Text($0.name).tag($0.id) } }
                            }
                            Section(recommended.isEmpty ? "" : t("全部")) {
                                ForEach(modelChoices.filter { !isRecommended($0) }) { Text(t($0.name)).tag($0.id) }
                            }
                        }
                        Button { Task { await loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help(t("重新读取模型列表")).disabled(loadingModels)
                    }
                } else {
                    TextField(t("模型"), text: $model, prompt: Text(service.popular.first ?? t("模型 ID")))
                }
                HStack(spacing: 8) {
                    if loadingModels {
                        ProgressView().controlSize(.small)
                        Text(t("正在读取模型列表…")).foregroundStyle(.secondary)
                    } else if !modelNote.isEmpty {
                        Text(modelNote).foregroundStyle(modelNoteIsError ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !modelChoices.isEmpty {
                        Button(manualModel ? t("从列表选择") : t("手动填写")) { manualModel.toggle() }.buttonStyle(.inkLink)
                    }
                }
                .font(.caption)
            } header: {
                Text(t("模型"))
            }
            Section {
                LabeledContent {
                    if ready {
                        Label(t("已就绪"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if working && message.hasPrefix("正在下载") {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(t("安装")) { Task { await install() } }.disabled(working)
                    }
                } label: {
                    Text(t("翻译组件"))
                    Text(t("第一次安装要几分钟")).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A saved key shows as sk-…a3f9 with whether it works; a new one is pasted into a full-width
    /// field, checked against the service as it arrives, and saved the moment it works.
    @ViewBuilder private var keyRows: some View {
        if let savedKey, !editingKey {
            LabeledContent("API Key") {
                HStack(spacing: 10) {
                    Text(KeyVault.mask(savedKey)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    keyBadge
                    Button(t("更换")) { key = ""; keyCheck = .idle; editingKey = true }
                    Button(t("移除")) {
                        KeyVault.remove(trimmedBase); refreshKey(); models = []; keyCheck = .idle
                    }
                    .help(t("从钥匙串删除这个服务的 Key"))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                HStack(spacing: 6) {
                    Group {
                        if revealKey {
                            TextField("", text: $key, prompt: Text(t("粘贴\(gapped(t(service.name)))的 API Key")))
                        } else {
                            SecureField("", text: $key, prompt: Text(t("粘贴\(gapped(t(service.name)))的 API Key")))
                        }
                    }
                    .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .onSubmit { verifySoon(after: 0) }
                    Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(revealKey ? t("隐藏") : t("显示")).accessibilityLabel(revealKey ? t("隐藏") : t("显示"))
                    if savedKey != nil {
                        Button(t("取消")) { key = ""; editingKey = false; keyCheck = .idle; Task { await loadModels() } }
                    }
                }
                HStack(spacing: 6) {
                    switch keyCheck {
                    case .checking:
                        ProgressView().controlSize(.mini)
                        Text(t("正在验证…")).foregroundStyle(.secondary)
                    case .failed(let reason):
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(t(reason)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button(t("重试")) { verifySoon(after: 0) }.buttonStyle(.inkLink)
                    default:
                        Text(t("粘贴后会自动检查，能用就保存。")).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                if service.keyURL != nil || service.signIn == .key {
                    HStack(spacing: 14) {
                        if let url = service.keyURL.flatMap(URL.init(string:)) {
                            InkLink(url: url) { Label(t("获取 API Key"), systemImage: "arrow.up.right.square") }
                        }
                        if service.signIn == .key {
                            Button { Task { await signInForKey() } } label: {
                                Label(signingIn ? t("正在等待浏览器授权…") : t("登录\(t(service.name))，自动填入 Key"), systemImage: "person.badge.key")
                            }
                            .buttonStyle(.inkLink).disabled(signingIn)
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var keyBadge: some View {
        switch keyCheck {
        case .checking:
            ProgressView().controlSize(.mini)
        case .ok:
            Label(t("可用"), systemImage: "circle.fill").labelStyle(Dot()).foregroundStyle(.green)
        case .failed(let reason):
            Label(t("不可用"), systemImage: "circle.fill").labelStyle(Dot()).foregroundStyle(.orange).help(t(reason))
        case .idle:
            EmptyView()
        }
    }

    private struct Dot: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) { configuration.icon.font(.system(size: 6)); configuration.title.font(.caption) }
        }
    }

    /// A space between Chinese and a Latin name (发给 DeepSeek), none before a Chinese one (发给硅基流动).
    /// `before` only when Chinese punctuation follows: 发给 DeepSeek，not 发给 DeepSeek ，.
    private func gapped(_ name: String, before only: Bool = false) -> String {
        guard !I18n.english, name.first?.isASCII == true else { return name }
        return only ? " \(name)" : " \(name) "
    }

    private var savedServiceName: String { t(ProviderCatalog.service(savedService)?.name ?? savedService) }

    /// Picked a service that cannot run yet: the saved one stays in use until this one works.
    private var pendingSwitch: Bool { loaded && serviceID != savedService && !savedService.isEmpty && !usable }

    /// Whether what is on screen can translate: signed in, local, or a key that is saved.
    private var usable: Bool {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if service.signIn == .chatgpt { return codexLoggedIn }
        guard validBase(trimmedBase) != nil else { return false }
        return !service.needsKey && service.group != .custom || savedKey != nil || service.group == .local
    }

    private func refreshKey() {
        let wantsKey = service.signIn != .chatgpt && (service.needsKey || service.group == .custom)
        savedKey = wantsKey ? KeyVault.read(trimmedBase) : nil
        editingKey = wantsKey && savedKey == nil
        revealKey = false
    }

    private func verifySoon(after delay: Double = 0.7) {
        verifyTask?.cancel()
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { if keyCheck != .ok { keyCheck = .idle }; return }
        guard typed.count >= 8 else { return }
        verifyTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private func autosave(after delay: Double = 0.4) {
        guard loaded else { return }
        saved = false
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func pick(_ id: String) {
        guard id != serviceID else { return }
        serviceID = id
        base = service.base; key = ""; manualModel = false; modelNote = ""; keyCheck = .idle; message = ""
        models = []; model = service.popular.first ?? ""
        refreshKey()
        Task { await loadModels() }
    }

    @ViewBuilder private var chatgptRows: some View {
        if codexInstalled == false {
            LabeledContent(t("Codex 命令行")) { Text(t("还没有安装")).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                Text(t("要先装 OpenAI 的 Codex 工具。打开「终端」，运行这一行："))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(installCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(t("拷贝")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    }
                    Button(t("装好了，重新检测")) { Task { await loadModels() } }
                }
            }
        } else if codexLoggedIn {
            LabeledContent(t("账号")) {
                HStack(spacing: 10) {
                    Text([codexEmail, codexPlan.map { t("\($0.capitalized) 套餐") }].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Button(t("退出登录")) { Task { await codexCall("codex-logout") } }.disabled(signingIn)
                }
            }
        } else {
            LabeledContent {
                Button(signingIn ? t("正在等待浏览器登录…") : t("用 ChatGPT 登录")) { Task { await codexCall("codex-login") } }
                    .buttonStyle(.ink).disabled(signingIn || codexInstalled == nil)
            } label: {
                Text(t("账号"))
                Text(t("会打开浏览器。Plus、Pro、Business 都可以")).font(.caption)
            }
        }
    }

    private let installCommand = "brew install --cask codex"

    private var serviceNote: String {
        switch service.group {
        case .account:
            return t("用你 ChatGPT 套餐的额度，不另外收费，但有用量上限。正文会发给 OpenAI。")
        case .local:
            return t("模型在这台 Mac 上运行，正文不出本机。先在 \(service.name) 里下载并打开模型。")
        default:
            let name = service.name == "自定义服务" ? t("这个服务") : service.name
            return t("翻译时，正文会发给\(gapped(name, before: true))，按用量付费。Key 只存在这台 Mac 上。")
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
        let typed = editingKey ? key.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let wantsKey = service.needsKey || service.group == .custom
        if wantsKey && typed.isEmpty && savedKey == nil {
            models = []; modelNote = t("填好 API Key，会自动列出模型。"); return
        }
        if wantsKey { keyCheck = .checking }
        let response = await Bridge.call(["models", trimmedBase] + (typed.isEmpty ? [] : ["--key-stdin"]),
                                         input: typed.isEmpty ? nil : typed)
        // The field changed while this was in flight: its own check is on the way.
        if !typed.isEmpty && typed != key.trimmingCharacters(in: .whitespacesAndNewlines) { return }
        if response.ok, let list = response.models {
            models = list
            if model.isEmpty || !list.contains(where: { $0.id == model }) && !service.popular.isEmpty && service.popular.first == model {
                model = list.first(where: isRecommended)?.id ?? list.first?.id ?? model
            }
            modelNote = t("共 \(list.count) 个模型")
            if wantsKey { keyCheck = .ok }
            if !typed.isEmpty {
                // It works: keep it, and stop showing it.
                guard KeyVault.write(typed, for: trimmedBase) else {
                    keyCheck = .failed(t("无法保存密钥，请解锁 macOS 钥匙串后重试。")); return
                }
                key = ""; refreshKey(); keyCheck = .ok
            }
            if usable { autosave(after: 0) }
        } else {
            let reason = response.message ?? t("读不到模型列表，可以手动填写。")
            models = []
            if wantsKey {
                // A refused key is about the key, not the models: say so once, next to the field.
                let refused = reason.contains("HTTP 401") || reason.contains("HTTP 403")
                keyCheck = .failed(refused ? t("\(t(service.name)) 不认这个 Key。看看是不是没复制全，或者不是这个服务的 Key。") : reason)
                modelNote = refused ? t("Key 能用后，会自动列出模型。") : reason
                modelNoteIsError = !refused
            } else { modelNote = reason; modelNoteIsError = true }
        }
    }

    private func codexCall(_ command: String) async {
        signingIn = true; defer { signingIn = false }
        let response = await Bridge.call([command])
        if !response.ok { message = response.message ?? t("没有完成。") }
        await loadModels()
        if usable { autosave(after: 0) }
    }

    private func signInForKey() async {
        signingIn = true; defer { signingIn = false }
        let response = await Bridge.call(["sign-in-key", service.id])
        if response.ok, let value = response.key {
            editingKey = true; key = value
            verifySoon(after: 0)
        } else { message = response.message ?? t("授权没有完成。") }
    }

    private func install() async {
        working = true; message = t("正在下载并安装，首次可能需要几分钟…")
        let response = await Bridge.call(["translation-install"])
        ready = response.runtimeReady ?? false
        store.translationReady = ready
        message = ready ? "" : response.message ?? t("安装未完成，请重试。")
        working = false
    }

    private func validBase(_ value: String) -> String? {
        guard let url = URL(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        return value
    }

    /// Saves what is on screen when it can translate; otherwise keeps the service in use and saves the rest.
    private func save() async {
        let draft = usable
        if !draft && savedModel.isEmpty { return }
        let provider = draft ? serviceID : savedService
        let normalized = draft ? (service.signIn == .chatgpt ? "" : trimmedBase) : savedBase
        let chosen = draft ? model.trimmingCharacters(in: .whitespaces) : savedModel
        let fields: [String: Any] = ["base": normalized, "model": chosen,
                                     "workers": String(workers), "style": style, "glossary": glossary, "provider": provider]
        let json = String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        let response = await Bridge.call(["translation-save", json])
        if response.ok {
            message = ""
            savedBase = normalized; savedModel = chosen; savedService = provider; savedHasKey = response.hasKey ?? false
            store.translationProvider = provider
            withAnimation { saved = true }
        } else { message = response.message ?? t("设置保存失败。") }
    }
}
