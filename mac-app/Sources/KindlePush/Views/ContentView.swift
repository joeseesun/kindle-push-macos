import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: PushStore
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把文章，留给慢读。")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("从 Mac 到 Kindle，拖进来就好。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 5) {
                    Image(systemName: "paperplane").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ConnectionView(store: store)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("发送版本", selection: $store.translateBooks) {
                        Text("直接发送").tag(false)
                        Text("中文对照版").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().disabled(store.busy)
                    Button { store.showTranslationSettings = true } label: {
                        Image(systemName: "gearshape").font(.body)
                    }.buttonStyle(.borderless).help("翻译设置").accessibilityLabel("翻译设置").disabled(store.busy)
                }
                if store.translateBooks {
                    HStack(alignment: .top, spacing: 12) {
                        Text("EPUB 原文与中文逐段对照\n正文会发送给所选模型服务，按 API 用量计费；原书保留。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("先试译 3 段") { Task { await store.preview() } }
                            .disabled(store.busy || !store.previewAvailable)
                    }
                }
            }
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                Text("拖入 Markdown 或 EPUB").fontWeight(.medium)
                HStack(spacing: 6) {
                    Text("支持多篇文章，自动转换排版").foregroundStyle(.secondary)
                    Button("选择文件…") { store.showPicker = true }.buttonStyle(.link).disabled(store.busy)
                }.font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .dropDestination(for: URL.self) { urls, _ in
                guard !store.busy else { return false }; store.add(urls); return true
            } isTargeted: { targeted = $0 }
            HStack {
                Text("文章列表").fontWeight(.semibold)
                Text("\(store.articles.count)").foregroundStyle(.secondary)
                Spacer()
                if store.articles.contains(where: { $0.status == "已发送" }) {
                    Button("清除已发送") { store.clearSent() }.buttonStyle(.link).font(.caption).disabled(store.busy)
                }
            }
            if store.articles.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有文章").foregroundStyle(.secondary)
                    Text("原文留在原位置，发送后的文章在 Kindle「我的文章」里。")
                        .font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.articles) { article in
                            ArticleRow(article: article, store: store)
                            Divider()
                        }
                    }
                }.frame(minHeight: 100)
            }
            if !store.notice.isEmpty {
                Label(store.notice, systemImage: store.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(store.isError ? Color.orange : Color.green)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 12) {
                if store.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.busy ? store.activity : store.translateBooks ? "翻译为中文对照版，再通过 Wi-Fi 发送" : "只在本地转换，通过 Wi-Fi 传输")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("查看已转换文件") { store.revealOutput() }.buttonStyle(.link).font(.caption)
                }
                Spacer(minLength: 10)
                if store.currentJob != nil {
                    Button("停止翻译") { store.stopTranslation() }
                }
                Button { Task { await store.send() } } label: {
                    Label(store.busy ? "请稍候…" : "\(store.translateBooks ? "翻译并发送" : "发送到 Kindle")\(store.pendingCount > 0 ? " · \(store.pendingCount)" : "")", systemImage: "paperplane.fill")
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(store.busy || store.pendingCount == 0)
            }
        }
        .padding(26).frame(minWidth: 560, minHeight: 660)
        .sheet(isPresented: $store.showTranslationSettings) { TranslationSettingsView(store: store) }
        .fileImporter(isPresented: $store.showPicker,
                      allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText,
                                            UTType(filenameExtension: "markdown") ?? .plainText,
                                            UTType(filenameExtension: "epub") ?? .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): store.add(urls)
            case .failure(let error): store.notice = error.localizedDescription; store.isError = true
            }
        }
        .task { await store.start() }
        .onOpenURL { store.add([$0]) }
    }
}
