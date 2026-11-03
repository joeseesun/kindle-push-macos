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
            Picker("版本", selection: $store.outputMode) {
                ForEach(OutputMode.allCases, id: \.self) { Text($0.title).tag($0) }
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
                SettingsLink { Text("去设置") }.buttonStyle(.inkLink)
            }
            .font(.caption).foregroundStyle(.orange)
        } else if store.nonEpubPending {
            Label("翻译只支持 EPUB，请移除其他格式或切回原文", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            HStack(spacing: 6) {
                Label(store.translationProvider == "chatgpt" ? "用 ChatGPT 套餐额度翻译" : "正文发给翻译模型，按用量计费", systemImage: "globe")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                // A one-off check before a long run: a link, not a third button.
                Button("先试译 3 段") { Task { await store.preview() } }
                    .buttonStyle(.inkLink).disabled(store.busy || !store.previewAvailable)
                    .help("只翻译 3 段正文，在访达里打开给你检查；不发送")
            }
            .font(.caption).fixedSize()
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: store.overallProgress).tint(.ink)
                .progressViewStyle(.linear).frame(maxWidth: 260)
            Text(store.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Saving is as common as sending, so it is a button of its own, not a menu item. No Kindle needed.
    private var secondaryButton: some View {
        Button { Task { await store.saveLocally() } } label: {
            Label(store.translateBooks ? "翻译并保存" : "保存到本机", systemImage: "square.and.arrow.down")
        }
        .controlSize(.large).disabled(sendDisabled)
        .help("保存到本机，完成后在访达中选中；不需要连接 Kindle（⌥⌘↩）")
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
