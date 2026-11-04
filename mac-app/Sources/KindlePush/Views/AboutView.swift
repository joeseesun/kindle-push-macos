import SwiftUI
import AppKit

enum SettingsTab: Hashable { case service, quality, about }

enum Links {
    static let repo = URL(string: "https://github.com/joeseesun/kindle-push-macos")!
    static let issues = URL(string: "https://github.com/joeseesun/kindle-push-macos/issues/new")!
    static let site = URL(string: "https://kindle.qiaomu.ai/")!
}

/// About: icon, version, actions, follow/tip QR cards (bundled, works offline), links, privacy line, license.
struct AboutView: View {
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("乔木 Kindle 助手").font(.system(size: 20, weight: .semibold))
                        Text("Kindle Push \(version)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("把文章和电子书经 Wi‑Fi 送到 Kindle，可选中英对照翻译。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                AboutButton("检查更新", "arrow.triangle.2.circlepath") { Updater.shared.checkForUpdates() }
                AboutButton("反馈问题", "ladybug") { NSWorkspace.shared.open(Links.issues) }
                AboutButton("使用说明", "book") { NSWorkspace.shared.open(Links.site) }
                AboutButton("源代码", "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(Links.repo) }
            }
            Toggle("自动检查更新（每天一次，有新版时提示你）", isOn: $autoUpdate)
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(.secondary)
                .onChange(of: autoUpdate) { Updater.shared.automaticallyChecks = autoUpdate }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                QRCard(image: "wechat-qr.jpg", title: "关注公众号", symbol: "newspaper", hint: "微信搜索「向阳乔木推荐看」")
                QRCard(image: "reward-qr.png", title: "请我喝杯咖啡", symbol: "cup.and.saucer", hint: "微信扫码，支持持续更新")
            }
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    ForEach([("qiaomu.ai", "https://qiaomu.ai/"), ("博客", "https://blog.qiaomu.ai/"), ("乔木推荐", "https://tuijian.qiaomu.ai/"),
                             ("X", "https://x.com/vista8"), ("GitHub", "https://github.com/joeseesun")], id: \.0) { item in
                        Link(item.0, destination: URL(string: item.1)!).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                }
                Text("本机排版，经 Wi‑Fi 直传 Kindle。只有翻译时，正文才发给你设置的翻译服务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("© \(String(Calendar.current.component(.year, from: Date()))) 向阳乔木 · MIT 许可 · 基于 chasepal/kindle-push-macos\n第三方许可见 THIRD_PARTY_NOTICES.md")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(width: 520)
    }
}

private struct AboutButton: View {
    let title: String, symbol: String, action: () -> Void
    @State private var hover = false
    init(_ title: String, _ symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.09 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct QRCard: View {
    let image: String, title: String, symbol: String, hint: String
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("About/\(image)"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                } else { Color.primary.opacity(0.05) }
            }
            .frame(width: 128, height: 128).padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            VStack(spacing: 3) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// "关于 乔木 Kindle 助手" in the app menu: the About tab of Settings, not the bare system panel.
struct AboutMenuButton: View {
    @ObservedObject var store: PushStore
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("关于 乔木 Kindle 助手") { store.settingsTab = .about; openSettings() }
    }
}
