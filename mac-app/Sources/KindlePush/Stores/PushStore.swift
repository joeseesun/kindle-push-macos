import SwiftUI
import AppKit

@MainActor
final class PushStore: ObservableObject {
    @Published var articles: [Article] = []
    @Published var host = ""
    @Published var manualHost = ""
    @Published var connected = false
    @Published var busy = false
    @Published var activity = "正在检查连接…"
    @Published var notice = ""
    @Published var isError = false
    @Published var showPicker = false
    @Published var showConnection = false
    @Published var searching = false
    @Published var connectionIssue = ""
    @Published var setupNeeded = false
    @Published var translationReady: Bool?
    @Published var translationProvider = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var translateBooks = UserDefaults.standard.bool(forKey: "translateBooks") {
        didSet { UserDefaults.standard.set(translateBooks, forKey: "translateBooks") }
    }
    @Published var currentJob: String?
    private var stopRequested = false
    private var started = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "articles"),
           let saved = try? JSONDecoder().decode([Article].self, from: data) {
            articles = saved.map { item in
                var item = item
                if ["发送中", "翻译中", "试译中"].contains(item.status) { item.status = "等待继续" }
                return item
            }
        }
        updateBadge()
    }

    var pendingCount: Int { articles.filter { $0.status != "已发送" }.count }
    var previewAvailable: Bool { articles.contains { $0.format == "EPUB" && $0.status != "已发送" } }
    var sentCount: Int { articles.count - pendingCount }
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

    func add(_ urls: [URL]) {
        guard !busy else { return }
        var rejected = 0
        for url in urls {
            guard url.isFileURL, Article.isSupported(url) else {
                rejected += 1; continue
            }
            let path = url.standardizedFileURL.path
            if let index = articles.firstIndex(where: { $0.path == path }) {
                articles[index].status = "等待发送"
                articles[index].details = ""
                articles[index].output = nil; articles[index].bilingual = false
            } else { articles.append(Article(path: path)) }
        }
        if rejected > 0 { notice = "已略过 \(rejected) 个不支持的文件。支持 KOReader 能打开的电子书、漫画、文档，以及 Markdown。"; isError = true }
        else if isError { dismissNotice() }
        save()
    }

    func remove(_ id: UUID) { remove([id]) }
    func remove(_ ids: Set<UUID>) { guard !busy else { return }; articles.removeAll { ids.contains($0.id) }; save() }
    func reveal(_ ids: Set<UUID>) {
        let urls = articles.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func clearSent() { guard !busy else { return }; articles.removeAll { $0.status == "已发送" }; save() }
    func retry(_ id: UUID) {
        guard !busy, let index = articles.firstIndex(where: { $0.id == id }) else { return }
        articles[index].status = "等待发送"; articles[index].details = ""; save()
    }

    func start() async {
        guard !started else { return }; started = true
        busy = true
        let status = await Bridge.call(["status"])
        if status.ok {
            host = status.host ?? ""; manualHost = host
            await findConnection(manual: false)
        } else {
            setupNeeded = true
            connectionIssue = status.message ?? "还没完成首次配置。"
            activity = "需要首次配置"
        }
        busy = false
        await refreshTranslationStatus()
    }

    func refreshTranslationStatus() async {
        let response = await Bridge.call(["translation-settings"])
        translationReady = response.runtimeReady ?? false
        translationProvider = response.provider ?? ""
    }

    func connect(manual: Bool = false) async {
        guard !busy else { return }
        busy = true
        await findConnection(manual: manual)
        if connected && isError { dismissNotice() }
        busy = false
    }

    private func findConnection(manual: Bool) async {
        connected = false; searching = true
        defer { searching = false }
        activity = manual ? "正在连接 Kindle…" : "正在寻找你的 Kindle…"
        let response = await Bridge.call(manual ? ["connect", manualHost.trimmingCharacters(in: .whitespacesAndNewlines)] : ["discover"])
        if response.ok {
            host = response.host ?? ""; manualHost = host; connected = true
            setupNeeded = false; connectionIssue = ""
            activity = "Kindle 已连接"
        } else {
            connectionIssue = response.message ?? "没有找到 Kindle，请重试。"
            activity = "Kindle 尚未连接"
        }
    }

    func send() async { await process(deliver: true) }
    /// Convert or translate without a Kindle: the result stays on this Mac.
    func saveLocally() async { await process(deliver: false) }

    private func process(deliver: Bool) async {
        guard !busy, pendingCount > 0 else { return }
        if translateBooks && nonEpubPending {
            notice = "中英对照只支持 EPUB。请移除其他格式，或切回原文。"; isError = true; return
        }
        busy = true; notice = ""; isError = false; completed = 0
        stopRequested = false
        let ids = articles.filter { $0.status != "已发送" }.map(\.id)
        total = ids.count
        if deliver {
            // Revalidate every time; recover automatically after a Wi-Fi change.
            await findConnection(manual: false)
            guard connected else {
                notice = connectionIssue; isError = true; busy = false; return
            }
        }
        var failures = 0
        var saved: [URL] = []
        for id in ids {
            if stopRequested { break }
            guard let index = articles.firstIndex(where: { $0.id == id }) else { continue }
            var source = articles[index].path
            if translateBooks {
                guard let output = await translate(index: index, preview: false) else {
                    failures += 1; completed += 1; save(); continue
                }
                source = output
            }
            if stopRequested { break }
            if !deliver {
                var output = translateBooks ? source : nil
                if output == nil {
                    articles[index].status = "发送中"; articles[index].details = "正在转换…"
                    activity = "正在转换 \(completed + 1) / \(total)：\(articles[index].title)"
                    let response = await Bridge.call(["convert", source])
                    output = response.ok ? response.output : nil
                    if !response.ok { articles[index].details = response.message ?? "转换失败" }
                }
                if let output {
                    articles[index].status = "已保存"; articles[index].details = "已保存到本机 · 可在访达中查看"
                    articles[index].output = output; saved.append(URL(fileURLWithPath: output))
                } else { articles[index].status = "失败"; failures += 1 }
                completed += 1; save(); continue
            }
            articles[index].status = "发送中"
            activity = "正在发送 \(completed + 1) / \(total)：\(articles[index].title)"
            let response = await Bridge.call(["send", host, source])
            articles[index].status = response.ok ? "已发送" : "失败"
            articles[index].details = response.ok ? (response.details?.contains("提示：") == true ? response.details! : "已读回文件，校验一致") : (response.message ?? "发送失败")
            articles[index].output = response.output
            if !response.ok { failures += 1 }
            completed += 1; save()
        }
        if !deliver {
            if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
            announce(stopRequested ? "已停止。已完成的文件保留在本机。" : failures == 0 ? "\(saved.count) 个文件已保存到本机，已在访达中选中。" : "\(saved.count) 个已保存，\(failures) 个未完成。", error: failures > 0)
            activity = "已保存到本机"; busy = false
            return
        }
        announce(stopRequested ? "已停止。已完成的翻译保留，未完成的书籍没有发送。" : failures == 0 ? "\(total) 篇已送达 · 在 KOReader 打开 documents › 我的文章" : "\(total - failures) 篇已送达，\(failures) 篇未完成。可以重试未完成的文章。", error: failures > 0)
        activity = stopRequested ? "已停止" : failures == 0 ? "发送完成" : "部分文章未完成"
        busy = false
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func translate(index: Int, preview: Bool) async -> String? {
        articles[index].status = preview ? "试译中" : "翻译中"
        articles[index].details = "正在准备中文对照版…"
        activity = "正在\(preview ? "试译" : "翻译")：\(articles[index].title)"; save()
        var response = await Bridge.call(["translation-start", articles[index].path, preview ? "preview" : "full"])
        currentJob = response.job
        while let job = currentJob, response.ok, ["queued", "running"].contains(response.state ?? "") {
            if stopRequested { _ = await Bridge.call(["translation-cancel", job]) }
            articles[index].details = response.message ?? "正在翻译…"
            try? await Task.sleep(for: .seconds(1))
            response = await Bridge.call(["translation-progress", job])
        }
        currentJob = nil
        guard response.ok, response.state == "done", let output = response.output, !stopRequested else {
            articles[index].status = stopRequested || response.state == "cancelled" ? "已停止" : "失败"
            articles[index].details = response.message ?? "翻译未完成，请检查翻译设置。"; save()
            return nil
        }
        articles[index].status = preview ? "试译完成" : "翻译完成"
        articles[index].details = preview ? "已生成 3 段试译，整本翻译会单独处理。" : "中文对照版已生成，正在准备发送。"
        if !preview { articles[index].bilingual = true }
        save()
        return output
    }

    func preview() async {
        guard !busy, let index = articles.firstIndex(where: { $0.format == "EPUB" && $0.status != "已发送" }) else { return }
        busy = true; stopRequested = false; dismissNotice()
        if let output = await translate(index: index, preview: true) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
            announce("试译样本已在访达中打开，没有发送到 Kindle。满意后再翻译整本。", error: false)
        } else { notice = articles[index].details; isError = !stopRequested }
        busy = false
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
