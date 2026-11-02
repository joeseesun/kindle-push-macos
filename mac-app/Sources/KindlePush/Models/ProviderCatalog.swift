import Foundation

/// Translation services, after qiaomu-clipper's catalogue. All but ChatGPT speak the OpenAI chat API.
struct ModelService: Identifiable, Hashable {
    enum Group: String, CaseIterable { case account = "用账号登录", relay = "中转平台", vendor = "模型厂商", local = "本机", custom = "其他" }
    enum SignIn { case none, chatgpt, key }

    let id: String
    let name: String
    let group: Group
    let note: String
    let base: String
    var keyURL: String? = nil
    var signIn: SignIn = .none
    var needsKey = true
    var popular: [String] = []

    var hostLabel: String { URL(string: base)?.host ?? note }
}

enum ProviderCatalog {
    static let all: [ModelService] = [
        ModelService(id: "chatgpt", name: "ChatGPT", group: .account, note: "用 ChatGPT 套餐额度，不按 API 计费",
                     base: "", signIn: .chatgpt, needsKey: false),

        ModelService(id: "tokendance", name: "词元跳动", group: .relay, note: "一个 Key 用所有模型",
                     base: "https://tokendance.space/gateway/v1", keyURL: "https://tokendance.space/keys", signIn: .key,
                     popular: ["deepseek-v4-flash", "qwen3.8-flash", "kimi-k3"]),
        ModelService(id: "openrouter", name: "OpenRouter", group: .relay, note: "openrouter.ai",
                     base: "https://openrouter.ai/api/v1", keyURL: "https://openrouter.ai/settings/keys", signIn: .key),
        ModelService(id: "siliconflow", name: "硅基流动", group: .relay, note: "api.siliconflow.cn",
                     base: "https://api.siliconflow.cn/v1", keyURL: "https://cloud.siliconflow.cn/account/ak"),

        ModelService(id: "deepseek", name: "DeepSeek", group: .vendor, note: "api.deepseek.com",
                     base: "https://api.deepseek.com/v1", keyURL: "https://platform.deepseek.com/api_keys",
                     popular: ["deepseek-flash", "deepseek-v4-pro"]),
        ModelService(id: "openai", name: "OpenAI", group: .vendor, note: "api.openai.com",
                     base: "https://api.openai.com/v1", keyURL: "https://platform.openai.com/api-keys"),
        ModelService(id: "gemini", name: "Google Gemini", group: .vendor, note: "Gemini API",
                     base: "https://generativelanguage.googleapis.com/v1beta/openai", keyURL: "https://aistudio.google.com/app/apikey"),
        ModelService(id: "moonshot", name: "Kimi", group: .vendor, note: "api.moonshot.cn",
                     base: "https://api.moonshot.cn/v1", keyURL: "https://platform.moonshot.cn/console/api-keys"),
        ModelService(id: "zhipu", name: "智谱 GLM", group: .vendor, note: "open.bigmodel.cn",
                     base: "https://open.bigmodel.cn/api/paas/v4", keyURL: "https://open.bigmodel.cn/usercenter/apikeys"),
        ModelService(id: "qwen", name: "通义千问", group: .vendor, note: "阿里云百炼",
                     base: "https://dashscope.aliyuncs.com/compatible-mode/v1", keyURL: "https://bailian.console.aliyun.com/?apiKey=1"),
        ModelService(id: "doubao", name: "豆包", group: .vendor, note: "火山方舟",
                     base: "https://ark.cn-beijing.volces.com/api/v3", keyURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"),

        ModelService(id: "ollama", name: "Ollama", group: .local, note: "本机模型，不联网",
                     base: "http://127.0.0.1:11434/v1", needsKey: false),
        ModelService(id: "lmstudio", name: "LM Studio", group: .local, note: "本机 :1234",
                     base: "http://127.0.0.1:1234/v1", needsKey: false),

        ModelService(id: "custom", name: "自定义服务", group: .custom, note: "任何兼容 OpenAI 接口的地址", base: ""),
    ]

    static func service(_ id: String) -> ModelService? { all.first { $0.id == id } }

    /// A saved configuration's service: by id, else by address, else custom.
    static func match(provider: String, base: String) -> ModelService {
        if let found = service(provider) { return found }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return all.first { !$0.base.isEmpty && $0.base == trimmed } ?? service("custom")!
    }
}
