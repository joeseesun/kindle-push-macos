import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder or the Dock, all at once and into the one window.
    var open: (([URL]) -> Void)? { didSet { flush() } }
    private var pending: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) { pending += urls; flush() }
    private func flush() {
        guard let open, !pending.isEmpty else { return }
        open(pending); pending = []
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = Updater.shared
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KindlePushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PushStore()
    init() { PDFPages.runIfRequested() }
    var body: some Scene {
        Window("乔木 Kindle 助手", id: "main") {
            ContentView(store: store)
                .tint(.ink)
                .onAppear { appDelegate.open = { store.add($0) } }
        }
        .defaultSize(width: 660, height: 640)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton(store: store)
                Button("检查更新…") { Updater.shared.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("添加文章…") { store.showPicker = true }
                    .keyboardShortcut("o")
                Button("整理文件名…") { store.tidyNames() }
                    .keyboardShortcut("e").disabled(store.articles.isEmpty)
            }
            CommandMenu("Kindle") {
                Button("重新寻找 Kindle") { Task { await store.connect() } }
                    .keyboardShortcut("r").disabled(store.searching)
                Button("连接设置…") { store.showConnection = true }
                    .keyboardShortcut("k")
                Button("添加 Kindle…") { store.showConnection = false; store.showAddKindle = true }
                Button("发送历史…") { store.showConnection = false; store.showHistory = true }
                    .keyboardShortcut("y")
                Divider()
                Button("发送到 Kindle") { Task { await store.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.queueable.isEmpty)
                Button("保存到本机") { Task { await store.saveLocally() } }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(store.queueable.isEmpty)
                Button(store.quick.running ? "停止发送" : "停止翻译") {
                    if store.quick.running { store.stopSending() } else { store.stopTranslation() }
                }
                .keyboardShortcut(".").disabled(store.currentJob == nil && !store.quick.running)
                Divider()
                Button("查看已转换文件") { store.revealOutput() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        Settings {
            TranslationSettingsView(store: store).tint(.ink)
        }
    }
}
