import SwiftUI
import AppKit
import Security
import CryptoKit

/// Translation keys in the Keychain, one per service address, the same entries the worker reads.
enum KeyVault {
    private static let service = "local.chase.KindlePush.translation"

    static func account(_ base: String) -> String {
        SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func query(_ base: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(base)]
    }

    static func read(_ base: String) -> String? {
        guard !base.isEmpty else { return nil }
        var item = query(base)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func write(_ key: String, for base: String) -> Bool {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query(base) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(base)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func remove(_ base: String) { SecItemDelete(query(base) as CFDictionary) }

    /// Enough to recognise a key without showing it: sk-…a3f9.
    static func mask(_ key: String) -> String {
        let tail = String(key.suffix(4))
        let head = key.hasPrefix("sk-") ? "sk-" : String(key.prefix(2))
        return key.count <= 8 ? String(repeating: "•", count: 6) : head + "…" + tail
    }
}

/// The brand mark when we have one, else the first letter on a tinted tile.
struct ProviderTile: View {
    let service: ModelService
    var size: CGFloat = 28

    private var image: NSImage? {
        ProviderIcons.svg[service.id].flatMap { NSImage(data: Data($0.utf8)) }.map { image in
            image.isTemplate = true
            return image
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size * 0.58, height: size * 0.58).foregroundStyle(Color.ink)
            } else {
                Text(String(t(service.name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A searchable wall of services, grouped like the catalogue. Shows which one is in use
/// and which already have a key, so switching back never means pasting it again.
struct ServicePicker: View {
    let current: String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func matches(_ service: ModelService) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || "\(t(service.name)) \(service.name) \(t(service.note)) \(service.id)".lowercased().contains(q)
    }

    private func hasKey(_ service: ModelService) -> Bool {
        service.needsKey && !service.base.isEmpty && KeyVault.read(service.base) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("选择翻译服务")).font(.headline)
                Spacer()
                Button(t("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            TextField(t("搜索服务"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ModelService.Group.allCases, id: \.self) { group in
                        let items = ProviderCatalog.all.filter { $0.group == group && matches($0) }
                        if !items.isEmpty {
                            Text(t(group.rawValue)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(items) { item in card(item) }
                            }
                        }
                    }
                    if ProviderCatalog.all.allSatisfy({ !matches($0) }) {
                        Text(t("没有找到这个服务。可以选「自定义服务」，填任何兼容 OpenAI 接口的地址。"))
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 520)
    }

    private func card(_ item: ModelService) -> some View {
        let inUse = item.id == current
        return Button {
            pick(item.id); dismiss()
        } label: {
            HStack(spacing: 10) {
                ProviderTile(service: item, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t(item.name)).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(hasKey(item) ? t("已保存 Key") : t(item.note))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if inUse { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.ink) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color.primary.opacity(inUse ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(inUse ? 0.28 : 0.08), lineWidth: inUse ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(item.name) + (inUse ? t("（正在使用）") : ""))
    }
}
