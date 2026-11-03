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
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct KindlePushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PushStore()
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
                Button("关于 乔木 Kindle 助手") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "乔木 Kindle 助手"])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("添加文章…") { store.showPicker = true }
                    .keyboardShortcut("o").disabled(store.busy)
            }
            CommandMenu("Kindle") {
                Button("重新寻找 Kindle") { Task { await store.connect() } }
                    .keyboardShortcut("r").disabled(store.busy)
                Button("连接设置…") { store.showConnection = true }
                    .keyboardShortcut("k")
                Divider()
                Button("发送到 Kindle") { Task { await store.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.busy || store.pendingCount == 0)
                Button(store.translateBooks ? "翻译并保存到本机" : "保存到本机") { Task { await store.saveLocally() } }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(store.busy || store.pendingCount == 0)
                Button("先试译 3 段") { Task { await store.preview() } }
                    .disabled(store.busy || !store.translateBooks || !store.previewAvailable)
                Button("停止翻译") { store.stopTranslation() }
                    .keyboardShortcut(".").disabled(store.currentJob == nil)
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
