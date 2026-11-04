import SwiftUI
import AppKit

@MainActor
final class PushStore: ObservableObject {
    @Published var articles: [Article] = []
    @Published var host = ""
    @Published var manualHost = ""
    @Published var connected = false
    /// Translation and everything else run in separate queues, so a translation that takes hours
    /// never holds up sending, saving or tidying the other books.
    @Published var translation = Lane()
    @Published var quick = Lane()
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
    @Published var outputMode: OutputMode = OutputMode.saved {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") }
    }
    var translateBooks: Bool { outputMode != .original }
    @Published var currentJob: String?
    @Published var settingsTab: SettingsTab = .service
    private var stopRequested = false
    private var started = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "articles"),
           let saved = try? JSONDecoder().decode([Article].self, from: data) {
            articles = saved.map { item in
                var item = item
                if ["发送中", "翻译中", "试译中"].contains(item.status) { item.status = "等待继续" }
                if item.status == "排队中" { item.status = "等待发送" }
                return item
            }
        }
        updateBadge()
        Task { await loadBookInfo() }
    }

    /// Titles, authors and covers for items that do not have them yet.
    func loadBookInfo() async {
        for article in articles where article.bookTitle == nil {
            let response = await Bridge.call(["book-info", article.path])
            guard let index = articles.firstIndex(where: { $0.id == article.id }) else { continue }
            if response.ok {
                articles[index].bookTitle = response.title ?? ""
                articles[index].author = response.author
                articles[index].cover = response.cover
            } else { articles[index].bookTitle = "" }
            if articles[index].format == "PDF", articles[index].cover == nil {
                articles[index].cover = await Covers.pdf(articles[index].path)
            }
        }
        save()
    }

    var pendingCount: Int { articles.filter { $0.status != "已发送" }.count }
    var previewAvailable: Bool { articles.contains { $0.format == "EPUB" && $0.status != "已发送" } }
    /// How far each queue has got; translation counts the book being translated right now.
    var translationProgress: Double {
        let current = articles.first { $0.status == "翻译中" }?.progress ?? 0
        return min(1, (Double(translation.completed) + current) / Double(max(translation.total, 1)))
    }
    var quickProgress: Double { min(1, Double(quick.completed) / Double(max(quick.total, 1))) }
    /// Books the main buttons would start now in this mode: not sent, not already queued or running.
    var queueable: [Article] {
        articles.filter { $0.status != "已发送" && $0.status != "排队中" && $0.phase != .working
            && (outputMode == .original || $0.format == "EPUB") }
    }
    var sentCount: Int { articles.count - pendingCount }
    /// Why the send and save buttons are disabled, in words; nil when they are not.
    var nothingToSendReason: String? {
        guard queueable.isEmpty, !busy, !articles.isEmpty else { return nil }
        if pendingCount == 0 { return "都已送达。拖入新的书，或右键一本书「放回待发送」再发一次" }
        if translateBooks && !articles.contains(where: { $0.status != "已发送" && $0.format == "EPUB" }) {
            return nil   // nonEpubPending explains this one
        }
        return "没有可发送的书"
    }
    var nonEpubPending: Bool { articles.contains { $0.status != "已发送" && $0.format != "EPUB" } }
    var connectionTitle: String {
        if searching { return "正在寻找…" }
        if connected { return "我的 Kindle" }
        return setupNeeded ? "需要首次配置" : "未连接 Kindle"
    }

    func save() {
        if let data = try? JSONEncoder().encode(articles) { UserDefaults.standard.set(data, forKey: "articles") }
        updateBadge()
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = pendingCount > 0 ? "\(pendingCount)" : nil
    }

    func dismissNotice() { notice = ""; isError = false }

    private func announce(_ message: String, error: Bool) {
        notice = message; isError = error
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
                articles[index].details = ""
                articles[index].output = nil; articles[index].bilingual = false
            } else { articles.append(Article(path: path)) }
        }
        Task { await loadBookInfo() }
        if rejected > 0 { notice = "已略过 \(rejected) 个不支持的文件。支持 KOReader 能打开的电子书、漫画、文档，以及 Markdown。"; isError = true }
        else if isError { dismissNotice() }
        save()
    }

    func remove(_ id: UUID) { remove([id]) }
    /// The book being worked on stays; anything else can go, even mid-batch (the batch skips missing items).
    func remove(_ ids: Set<UUID>) {
        articles.removeAll { ids.contains($0.id) && !(busy && $0.phase == .working) }; save()
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

    func clearSent() { articles.removeAll { $0.status == "已发送" }; save() }
    func retry(_ id: UUID) {
        guard let index = articles.firstIndex(where: { $0.id == id }),
              articles[index].status != "排队中", articles[index].phase != .working else { return }
        articles[index].status = "等待发送"; articles[index].details = ""; save()
    }

    func start() async {
        guard !started else { return }; started = true
        await refreshTranslationStatus()
        Task { await resumeTranslations() }
        let status = await Bridge.call(["status"])
        if status.ok {
            host = status.host ?? ""; manualHost = host
            await findConnection(manual: false, report: false)
        } else {
            setupNeeded = true
            connectionIssue = status.message ?? "还没完成首次配置。"
            activity = "需要首次配置"
        }
    }

    /// Translations that kept running, or finished, while the app was closed: show them again.
    private func resumeTranslations() async {
        for article in articles where article.format == "EPUB" && ["等待继续", "翻译中"].contains(article.status) {
            let found = await Bridge.call(["translation-find", article.path])
            guard found.ok, let index = articles.firstIndex(where: { $0.id == article.id }) else { continue }
            switch found.state {
            case "queued", "running":
                guard !translation.running else { continue }
                translation.reset(total: 1); stopRequested = false
                articles[index].status = "翻译中"
                articles[index].chineseOnly = found.mode == "chinese"
                translation.activity = "正在翻译：\(article.title)"
                let output = await follow(article.id, from: found, preview: false, mode: found.mode == "chinese" ? .chinese : .bilingual)
                if output != nil { translationFinished(article.id) }
                else if !stopRequested, let failed = articles.first(where: { $0.id == article.id }) {
                    notice = failed.details; isError = true
                }
                translation.running = false
                // Books queued while this one was being picked up.
                await runQueuedTranslations()
            case "done":
                articles[index].output = found.output; articles[index].bilingual = true
                articles[index].chineseOnly = found.mode == "chinese"
                articles[index].status = "翻译完成"
                translationFinished(article.id)
            default:
                break
            }
        }
    }

    private func translationFinished(_ id: UUID) {
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        articles[index].details = "中文对照版已生成 · 点「翻译并发送」送到 Kindle"
        save()
        announce("《\(articles[index].title)》翻译完成。点「翻译并发送」会直接用这份译本。", error: false)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func refreshTranslationStatus() async {
        let response = await Bridge.call(["translation-settings"])
        translationReady = response.runtimeReady ?? false
        translationProvider = response.provider ?? ""
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
        if response.ok {
            host = response.host ?? ""; manualHost = host; connected = true
            setupNeeded = false; connectionIssue = ""
            if report { activity = "Kindle 已连接" }
        } else {
            connectionIssue = response.message ?? "没有找到 Kindle，请重试。"
            if report { activity = "Kindle 尚未连接" }
        }
    }

    func send() async { await enqueue(deliver: true) }
    /// Convert or translate without a Kindle: the result stays on this Mac.
    func saveLocally() async { await enqueue(deliver: false) }

    /// Queues every ready book for the chosen version. Translations go to their own queue;
    /// pressing again while a queue runs adds to it instead of waiting.
    private func enqueue(deliver: Bool) async {
        let mode = outputMode
        guard !queueable.isEmpty else {
            if mode != .original && nonEpubPending {
                notice = "翻译只支持 EPUB。其他格式请切回「原文」发送或保存。"; isError = true
            }
            return
        }
        if deliver {
            // Revalidate every time; recover automatically after a Wi-Fi change.
            await findConnection(manual: false, report: !busy)
            guard connected else { notice = connectionIssue; isError = true; return }
        }
        // Read again after the search: books may have been removed or queued meanwhile.
        let jobs = queueable.map { Job(id: $0.id, deliver: deliver, mode: mode) }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            guard let index = articles.firstIndex(where: { $0.id == job.id }) else { continue }
            articles[index].status = "排队中"; articles[index].details = ""
        }
        if isError { dismissNotice() }
        save()
        if mode == .original {
            if quick.running { quick.queue += jobs; quick.total += jobs.count }
            else { quick.reset(total: jobs.count); quick.queue = jobs; await runQuick() }
        } else {
            if translation.running { translation.queue += jobs; translation.total += jobs.count }
            else { translation.reset(total: jobs.count); translation.queue = jobs; await runTranslation() }
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
        quick.running = true
        while let (job, index) = next(\.quick) {
            await deliver(job, index: index, source: articles[index].path, translated: false, lane: \.quick)
        }
        quick.running = false
        report(quick, stopped: false)
    }

    private func runTranslation() async {
        translation.running = true; stopRequested = false
        while let (job, index) = next(\.translation) {
            if stopRequested { break }
            guard let output = await translate(index: index, preview: false, mode: job.mode) else {
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
        let response = await Bridge.call(["send", host, source])
        guard articles.contains(where: { $0.id == id }) else { return }
        articles[index].status = response.ok ? "已发送" : "失败"
        articles[index].details = response.ok ? (response.details?.contains("提示：") == true ? response.details! : "已读回文件，校验一致") : (response.message ?? "发送失败")
        articles[index].output = response.output
        if response.ok { self[keyPath: lane].sent += 1 } else { self[keyPath: lane].failures += 1 }
        self[keyPath: lane].completed += 1; save()
    }

    /// One message when a queue runs dry.
    private func report(_ lane: Lane, stopped: Bool) {
        if !lane.saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(lane.saved) }
        var parts: [String] = []
        if stopped { parts.append("已停止。已完成的翻译保留，未开始的书回到待发送") }
        if lane.sent > 0 { parts.append("\(lane.sent) 篇已送达 · 在 KOReader 打开 documents › 我的文章") }
        if !lane.saved.isEmpty { parts.append("\(lane.saved.count) 个文件已保存到本机，已在访达中选中") }
        if lane.failures > 0 { parts.append("\(lane.failures) 篇未完成，可以重试") }
        guard !parts.isEmpty else { return }
        announce(parts.joined(separator: "；") + "。", error: lane.failures > 0)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func translate(index: Int, preview: Bool, mode: OutputMode) async -> String? {
        articles[index].status = preview ? "试译中" : "翻译中"
        articles[index].details = "正在准备中文对照版…"
        translation.activity = "正在\(preview ? "试译" : "翻译")：\(articles[index].title)"; save()
        let id = articles[index].id
        let response = await Bridge.call(["translation-start", articles[index].path, preview ? "preview" : "full", mode.engineMode])
        return await follow(id, from: response, preview: preview, mode: mode)
    }

    /// Polls a translation job until it ends; shared by new runs and by jobs found at launch.
    private func follow(_ id: UUID, from first: BridgeResponse, preview: Bool, mode: OutputMode) async -> String? {
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
        guard response.ok, response.state == "done", let output = response.output, !stopRequested else {
            articles[index].status = stopRequested || response.state == "cancelled" ? "已停止" : "失败"
            articles[index].details = response.message ?? "翻译未完成，请检查翻译设置。"; save()
            return nil
        }
        articles[index].status = preview ? "试译完成" : "翻译完成"
        articles[index].details = preview ? "已生成 3 段试译，整本翻译会单独处理。" : "中文对照版已生成，正在准备发送。"
        if !preview { articles[index].bilingual = true; articles[index].chineseOnly = mode == .chinese }
        save()
        return output
    }

    func preview() async {
        guard !translation.running, outputMode != .original, let first = queueable.first,
              let index = articles.firstIndex(where: { $0.id == first.id }) else { return }
        translation.reset(total: 1); stopRequested = false; dismissNotice()
        if let output = await translate(index: index, preview: true, mode: outputMode) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
            announce("试译样本已在访达中打开，没有发送到 Kindle。满意后再翻译整本。", error: false)
        } else if let failed = articles.first(where: { $0.id == first.id }) {
            notice = failed.details; isError = !stopRequested
        }
        translation.running = false
        await runQueuedTranslations()
    }

    func stopTranslation() {
        stopRequested = true
        if let job = currentJob { Task { _ = await Bridge.call(["translation-cancel", job]) } }
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

    mutating func reset(total: Int) {
        queue = []; running = true; completed = 0; self.total = total; failures = 0; sent = 0; saved = []; activity = ""
    }
}

struct Job {
    let id: UUID
    let deliver: Bool
    let mode: OutputMode
}
