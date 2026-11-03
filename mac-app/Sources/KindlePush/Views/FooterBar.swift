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
                if store.busy && store.total > 0 { progress } else { modePicker }
                Spacer(minLength: 8)
                if store.currentJob != nil {
                    Button("停止") { store.stopTranslation() }.controlSize(.large)
                } else if !store.busy {
                    secondaryButton
                }
                sendButton
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("发送版本", selection: $store.translateBooks) {
                Text("原文").tag(false)
                Text("中英对照").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(store.busy)
            caption
        }
    }

    @ViewBuilder private var caption: some View {
        if !store.translateBooks {
            Label("本机排版，经 Wi‑Fi 直传，不经过云端", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        } else if store.translationReady == false {
            HStack(spacing: 4) {
                Label("还没安装翻译组件", systemImage: "exclamationmark.triangle")
                SettingsLink { Text("去设置") }.buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.orange)
        } else if store.nonEpubPending {
            Label("中英对照只支持 EPUB，请移除其他格式或切回原文", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label(store.translationProvider == "chatgpt" ? "仅 EPUB · 用 ChatGPT 套餐额度翻译" : "仅 EPUB · 正文发给翻译模型，按用量计费", systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: store.overallProgress).tint(.ink)
                .progressViewStyle(.linear).frame(maxWidth: 260)
            Text(store.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Work that stays on this Mac: no Kindle needed.
    @ViewBuilder private var secondaryButton: some View {
        if store.translateBooks {
            Menu("先试译 3 段") {
                Button("先试译 3 段") { Task { await store.preview() } }
                    .disabled(!store.previewAvailable)
                Divider()
                Button("翻译整本，只保存到本机") { Task { await store.saveLocally() } }
                    .disabled(sendDisabled)
            } primaryAction: { Task { await store.preview() } }
            .controlSize(.large).fixedSize()
            .disabled(!store.previewAvailable || store.translationReady == false)
            .help("只翻译 3 段正文给你检查，不发送。点箭头可翻译整本并只保存到本机（⌥⌘↩）")
        } else {
            Button("保存到本机") { Task { await store.saveLocally() } }
                .controlSize(.large).disabled(sendDisabled)
                .help("只转换排版，保存到本机，不需要 Kindle（⌥⌘↩）")
        }
    }

    private var sendDisabled: Bool {
        store.busy || store.pendingCount == 0
            || (store.translateBooks && (store.nonEpubPending || store.translationReady == false))
    }

    private var sendButton: some View {
        Button { Task { await store.send() } } label: {
            HStack(spacing: 7) {
                if store.busy { ProgressView().controlSize(.small).tint(Color.onInk) }
                else { Image(systemName: "paperplane.fill") }
                Text(store.busy ? "正在处理…" : store.translateBooks ? "翻译并发送" : "发送到 Kindle")
                if !store.busy && store.pendingCount > 0 {
                    Text("\(store.pendingCount)").font(.callout.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.onInk.opacity(0.2), in: Capsule())
                }
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.ink).controlSize(.large)
        .disabled(sendDisabled)
        .help("⌘↩")
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
