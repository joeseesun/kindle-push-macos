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
        .defaultSize(width: 620, height: 740)
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
            CommandGroup(replacing: .appSettings) {
                Button("翻译设置…") { store.showTranslationSettings = true }
                    .keyboardShortcut(",").disabled(store.busy)
            }
            CommandMenu("Kindle") {
                Button("自动寻找") { Task { await store.connect() } }.disabled(store.busy)
                Button("发送文章") { Task { await store.send() } }.disabled(store.busy || store.pendingCount == 0)
                Divider()
                Button("查看已转换文件") { store.revealOutput() }
            }
        }
    }
}
