import SwiftUI

/// Preview clean names for the original files, edit any of them, then rename on disk.
struct RenameSheet: View {
    @ObservedObject var store: PushStore
    let ids: [UUID]
    @AppStorage("renameSmart") private var smart = true
    @AppStorage("renameWithAuthor") private var withAuthor = false
    @State private var names: [UUID: String] = [:]
    @State private var chosen: Set<UUID> = []
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    private var items: [Article] { ids.compactMap { id in store.articles.first { $0.id == id } } }
    private var changes: [UUID: String] {
        names.filter { chosen.contains($0.key) && isChanged($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("整理文件名").font(.title2.weight(.semibold))
                Text("去掉 z-library 等来源标记、杂乱分隔符和版本年份后缀。只改文件名，书的内容不变。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            HStack(spacing: 14) {
                Picker("书名提取方式", selection: $smart) {
                    Text("智能精简").tag(true)
                    Text("保守清理").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("加上作者", isOn: $withAuthor).toggleStyle(.checkbox)
                Spacer()
            }
            Text(smart ? "只留主书名：去掉副标题，以及书名后括号里的作者、出版社等说明。" : "保留副标题，只去掉来源标记、多余符号和版本后缀。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { article in
                        row(article)
                        if article.id != items.last?.id { Divider().padding(.leading, 76) }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 360)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            .overlay { if loading { ProgressView().controlSize(.small) } }

            HStack(spacing: 10) {
                Text("根据书里的书名和文件名推断，难免出错，确认后再重命名。")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(changes.isEmpty ? "重命名" : "重命名 \(changes.count) 个文件") { apply() }
                    .buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(changes.isEmpty)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 600)
        .tint(.ink)
        .task(id: "\(smart)\(withAuthor)") { await suggest() }
    }

    private func row(_ article: Article) -> some View {
        let suffix = "." + Article.fileExtension(of: article.path)
        let changed = isChanged(article.id)
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { chosen.contains(article.id) },
                                     set: { if $0 { chosen.insert(article.id) } else { chosen.remove(article.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!changed)
            BookCover(article: article).scaleEffect(0.62).frame(width: 34, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: article.path).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(article.path)
                HStack(spacing: 2) {
                    TextField("文件名", text: Binding(get: { names[article.id] ?? "" },
                                                    set: { names[article.id] = $0; chosen.insert(article.id) }))
                        .textFieldStyle(.plain).font(.body.weight(.medium))
                    Text(suffix).font(.body).foregroundStyle(.tertiary)
                }
            }
            if !changed && !loading {
                Text("已经很干净").font(.caption).foregroundStyle(.tertiary).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(changed || loading ? 1 : 0.6)
    }

    private func stem(of article: Article) -> String {
        let name = URL(fileURLWithPath: article.path).lastPathComponent
        return String(name.dropLast(Article.fileExtension(of: name).count + 1))
    }

    private func isChanged(_ id: UUID) -> Bool {
        guard let article = items.first(where: { $0.id == id }),
              let name = names[id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return false }
        return name != stem(of: article)
    }

    private func suggest() async {
        loading = true
        let request: [String: Any] = [
            "smart": smart, "author": withAuthor,
            "items": items.map { ["path": $0.path, "title": $0.bookTitle ?? "", "author": $0.author ?? ""] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let suggested = await Bridge.call(["tidy-names"], input: String(decoding: data, as: UTF8.self)).names,
              suggested.count == items.count else { loading = false; return }
        for (article, name) in zip(items, suggested) {
            let suffix = "." + Article.fileExtension(of: article.path)
            names[article.id] = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        }
        chosen = Set(items.map(\.id).filter(isChanged))
        loading = false
    }

    private func apply() {
        let count = changes.count
        let failed = store.rename(changes)
        if failed.isEmpty {
            store.notice = "已重命名 \(count) 个文件。"; store.isError = false
        } else {
            store.notice = "\(failed.count) 个文件没能重命名（可能已被移动或没有权限）：\(failed.joined(separator: "、"))"
            store.isError = true
        }
        dismiss()
    }
}
