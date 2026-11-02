import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        WindowGroup("Kindle 推送") {
            ContentView(store: store)
        }
        .defaultSize(width: 660, height: 640)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Kindle 推送") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Kindle 推送"])
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
            TranslationSettingsView(store: store)
        }
    }
}
