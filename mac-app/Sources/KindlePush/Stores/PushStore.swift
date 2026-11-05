import SwiftUI
import AppKit

@MainActor
final class PushStore: ObservableObject {
    @Published var articles: [Article] = []
    @Published var host = ""
    @Published var manualHost = ""
    @Published var connected = false
    /// The Kindle books go to, and every paired one.
    @Published var deviceName = ""
    @Published var deviceId = ""
    @Published var devices: [KindleDevice] = []
    @Published var checkingDevices = false
    @Published var showAddKindle = false
    /// The add-Kindle sheet is upgrading this paired Kindle's receiver, not pairing a new one.
    @Published var upgrading: KindleDevice?
    @Published var showHistory = false
    /// Books delivered to a Kindle, newest first.
    @Published var history: [SendRecord] = []
    /// Translation and everything else run in separate queues, so a translation that takes hours
    /// never holds up sending, saving or tidying the other books.
    @Published var translation = Lane() { didSet { holdOffSleep() } }
    @Published var quick = Lane() { didSet { holdOffSleep() } }
    /// Kept while either queue runs, so an idle Mac does not sleep through a transfer. The translation
    /// worker holds its own (see translation.py), which also covers the window being closed.
    private var awake: NSObjectProtocol?
    private func holdOffSleep() {
        if busy, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "正在翻译或发送书")
        } else if !busy, let token = awake {
            ProcessInfo.processInfo.endActivity(token); awake = nil
        }
    }
    /// What the last removal took out and where it was, while it can still be undone.
    @Published var undoable: [(offset: Int, article: Article)] = []
    var busy: Bool { translation.running || quick.running }
    @Published var activity = "正在检查连接…"
    @Published var notice = ""
    @Published var isError = false
    @Published var showPicker = false
    @Published var showConnection = false
    /// Books shown in the rename sheet; empty when it is closed.
    @Published var renameIDs: [UUID] = []
    @Published var searching = false
    @Published var connectionIssue = ""
    @Published var setupNeeded = false
    @Published var translationReady: Bool?
    @Published var translationProvider = ""
    /// What foreign books are translated into. Books already in this language get no translation UI.
    @Published var targetLanguage: String = UserDefaults.standard.string(forKey: "targetLanguage") ?? "zh" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage"); applyDefault(); save() }
    }
    /// What a foreign book gets when it is added; `.ask` shows the prompt above the list.
    @Published var foreignDefault: ForeignDefault = ForeignDefault.saved {
        didSet { UserDefaults.standard.set(foreignDefault.rawValue, forKey: "foreignDefault"); applyDefault(); save() }
    }
    @Published var translationWorkers = 16
    /// Books a queue has taken and not finished: translated and waiting to be sent counts too.
    @Published var active: Set<UUID> = []
    @Published var currentJob: String?
    @Published var settingsTab: SettingsTab = .service
    private var stopRequested = false
    /// Sending: stop after the book in flight, or (`cancelNow`) drop it too.
    @Published var sendStopRequested = false
    private var cancelNow = false
    private var started = false
    /// Kindles found away during a batch, until when not to search for them again.
    private var awayUntil: [String: Date] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "history"),
           let saved = try? JSONDecoder().decode([SendRecord].self, from: data) { history = saved }
        if let data = UserDefaults.standard.data(forKey: "articles"),
           let saved = try? JSONDecoder().decode([Article].self, from: data) {
            articles = saved.map { item in
                var item = item
                if ["发送中", "翻译中", "试译中"].contains(item.status) { item.status = "等待继续" }
                if item.status == "排队中" { item.status = "等待发送" }
                // Translated in 1.13, when the footer chose the version for every book.
                if item.bilingual == true && item.choice == nil {
                    item.choice = item.chineseOnly == true ? .targetOnly : .bilingual
                    item.translatedTo = item.translatedTo ?? "zh"
                }
                return item
            }
        }
        // 1.14 moved the footer's version into the default for foreign books; write it down once.
        UserDefaults.standard.set(foreignDefault.rawValue, forKey: "foreignDefault")
        updateBadge()
        Task { await loadBookInfo() }
    }

    /// Titles, authors, covers and languages for items that do not have them yet.
    func loadBookInfo() async {
        // canTranslate is new in 1.15: books already in the list are read once more for it.
        for article in articles where article.bookTitle == nil || article.canTranslate == nil {
            let response = await Bridge.call(["book-info", article.path])
            guard let index = articles.firstIndex(where: { $0.id == article.id }) else { continue }
            if response.ok {
                articles[index].bookTitle = response.title ?? ""
                articles[index].author = response.author
                articles[index].cover = response.cover
                articles[index].language = response.language ?? ""
                articles[index].textSize = response.textSize
                articles[index].canTranslate = response.translatable ?? false
            } else { articles[index].bookTitle = ""; articles[index].language = ""; articles[index].canTranslate = false }
            if articles[index].format == "PDF", articles[index].cover == nil {
                articles[index].cover = await Covers.pdf(articles[index].path)
            }
        }
        applyDefault()
        save()
    }

    // MARK: Translation per book

    /// A book whose text this app can read, with its language checked: any of these can be translated into any language.
    func translatable(_ article: Article) -> Bool {
        (article.canTranslate ?? (article.format == "EPUB")) && article.language != nil
    }
    /// The language this book goes into: its own choice, else the preference from settings.
    func goal(of article: Article) -> String { article.target ?? targetLanguage }
    /// A book in another language than the preference, not yet decided: what the prompt asks about.
    func isForeign(_ article: Article) -> Bool {
        guard translatable(article), let language = article.language, !language.isEmpty else { return false }
        return language != targetLanguage
    }
    /// What sending does with this book now. A book is never "translated" into its own language.
    func mode(of article: Article) -> OutputMode {
        guard translatable(article), article.language != goal(of: article) else { return .original }
        return article.choice ?? .original
    }
    /// The words for a mode on this book: 中英对照, 英日对照, 仅中文…
    func title(_ mode: OutputMode, for article: Article) -> String {
        mode.title(from: article.language ?? "", to: goal(of: article))
    }
    /// Foreign books waiting for a decision: what the prompt above the list asks about.
    var undecided: [Article] {
        articles.filter { isForeign($0) && $0.choice == nil && $0.target == nil && $0.status != "已发送"
            && $0.status != "排队中" && $0.phase != .working && !active.contains($0.id) }
    }
    func choose(_ mode: OutputMode, for ids: Set<UUID>) {
        for index in articles.indices where ids.contains(articles[index].id) {
            // Another version of the book: Kindles that got the old one have not got this one.
            if articles[index].choice != mode { articles[index].deliveredTo = nil }
            articles[index].choice = mode
        }
        save()
    }
    /// Translate these books into `code`; a book that was going as it is becomes bilingual.
    func translate(_ ids: Set<UUID>, into code: String) {
        for index in articles.indices where ids.contains(articles[index].id) {
            articles[index].target = code == targetLanguage ? nil : code
            articles[index].deliveredTo = nil
            if articles[index].choice == nil || articles[index].choice == .original { articles[index].choice = .bilingual }
        }
        remember(code); save()
    }
    /// The last languages picked, newest first: shown first in the menu, after the preference.
    @Published private(set) var recentTargets: [String] = UserDefaults.standard.stringArray(forKey: "recentTargets") ?? []
    private func remember(_ code: String) {
        recentTargets = Array(([code] + recentTargets.filter { $0 != code }).prefix(3))
        UserDefaults.standard.set(recentTargets, forKey: "recentTargets")
    }
    /// With a default chosen in settings, foreign books are marked as they arrive and nothing asks.
    private func applyDefault() {
        guard let mode = foreignDefault.mode else { return }
        for index in articles.indices where articles[index].choice == nil && isForeign(articles[index]) {
            articles[index].choice = mode
        }
    }
    /// Books the buttons would start now, split by what happens to them.
    var plannedOriginals: [Article] { queueable.filter { mode(of: $0) == .original } }
    var plannedTranslations: [Article] { queueable.filter { mode(of: $0) != .original } }
    /// The buttons say what will happen: 翻译并保存 when any book will be translated first.
    var saveTitle: String { plannedTranslations.isEmpty ? t("保存到本机") : t("翻译并保存") }
    var sendTitle: String {
        if !plannedTranslations.isEmpty { return t("翻译并发送") }
        return targets.count > 1 ? t("发送到 \(targets.count) 台 Kindle") : t("发送到 Kindle")
    }
    /// A rough time for the translations about to start: they run one book after another.
    var translationMinutes: Int? {
        let books = plannedTranslations
        guard !books.isEmpty, books.allSatisfy({ $0.textSize != nil }) else { return nil }
        let bytes = books.reduce(0) { $0 + ($1.textSize ?? 0) }
        let workers = translationProvider == "chatgpt" ? 1 : max(1, translationWorkers)
        // About 5 KB of XHTML per worker and minute, from runs on DeepSeek; a guess, shown as one.
        return max(1, Int((Double(bytes) / Double(5000 * workers)).rounded()))
    }

    /// About 0.6 tokens per byte of XHTML in and out together, from real whole-book runs; the same kind of guess.
    var translationTokens: Int? {
        let books = plannedTranslations
        guard !books.isEmpty, books.allSatisfy({ $0.textSize != nil }) else { return nil }
        return Int(Double(books.reduce(0) { $0 + ($1.textSize ?? 0) }) * 0.6)
    }

    var pendingCount: Int { articles.filter { $0.status != "已发送" }.count }
    /// How far each queue has got; translation counts the book being translated right now.
    var translationProgress: Double {
        let current = articles.first { $0.status == "翻译中" }?.progress ?? 0
        return min(1, (Double(translation.completed) + current) / Double(max(translation.total, 1)))
    }
    var quickProgress: Double {
        let current = articles.first { $0.id == quick.sending }?.progress ?? 0
        return min(1, (Double(quick.completed) + current) / Double(max(quick.total, 1)))
    }
    /// Books the main buttons would start now: not sent, not already queued or running.
    var queueable: [Article] {
        articles.filter { $0.status != "已发送" && $0.status != "排队中" && $0.phase != .working && !active.contains($0.id) }
    }
    var sentCount: Int { articles.count - pendingCount }
    /// Why the send and save buttons are disabled, in words; nil when they are not.
    var nothingToSendReason: String? {
        guard queueable.isEmpty, !busy, !articles.isEmpty else { return nil }
        if pendingCount == 0 { return "都已送达。拖入新的书，或右键一本书「放回待发送」再发一次" }
        return "没有可发送的书"
    }
    /// The Kindles a book goes to when several are ticked; empty means just the connected one.
    var targets: [KindleDevice] {
        let ticked = devices.filter { $0.selected == true }
        return ticked.count > 1 ? ticked : []
    }
    var connectionTitle: String {
        if searching { return "正在寻找…" }
        if !targets.isEmpty { return "\(targets.count) 台 Kindle" }
        if connected { return deviceName.isEmpty ? "我的 Kindle" : deviceName }
        return setupNeeded ? "需要首次配置" : "未连接 Kindle"
    }

    func save() {
        if let data = try? JSONEncoder().encode(articles) { UserDefaults.standard.set(data, forKey: "articles") }
        updateBadge()
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = pendingCount > 0 ? "\(pendingCount)" : nil
    }

    func dismissNotice() { notice = ""; isError = false; undoable = [] }

    private func announce(_ message: String, error: Bool) {
        notice = message; isError = error; undoable = []
        guard !error else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if notice == message { dismissNotice() }
        }
    }

    /// Always allowed: a long translation must not lock the list. New items join the next batch.
    func add(_ urls: [URL]) {
        var rejected = 0
        for url in urls {
            guard url.isFileURL, Article.isSupported(url) else {
                rejected += 1; continue
            }
            let path = url.standardizedFileURL.path
            if let index = articles.firstIndex(where: { $0.path == path }) {
                // Leave a queued or running book alone; otherwise adding again means "send again".
                guard articles[index].status != "排队中", articles[index].phase != .working else { continue }
                articles[index].status = "等待发送"; articles[index].bookTitle = nil
                articles[index].details = ""; articles[index].deliveredTo = nil
                articles[index].output = nil; articles[index].bilingual = false
                articles[index].choice = nil; articles[index].language = nil; articles[index].target = nil
            } else { articles.append(Article(path: path)) }
        }
        Task { await loadBookInfo() }
        if rejected > 0 { notice = "有 \(rejected) 个文件不支持，已跳过。支持 KOReader 能打开的电子书、漫画、文档和 Markdown。"; isError = true }
        else if isError { dismissNotice() }
        save()
    }

    func remove(_ id: UUID) { remove([id]) }
    /// The book being worked on stays; anything else can go, even mid-batch (the batch skips missing items).
    func remove(_ ids: Set<UUID>) {
        take { ids.contains($0.id) && !(busy && $0.phase == .working) }
    }
    /// Removing is one key away and has no dialog, so it can always be taken back for a moment.
    private func take(where chosen: (Article) -> Bool) {
        let gone = articles.enumerated().filter { chosen($0.element) }.map { (offset: $0.offset, article: $0.element) }
        guard !gone.isEmpty else { return }
        articles.removeAll(where: chosen); save()
        let label = gone.count == 1 ? "已移除《\(gone[0].article.title)》" : "已移除 \(gone.count) 本"
        announce(label, error: false)
        undoable = gone
    }
    func undoRemove() {
        for item in undoable.sorted(by: { $0.offset < $1.offset }) where !articles.contains(where: { $0.id == item.article.id }) {
            articles.insert(item.article, at: min(item.offset, articles.count))
        }
        dismissNotice(); save()
    }
    /// Shows the file the app made (translation or converted copy) when it still exists, else the original.
    func reveal(_ ids: Set<UUID>) {
        let urls = articles.filter { ids.contains($0.id) }.map(\.preferredURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { revealMissing() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func revealOriginal(_ ids: Set<UUID>) {
        let urls = articles.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { revealMissing() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    /// Opens with the default app: the same file `reveal` would show.
    func open(_ ids: Set<UUID>) {
        let urls = articles.filter { ids.contains($0.id) }.map(\.preferredURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { revealMissing() } else { urls.forEach { NSWorkspace.shared.open($0) } }
    }
    private func revealMissing() {
        notice = "找不到这个文件，可能已被移动或删除。重新拖入即可。"; isError = true
    }
    /// Opens the rename sheet for these books, or for every book when none are chosen.
    func tidyNames(_ ids: Set<UUID> = []) {
        // Books only: notes keep their names, or links to them (Obsidian, Markdown) would break.
        let chosen = articles.filter { (ids.isEmpty || ids.contains($0.id)) && $0.isBook }
        renameIDs = chosen.filter { !(busy && $0.phase == .working) }.map(\.id)
        if renameIDs.isEmpty { announce("没有可整理的电子书文件名。笔记和文档保留原名。", error: false) }
    }

    /// Renames the original files. A taken name gets " 2"; the book being worked on is left alone.
    /// Returns the names that could not be changed.
    func rename(_ changes: [UUID: String]) -> [String] {
        var failed: [String] = []
        for (id, name) in changes {
            guard let index = articles.firstIndex(where: { $0.id == id }),
                  !(busy && articles[index].phase == .working) else { continue }
            let old = URL(fileURLWithPath: articles[index].path)
            let folder = old.deletingLastPathComponent()
            let suffix = Article.fileExtension(of: old.path)
            let stem = name.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " - ")
                .trimmingCharacters(in: .whitespaces)
            guard !stem.isEmpty, stem + "." + suffix != old.lastPathComponent else { continue }
            var target = folder.appendingPathComponent(stem + "." + suffix)
            var number = 2
            // Only a case change of the same file may reuse its own name.
            while FileManager.default.fileExists(atPath: target.path),
                  target.path.lowercased() != old.path.lowercased() {
                target = folder.appendingPathComponent("\(stem) \(number).\(suffix)"); number += 1
            }
            do {
                try FileManager.default.moveItem(at: old, to: target)
                // Reread the title: without metadata it came from the old file name.
                articles[index].path = target.standardizedFileURL.path; articles[index].bookTitle = nil
            } catch { failed.append(old.lastPathComponent) }
        }
        save()
        Task { await loadBookInfo() }
        return failed
    }

    func clearSent() { take { $0.status == "已发送" } }

    // MARK: Send history

    private static let historyLimit = 500

    private func record(_ article: Article, sentAs: String?, device: String?) {
        let entry = SendRecord(path: article.path, title: article.title, author: article.author, cover: article.cover,
                               device: device ?? (deviceName.isEmpty ? "Kindle" : deviceName),
                               sentAs: sentAs.map { URL(fileURLWithPath: $0).lastPathComponent },
                               translated: article.bilingual == true)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "history") }
    }

    /// Puts a book from the history back in the list, ready to send.
    func resend(_ entries: [SendRecord]) {
        let urls = entries.filter(\.exists).map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { announce("原文件已经不在了，无法再发。", error: true); return }
        add(urls)
        announce(urls.count == 1 ? "已放回待发送，点「发送到 Kindle」即可。" : "\(urls.count) 本已放回待发送，点「发送到 Kindle」即可。", error: false)
    }

    func revealHistory(_ entry: SendRecord) {
        guard entry.exists else { announce("原文件已经不在了。", error: true); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    func forgetHistory(_ ids: Set<UUID>) { history.removeAll { ids.contains($0.id) }; saveHistory() }
    func clearHistory() { history = []; saveHistory() }

    /// Books delivered before history existed: listed once, so they are not lost on the first clear.
    func seedHistoryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "historySeeded") else { return }
        UserDefaults.standard.set(true, forKey: "historySeeded")
        guard history.isEmpty else { return }
        history = articles.filter { $0.status == "已发送" }.map {
            SendRecord(path: $0.path, title: $0.title, author: $0.author, cover: $0.cover,
                       device: "",
                       sentAs: $0.output.map { URL(fileURLWithPath: $0).lastPathComponent },
                       translated: $0.bilingual == true, earlier: true)
        }
        saveHistory()
    }
    func retry(_ id: UUID) {
        guard let index = articles.firstIndex(where: { $0.id == id }),
              articles[index].status != "排队中", articles[index].phase != .working else { return }
        // Fully delivered and put back: send it again everywhere. Partly delivered: only to the rest.
        if articles[index].status == "已发送" { articles[index].deliveredTo = nil }
        articles[index].status = "等待发送"; articles[index].details = ""; save()
    }

    func start() async {
        guard !started else { return }; started = true
        seedHistoryIfNeeded()
        await refreshTranslationStatus()
        Task { await resumeTranslations() }
        let status = await Bridge.call(["status"])
        if status.ok {
            host = status.host ?? ""; manualHost = host
            deviceName = status.device ?? ""; deviceId = status.deviceId ?? ""
            await findConnection(manual: false, report: false)
            await refreshDevices()
        } else {
            setupNeeded = true
            connectionIssue = status.message ?? "还没完成首次配置。"
            activity = "需要首次配置"
        }
    }

    /// Translations that kept running, or finished, while the app was closed: show them again.
    private func resumeTranslations() async {
        for article in articles where (article.canTranslate ?? (article.format == "EPUB")) && ["等待继续", "翻译中"].contains(article.status) {
            let goal = article.translatedTo ?? self.goal(of: article)
            let found = await Bridge.call(["translation-find", article.path, goal])
            guard found.ok, let index = articles.firstIndex(where: { $0.id == article.id }) else { continue }
            switch found.state {
            case "queued", "running":
                guard !translation.running else { continue }
                translation.reset(total: 1); stopRequested = false
                articles[index].status = "翻译中"
                let mode = OutputMode(legacy: found.mode ?? "") ?? .bilingual
                articles[index].chineseOnly = mode == .targetOnly; articles[index].translatedTo = goal
                translation.activity = "正在翻译：\(article.title)"
                let output = await follow(article.id, from: found, preview: false, mode: mode, target: goal)
                if output != nil { translationFinished(article.id) }
                else if !stopRequested, let failed = articles.first(where: { $0.id == article.id }) {
                    notice = failed.details; isError = true
                    Notify.post("翻译没有完成", "《\(failed.title)》：\(failed.details)")
                }
                translation.running = false
                // Books queued while this one was being picked up.
                await runQueuedTranslations()
            case "done":
                articles[index].output = found.output; articles[index].bilingual = true
                articles[index].chineseOnly = found.mode != "bilingual"; articles[index].translatedTo = goal
                articles[index].status = "翻译完成"
                translationFinished(article.id)
            default:
                break
            }
        }
    }

    private func translationFinished(_ id: UUID) {
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        articles[index].details = "译本已生成 · 点「发送到 Kindle」送到 Kindle"
        save()
        announce("《\(articles[index].title)》翻译完成。点「发送到 Kindle」会直接用这份译本。", error: false)
        Notify.post("翻译完成", "《\(articles[index].title)》的译本已生成。")
    }

    func refreshTranslationStatus() async {
        let response = await Bridge.call(["translation-settings"])
        translationReady = response.runtimeReady ?? false
        translationProvider = response.provider ?? ""
        translationWorkers = response.workers ?? 16
    }

    func connect(manual: Bool = false) async {
        guard !searching else { return }
        await findConnection(manual: manual)
        if connected && isError { dismissNotice() }
    }

    /// `report`: show the search in the footer. Off for the background search at launch,
    /// which must not overwrite a translation's status there.
    private func findConnection(manual: Bool, report: Bool = true) async {
        connected = false; searching = true
        defer { searching = false }
        if report { activity = manual ? "正在连接 Kindle…" : "正在寻找你的 Kindle…" }
        let response = await Bridge.call(manual ? ["connect", manualHost.trimmingCharacters(in: .whitespacesAndNewlines)] : ["discover"])
        apply(response, report: report)
    }

    private func apply(_ response: BridgeResponse, report: Bool) {
        if response.ok {
            host = response.host ?? ""; manualHost = host; connected = true
            deviceName = response.device ?? deviceName; deviceId = response.deviceId ?? deviceId
            setupNeeded = false; connectionIssue = ""
            if report { activity = "\(deviceName.isEmpty ? "Kindle" : deviceName) 已连接" }
            if let message = response.message, message.contains("已改为发到") { announce(message, error: false) }
        } else {
            connectionIssue = response.message ?? "没有找到 Kindle，请重试。"
            if report { activity = "Kindle 尚未连接" }
        }
    }

    /// Paired Kindles for the connection popover. `scan` searches the whole network, which finds
    /// a Kindle whose address changed; otherwise only each one's last address is checked.
    func refreshDevices(scan: Bool = false) async {
        guard !setupNeeded, !checkingDevices else { return }
        checkingDevices = true
        defer { checkingDevices = false }
        let response = await Bridge.call(scan ? ["devices", "scan"] : ["devices"])
        guard response.ok else { return }
        devices = response.devices ?? []
        // A chosen Kindle came online after the last search: connect without another click.
        if !connected, !searching, devices.contains(where: { $0.selected == true && $0.online == true }) {
            checkingDevices = false
            await connect()
        }
    }

    /// Tick or untick a Kindle. At least one stays ticked. Books already queued keep the Kindles
    /// they were queued for, so this is safe while a queue runs.
    func toggle(_ device: KindleDevice) async {
        guard !searching, let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let ticked = devices[index].selected == true
        if ticked && devices.filter({ $0.selected == true }).count == 1 { return }
        devices[index].selected = !ticked
        let ids = devices.filter { $0.selected == true }.map(\.id)
        let response = await Bridge.call(["targets"] + ids)
        guard response.ok else { notice = response.message ?? "没有改成。"; isError = true; await refreshDevices(); return }
        devices = response.devices ?? devices
        if let current = devices.first(where: \.current) { deviceName = current.name; deviceId = current.id }
        // The connection status follows what is ticked now.
        if !busy { await connect() }
    }

    var outdatedKindles: [KindleDevice] { devices.filter { $0.outdated == true } }

    func startUpgrade(_ device: KindleDevice) {
        upgrading = device; showConnection = false; showAddKindle = true
    }

    // MARK: Adding a Kindle

    /// A Kindle on the cable that has not mounted yet: it is still in KOReader.
    @Published var kindlePlugged = false

    func usbVolumes() async -> [KindleVolume] {
        let response = await Bridge.call(["usb-volumes"])
        kindlePlugged = response.plugged ?? false
        return response.volumes ?? []
    }

    /// Writes the receiver to the Kindle mounted at `path`. Returns an error message, or nil.
    func usbInstall(_ path: String) async -> String? {
        let response = await Bridge.call(["usb-install", path])
        return response.ok ? nil : (response.message ?? "没有写入。")
    }

    func findNewKindles(at host: String? = nil) async -> (found: [NewKindle], error: String?) {
        let response = await Bridge.call(["find-new"] + (host.map { [$0] } ?? []))
        return (response.candidates ?? [], response.ok ? nil : response.message)
    }

    /// Pairs a Kindle found on the network and sends to it from now on. Returns an error message, or nil.
    func pair(_ kindle: NewKindle, name: String) async -> String? {
        let response = await Bridge.call(["pair", kindle.host, kindle.key, name])
        guard response.ok else { return response.message ?? "没有配对。" }
        setupNeeded = false
        apply(response, report: true)
        await refreshDevices()
        return nil
    }

    func rename(_ device: KindleDevice, to name: String) async {
        let response = await Bridge.call(["rename", device.id, name])
        guard response.ok else { announce(response.message ?? "没有改名。", error: true); return }
        devices = response.devices ?? devices
        if device.id == deviceId { deviceName = devices.first { $0.id == device.id }?.name ?? deviceName }
    }

    func forget(_ device: KindleDevice) async {
        let response = await Bridge.call(["forget", device.id])
        guard response.ok else { announce(response.message ?? "没有取消配对。", error: true); return }
        devices = response.devices ?? []
        guard device.id == deviceId else { return }
        connected = false; deviceName = ""; deviceId = ""; host = ""
        if devices.isEmpty {
            setupNeeded = true; connectionIssue = "还没有配对的 Kindle。"
        } else {
            await connect()
        }
    }

    /// Run one book again now, for what it was run for last time. What was already translated
    /// is kept by the engine's checkpoint and is not paid for twice.
    func retryNow(_ id: UUID) async {
        guard let article = articles.first(where: { $0.id == id }) else { return }
        retry(id)
        await enqueue(deliver: article.wantsKindle ?? !setupNeeded, only: [id])
    }

    /// Asked first by the confirmation in ContentView: this costs model usage again.
    @Published var confirmRetranslate: UUID?

    /// Throw away this book's translation and checkpoint, and translate it from the beginning.
    func retranslate(_ id: UUID) async {
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        let article = articles[index]
        var chosen = mode(of: article)
        if chosen == .original { chosen = article.chineseOnly == true ? .targetOnly : .bilingual }
        let goal = article.translatedTo ?? self.goal(of: article)
        let response = await Bridge.call(["translation-reset", article.path, chosen == .targetOnly ? "target-only" : "bilingual", goal])
        guard response.ok else { notice = response.message ?? "没能重新翻译。"; isError = true; return }
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        articles[index].choice = chosen
        articles[index].status = "等待发送"; articles[index].details = ""
        articles[index].output = nil; articles[index].bilingual = false; articles[index].deliveredTo = nil
        save()
        await enqueue(deliver: article.wantsKindle ?? !setupNeeded, only: [id])
    }

    func send() async { await enqueue(deliver: true) }
    /// Convert or translate without a Kindle: the result stays on this Mac.
    func saveLocally() async { await enqueue(deliver: false) }

    /// Queues every ready book as it is marked: originals go straight out, translations go to their
    /// own queue and are sent when done. Pressing again while a queue runs adds to it instead of waiting.
    private func enqueue(deliver: Bool, only: Set<UUID>? = nil) async {
        var pool: [Article] { queueable.filter { only?.contains($0.id) ?? true } }
        guard !pool.isEmpty else { return }
        // Undecided books go as they are; the prompt was there to change that.
        var skipped = 0
        if translationReady == false {
            skipped = pool.filter { mode(of: $0) != .original }.count
            if skipped > 0 && pool.allSatisfy({ mode(of: $0) != .original }) {
                notice = "还没安装翻译组件。请先在翻译设置里安装，或把这些书改成「原文」。"; isError = true
                return
            }
        }
        if deliver {
            // A fresh press tries every Kindle again, including one that was away earlier.
            awayUntil = [:]
            // Revalidate every time; recover automatically after a Wi-Fi change.
            await findConnection(manual: false, report: !busy)
            guard connected else { notice = connectionIssue; isError = true; return }
        }
        // Read again after the search: books may have been removed or queued meanwhile.
        // Each job remembers the Kindles ticked now; changing them later affects later books only.
        let kindles = deliver ? targets : []
        let jobs = pool.map { Job(id: $0.id, deliver: deliver, mode: mode(of: $0), target: goal(of: $0), kindles: kindles) }
            .filter { translationReady != false || $0.mode == .original }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            guard let index = articles.firstIndex(where: { $0.id == job.id }) else { continue }
            articles[index].status = "排队中"; articles[index].details = ""
            articles[index].wantsKindle = deliver
        }
        if isError { dismissNotice() }
        if skipped > 0 { notice = "\(skipped) 本要翻译的书没有开始：还没安装翻译组件。"; isError = true }
        save()
        let originals = jobs.filter { $0.mode == .original }
        let translations = jobs.filter { $0.mode != .original }
        // Both queues at once: a long translation never holds up the books that go as they are.
        await withTaskGroup(of: Void.self) { group in
            if !translations.isEmpty {
                if translation.running { translation.queue += translations; translation.total += translations.count }
                else {
                    translation.reset(total: translations.count); translation.queue = translations
                    group.addTask { await self.runTranslation() }
                }
            }
            if !originals.isEmpty {
                if quick.running { quick.queue += originals; quick.total += originals.count }
                else {
                    quick.reset(total: originals.count); quick.queue = originals
                    group.addTask { await self.runQuick() }
                }
            }
        }
    }

    /// Books queued while a single translation (a preview, or one picked up at launch) was running.
    private func runQueuedTranslations() async {
        guard !translation.running, !translation.queue.isEmpty else { return }
        let queued = translation.queue
        translation.reset(total: queued.count); translation.queue = queued
        await runTranslation()
    }

    /// The next queued job still in the list; removed books are dropped from the count.
    private func next(_ lane: ReferenceWritableKeyPath<PushStore, Lane>) -> (Job, Int)? {
        while !self[keyPath: lane].queue.isEmpty {
            let job = self[keyPath: lane].queue.removeFirst()
            if let index = articles.firstIndex(where: { $0.id == job.id }), articles[index].status == "排队中" {
                return (job, index)
            }
            self[keyPath: lane].total -= 1
        }
        return nil
    }

    private func runQuick() async {
        quick.running = true; sendStopRequested = false; cancelNow = false
        while !sendStopRequested, let (job, index) = next(\.quick) {
            active.insert(job.id); defer { active.remove(job.id) }
            await deliver(job, index: index, source: articles[index].path, translated: false, lane: \.quick)
        }
        let stopped = sendStopRequested
        // Stopping ends the queue; books not started go back to waiting, ready to send again.
        for job in quick.queue {
            if let index = articles.firstIndex(where: { $0.id == job.id }), articles[index].status == "排队中" {
                articles[index].status = "等待发送"
            }
        }
        quick.queue = []
        quick.running = false; sendStopRequested = false; cancelNow = false
        save()
        report(quick, stopped: stopped, sending: true)
    }

    /// Stop sending after the book in flight; `now` also cancels that book's transfer.
    /// Pressing send again carries on: books already delivered are not sent twice.
    func stopSending(now: Bool = false) {
        guard quick.running else { return }
        sendStopRequested = true
        if now, let id = quick.sending { cancelNow = true; Bridge.cancel("send-\(id)") }
    }

    /// Takes one book out of the queue without stopping the others.
    func unqueue(_ ids: Set<UUID>) {
        for index in articles.indices where ids.contains(articles[index].id) && articles[index].status == "排队中" {
            articles[index].status = "等待发送"; articles[index].details = "已移出队列"
        }
        save()
    }

    private func runTranslation() async {
        translation.running = true; stopRequested = false
        while let (job, index) = next(\.translation) {
            active.insert(job.id); defer { active.remove(job.id) }
            if stopRequested { break }
            guard let output = await translate(index: index, preview: false, mode: job.mode, target: job.target) else {
                translation.failures += 1; translation.completed += 1; save(); continue
            }
            if stopRequested { break }
            guard let index = articles.firstIndex(where: { $0.id == job.id }) else { continue }
            if job.deliver {
                // Hours may have passed since the book was queued: find the Kindle again.
                await findConnection(manual: false, report: false)
                guard connected else {
                    articles[index].details = "翻译完成，但没连上 Kindle：\(connectionIssue)"
                    translation.failures += 1; translation.completed += 1; save(); continue
                }
            }
            await deliver(job, index: index, source: output, translated: true, lane: \.translation)
        }
        let stopped = stopRequested
        // A stop ends the whole queue; what has not started goes back to waiting.
        for job in translation.queue {
            if let index = articles.firstIndex(where: { $0.id == job.id }), articles[index].status == "排队中" {
                articles[index].status = "等待发送"
            }
        }
        translation.queue = []
        translation.running = false
        save()
        report(translation, stopped: stopped)
    }

    /// The last step of a job: send to the Kindle, or keep on this Mac.
    private func deliver(_ job: Job, index: Int, source: String, translated: Bool,
                         lane: ReferenceWritableKeyPath<PushStore, Lane>) async {
        let id = job.id
        var index: Int { articles.firstIndex { $0.id == id } ?? index }
        let step = "\(self[keyPath: lane].completed + 1) / \(self[keyPath: lane].total)"
        if !job.deliver {
            var output = translated ? source : nil
            if output == nil {
                articles[index].status = "发送中"; articles[index].details = "正在转换…"
                self[keyPath: lane].activity = "正在转换 \(step)：\(articles[index].title)"
                let response = await Bridge.call(["convert", source])
                output = response.ok ? response.output : nil
                if !response.ok { articles[index].details = response.message ?? "转换失败" }
            }
            guard articles.contains(where: { $0.id == id }) else { return }
            if let output {
                articles[index].status = "已保存"; articles[index].details = "已保存到本机 · 可在访达中查看"
                articles[index].output = output; self[keyPath: lane].saved.append(URL(fileURLWithPath: output))
            } else { articles[index].status = "失败"; self[keyPath: lane].failures += 1 }
            self[keyPath: lane].completed += 1; save(); return
        }
        articles[index].status = "发送中"
        self[keyPath: lane].activity = "正在发送 \(step)：\(articles[index].title)"
        if !job.kindles.isEmpty {
            await deliverToEach(job, source: source, step: step, lane: lane)
            return
        }
        let response = await transfer(["send", host, source] + (deviceId.isEmpty ? [] : [deviceId]), id: id, lane: lane)
        guard articles.contains(where: { $0.id == id }) else { return }
        if response.state == "cancelled" {
            // The receiver discards an unfinished file, so nothing half-written stays on the Kindle.
            articles[index].status = "等待发送"; articles[index].details = "已取消发送"
            self[keyPath: lane].total -= 1; save(); return
        }
        articles[index].status = response.ok ? "已发送" : "失败"
        articles[index].details = response.ok ? (response.details?.contains("提示：") == true ? response.details! : "已读回文件，校验一致") : (response.message ?? "发送失败")
        articles[index].output = response.output
        if response.ok { record(articles[index], sentAs: response.output, device: response.device) }
        if response.ok { self[keyPath: lane].sent += 1 } else { self[keyPath: lane].failures += 1 }
        self[keyPath: lane].completed += 1; save()
    }

    /// Sends and shows how far it has got, read from a file the bridge keeps up to date.
    private func transfer(_ arguments: [String], id: UUID, lead: String = "",
                          lane: ReferenceWritableKeyPath<PushStore, Lane>) async -> BridgeResponse {
        self[keyPath: lane].sending = id
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kindle-send-\(id.uuidString).json")
        let watcher = Task { [weak self] in
            struct Mark: Decodable { let percent: Int; let stage: String }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let data = try? Data(contentsOf: file), let mark = try? JSONDecoder().decode(Mark.self, from: data),
                      let self, let index = self.articles.firstIndex(where: { $0.id == id }), !Task.isCancelled else { continue }
                self.articles[index].progress = Double(mark.percent) / 100
                self.articles[index].details = lead + (mark.stage == "verify" ? "正在校验…" : "正在发送 · \(mark.percent)%")
            }
        }
        let response = await Bridge.call(arguments, tag: "send-\(id)", progressFile: file.path)
        watcher.cancel()
        try? FileManager.default.removeItem(at: file)
        self[keyPath: lane].sending = nil
        if let index = articles.firstIndex(where: { $0.id == id }) { articles[index].progress = nil }
        return response
    }

    /// One book to every Kindle ticked when it was queued, in turn. A Kindle that is away does not
    /// hold up the others; a retry sends only to those that did not get it.
    private func deliverToEach(_ job: Job, source: String, step: String,
                               lane: ReferenceWritableKeyPath<PushStore, Lane>) async {
        let id = job.id
        var index: Int { articles.firstIndex { $0.id == id } ?? 0 }
        let waiting = job.kindles.filter { !(articles[index].deliveredTo ?? []).contains($0.id) }
        var missed: [String] = []
        for kindle in waiting {
            // A Kindle already found away is not searched for again for every book in the batch.
            if let until = awayUntil[kindle.id], until > Date() { missed.append("「\(kindle.name)」不在这个 Wi-Fi 里"); continue }
            guard articles.contains(where: { $0.id == id }) else { return }
            articles[index].details = "正在发到「\(kindle.name)」…"
            let lead = job.kindles.count > 1 ? "「\(kindle.name)」" : ""
            self[keyPath: lane].activity = "正在发送 \(step)：\(articles[index].title) → \(kindle.name)"
            let response = await transfer(["send", kindle.host, source, kindle.id], id: id, lead: lead, lane: lane)
            guard articles.contains(where: { $0.id == id }) else { return }
            if response.state == "cancelled" {
                // Those already reached stay recorded; pressing send again carries on from here.
                articles[index].status = "等待发送"; articles[index].details = "已取消发送"
                self[keyPath: lane].total -= 1; save(); return
            }
            if response.ok {
                articles[index].deliveredTo = (articles[index].deliveredTo ?? []) + [kindle.id]
                articles[index].output = response.output
                record(articles[index], sentAs: response.output, device: response.device ?? kindle.name)
                save()
            } else {
                if response.state == "away" { awayUntil[kindle.id] = Date().addingTimeInterval(120) }
                missed.append(response.message ?? "「\(kindle.name)」没有发成")
            }
        }
        let names = job.kindles.filter { (articles[index].deliveredTo ?? []).contains($0.id) }.map(\.name)
        if missed.isEmpty {
            articles[index].status = "已发送"
            articles[index].details = "已送达 \(names.joined(separator: "、")) · 校验一致"
            self[keyPath: lane].sent += 1
        } else {
            articles[index].status = "失败"
            let reached = names.isEmpty ? "" : "已发到 \(names.joined(separator: "、"))；"
            let reasons = missed.map { $0.hasSuffix("。") ? String($0.dropLast()) : $0 }
            articles[index].details = reached + reasons.joined(separator: "；") + (names.isEmpty ? "" : "。重试只发给没收到的")
            self[keyPath: lane].failures += 1
        }
        self[keyPath: lane].completed += 1; save()
    }

    /// One message when a queue runs dry.
    private func report(_ lane: Lane, stopped: Bool, sending: Bool = false) {
        if !lane.saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(lane.saved) }
        var parts: [String] = []
        if stopped {
            parts.append(sending ? "已停止发送。没发的书回到待发送，再点「发送到 Kindle」接着发"
                                 : "已停止。已完成的翻译保留，未开始的书回到待发送")
        }
        if lane.sent > 0 { parts.append("\(lane.sent) 篇已送达 · 在 KOReader 打开 documents › 我的文章") }
        if !lane.saved.isEmpty { parts.append("\(lane.saved.count) 个文件已保存到本机，已在访达中选中") }
        if lane.failures > 0 { parts.append("\(lane.failures) 篇未完成，可以重试") }
        guard !parts.isEmpty else { return }
        announce(parts.joined(separator: "；") + "。", error: lane.failures > 0)
        guard !stopped else { return }
        // One failure's own reason says what to do next, which a count does not.
        let failed = articles.filter { $0.phase == .failed }
        let body = lane.failures == 1 && failed.count == 1 ? "《\(failed[0].title)》：\(failed[0].details)" : parts.joined(separator: "；") + "。"
        Notify.post(lane.failures > 0 ? "有书没有完成" : "都完成了", body)
    }

    private func translate(index: Int, preview: Bool, mode: OutputMode, target: String) async -> String? {
        articles[index].status = preview ? "试译中" : "翻译中"
        articles[index].details = "正在准备\(title(mode, for: articles[index]))版…"
        translation.activity = "正在\(preview ? "试译" : "翻译")：\(articles[index].title)"; save()
        let id = articles[index].id
        articles[index].problem = nil
        Notify.ask()
        let response = await Bridge.call(["translation-start", articles[index].path, preview ? "preview" : "full",
                                          mode == .targetOnly ? "target-only" : "bilingual", target])
        return await follow(id, from: response, preview: preview, mode: mode, target: target)
    }

    /// Polls a translation job until it ends; shared by new runs and by jobs found at launch.
    private func follow(_ id: UUID, from first: BridgeResponse, preview: Bool, mode: OutputMode, target: String) async -> String? {
        guard articles.contains(where: { $0.id == id }) else { return nil }
        var index: Int { articles.firstIndex { $0.id == id } ?? 0 }
        var response = first
        currentJob = response.job
        while let job = currentJob, response.ok, ["queued", "running"].contains(response.state ?? "") {
            if stopRequested { _ = await Bridge.call(["translation-cancel", job]) }
            articles[index].details = response.message ?? "正在翻译…"
            if let percent = response.percent { articles[index].progress = Double(percent) / 100 }
            try? await Task.sleep(for: .seconds(1))
            response = await Bridge.call(["translation-progress", job])
        }
        currentJob = nil
        articles[index].progress = nil
        if let tokensIn = response.tokensIn, let tokensOut = response.tokensOut { articles[index].tokens = tokensIn + tokensOut }
        articles[index].problem = response.problem
        guard response.ok, response.state == "done", let output = response.output, !stopRequested else {
            articles[index].status = stopRequested || response.state == "cancelled" ? "已停止" : "失败"
            articles[index].details = response.message ?? "翻译未完成，请检查翻译设置。"; save()
            return nil
        }
        articles[index].status = preview ? "试译完成" : "翻译完成"
        articles[index].details = preview ? "已生成 3 段试译，整本翻译会单独处理。" : "译本已生成，正在准备发送。"
        if !preview {
            articles[index].bilingual = true; articles[index].chineseOnly = mode == .targetOnly
            articles[index].translatedTo = target
        }
        save()
        return output
    }

    /// Three paragraphs of one foreign book, in its chosen layout (bilingual when it goes as it is).
    func preview(_ id: UUID) async {
        guard !translation.running, let index = articles.firstIndex(where: { $0.id == id }),
              translatable(articles[index]), articles[index].language != goal(of: articles[index]),
              articles[index].phase != .working else { return }
        guard translationReady != false else {
            notice = "还没安装翻译组件，请先在翻译设置里安装。"; isError = true; return
        }
        let first = articles[index]
        let mode = first.choice == .targetOnly ? OutputMode.targetOnly : .bilingual
        let before = (first.status, first.details)
        translation.reset(total: 1); stopRequested = false; dismissNotice()
        if let output = await translate(index: index, preview: true, mode: mode, target: goal(of: first)) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
            announce("试译已在访达里打开，没有发到 Kindle。满意了再译整本。", error: false)
        } else if let failed = articles.first(where: { $0.id == first.id }) {
            notice = failed.details; isError = !stopRequested
        }
        // A preview does not change what the book is waiting for.
        if let index = articles.firstIndex(where: { $0.id == first.id }), articles[index].status != "失败" {
            articles[index].status = before.0 == "等待继续" ? "等待发送" : before.0; articles[index].details = before.1; save()
        }
        translation.running = false
        await runQueuedTranslations()
    }

    func stopTranslation() {
        stopRequested = true
        if let job = currentJob { Task { _ = await Bridge.call(["translation-cancel", job]) } }
        // Past translating and on its way to the Kindle: the same button stops that.
        if let id = translation.sending { Bridge.cancel("send-\(id)") }
    }

    /// "1.2 万", for tokens; nobody needs the digits of a rough count.
    nonisolated static func tokenText(_ count: Int) -> String {
        if I18n.english { return count < 1000 ? "\(count)" : count < 1_000_000 ? "\(count / 1000)k" : String(format: "%.1fM", Double(count) / 1_000_000) }
        if count < 10_000 { return "\(count)" }
        let wan = Double(count) / 10_000
        return wan < 10 ? String(format: "%.1f 万", wan) : "\(Int(wan.rounded())) 万"
    }

    func revealOutput() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Kindle推送/已转换")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

/// One queue of work and its tally for the current run.
struct Lane {
    var queue: [Job] = []
    var running = false
    var completed = 0, total = 0, failures = 0, sent = 0
    var saved: [URL] = []
    var activity = ""
    /// The book this queue is transferring right now, for "cancel this one".
    var sending: UUID?

    mutating func reset(total: Int) {
        queue = []; running = true; completed = 0; self.total = total; failures = 0; sent = 0; saved = []; activity = ""
    }
}

struct Job {
    let id: UUID
    let deliver: Bool
    let mode: OutputMode
    var target = "zh"
    /// Kindles ticked when this was queued. Empty: the connected one, as with a single Kindle.
    var kindles: [KindleDevice] = []
}
