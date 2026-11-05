import SwiftUI

struct FooterBar: View {
    @ObservedObject var store: PushStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.notice.isEmpty {
                NoticeBanner(store: store)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                summary
                Spacer(minLength: 8)
                if store.quick.running { sendingControls }
                if store.currentJob != nil || store.translation.sending != nil {
                    Button(store.currentJob != nil ? "停止翻译" : "取消发送译本") { store.stopTranslation() }.buttonStyle(.inkOutline).controlSize(.large).fixedSize()
                        .help("停止正在翻译的书；已完成的进度保留，排队的书回到待发送（⌘.）")
                }
                // While a queue runs, only "add to queue" stays, so the stop buttons and progress have room.
                // No Kindle paired: this is a translation tool first, so saving is the main button.
                if store.setupNeeded && !store.busy {
                    sendButton.buttonStyle(.inkOutline)
                    secondaryButton.buttonStyle(.ink)
                } else {
                    if !store.busy { secondaryButton.buttonStyle(.inkOutline) }
                    if !store.busy || !store.queueable.isEmpty { sendButton.buttonStyle(.ink) }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }

    /// What pressing the buttons will do, or how the queues are getting on.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.busy { progress }
            if !store.busy || !store.queueable.isEmpty { caption }
        }
        // Gives way to the buttons, which keep their size: a squeezed button loses its text, not a line of status.
        .frame(alignment: .leading)
    }

    @ViewBuilder private var caption: some View {
        let originals = store.plannedOriginals.count
        let translations = store.plannedTranslations.count
        if let reason = store.nothingToSendReason {
            // The buttons are disabled; say why and what to do, instead of leaving them grey.
            Label(reason, systemImage: "tray").font(.caption).foregroundStyle(.secondary)
        } else if store.queueable.isEmpty {
            EmptyView()
        } else if translations > 0 && store.translationReady == false {
            HStack(spacing: 4) {
                Label("\(translations) 本要翻译，还没安装翻译组件", systemImage: "exclamationmark.triangle")
                SettingsLink { Text("去设置") }.buttonStyle(.inkLink)
            }
            .font(.caption).foregroundStyle(.orange)
        } else if translations == 0 {
            Label("\(originals) 本原文 · 本机排版，经 Wi‑Fi 直传，不经过云端", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            let guess = [store.translationMinutes.map { "约 \(Self.duration($0))" },
                         store.translationTokens.map { "约 \(PushStore.tokenText($0)) token" }].compactMap { $0 }
            let time = guess.isEmpty ? "" : "（\(guess.joined(separator: "，"))）"
            let parts = (originals > 0 ? ["\(originals) 本原文"] : []) + ["\(translations) 本翻译\(time)"]
            Label(parts.joined(separator: " · "), systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary)
                .help(store.translationProvider == "chatgpt" ? "要翻译的书用 ChatGPT 套餐额度翻译，译完自动发送"
                      : "要翻译的书正文发给翻译模型，按用量计费；译完自动发送。时间和用量按书的篇幅粗估")
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        return hours == hours.rounded() ? "\(Int(hours)) 小时" : String(format: "%.1f 小时", hours)
    }

    /// One line per running queue.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.translation.running { line(store.translationProgress, store.translation.activity) }
            if store.quick.running { line(store.quickProgress, store.quick.activity) }
        }
    }

    private func line(_ value: Double, _ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: value).tint(.ink).progressViewStyle(.linear).frame(width: 64)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(text)
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    /// Stop after the book in flight, or cancel it outright. Readable at all times: a status line
    /// replaces the stop button once pressed, instead of a greyed-out button.
    @ViewBuilder private var sendingControls: some View {
        if store.quick.sending != nil {
            Button("取消这本") { store.stopSending(now: true) }
                .buttonStyle(.inkOutline).controlSize(.large).fixedSize()
                .help("断开正在传的这本，Kindle 上不会留下半个文件；后面的书也不再发送")
        }
        if store.sendStopRequested {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("这本发完就停").font(.callout)
            }
            .fixedSize()
        } else {
            Button { store.stopSending() } label: {
                Label("停止发送", systemImage: "stop.fill")
            }
            .buttonStyle(.ink).controlSize(.large).fixedSize()
            .help("正在传的这本照常传完并校验，排队的书回到待发送（⌘.）")
        }
    }

    /// Saving is as common as sending, so it is a button of its own, not a menu item. No Kindle needed.
    private var secondaryButton: some View {
        Button { Task { await store.saveLocally() } } label: {
            Label("保存到本机", systemImage: "square.and.arrow.down")
        }
        .controlSize(.large).disabled(sendDisabled).fixedSize()
        .help(store.nothingToSendReason ?? "保存到本机（要翻译的书先翻译），完成后在访达中选中；不需要连接 Kindle（⌥⌘↩）")
    }

    /// Enabled whenever there is something new to queue, even while another queue runs.
    private var sendDisabled: Bool {
        store.queueable.isEmpty || (store.translationReady == false && store.plannedOriginals.isEmpty)
    }

    private var sendHelp: String {
        let names = store.targets.map(\.name).joined(separator: "、")
        return (names.isEmpty ? "" : "每本书都发给 \(names)。") + "原文直接发送，要翻译的书译完自动发送（⌘↩）"
    }

    private var sendButton: some View {
        Button { Task { await store.send() } } label: {
            HStack(spacing: 7) {
                Image(systemName: store.busy ? "plus" : "paperplane.fill")
                // Both queues running leaves little room: "+ 2" still says it, with the words in the tooltip.
                if !(store.translation.running && store.quick.running) {
                    Text(store.busy ? "加入队列" : store.targets.isEmpty ? "发送到 Kindle" : "发送到 \(store.targets.count) 台 Kindle")
                }
                if !store.queueable.isEmpty {
                    Text("\(store.queueable.count)").font(.callout.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.gray.opacity(0.35), in: Capsule())
                }
            }
            .padding(.horizontal, 6)
        }
        .controlSize(.large).fixedSize()
        .disabled(sendDisabled)
        .accessibilityLabel(store.busy ? "加入队列" : "发送到 Kindle")
        .help(store.nothingToSendReason ?? (store.busy ? "加入正在进行的队列（⌘↩）" : sendHelp))
    }
}

private struct NoticeBanner: View {
    @ObservedObject var store: PushStore
    var body: some View {
        let tint: Color = store.isError ? .orange : .green
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: store.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(store.notice).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !store.undoable.isEmpty {
                Button("撤销") { store.undoRemove() }.buttonStyle(.inkLink).font(.callout)
                    .keyboardShortcut("z", modifiers: .command)
            }
            if store.isError && !store.connected {
                Button("连接设置") { store.showConnection = true }.controlSize(.small)
            }
            Button { store.dismissNotice() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("关闭")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
