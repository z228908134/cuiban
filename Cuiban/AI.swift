import Foundation
import SwiftUI

// MARK: - 服务商预设

struct AIProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let applyHint: String

    static let all: [AIProvider] = [
        AIProvider(id: "deepseek", name: "DeepSeek",
                   baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                   applyHint: "platform.deepseek.com 申请 Key"),
        AIProvider(id: "zhipu", name: "智谱 GLM",
                   baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash",
                   applyHint: "bigmodel.cn 申请 Key，glm-4-flash 免费额度大"),
        AIProvider(id: "qwen", name: "通义千问",
                   baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
                   applyHint: "bailian.console.aliyun.com 申请 Key"),
        AIProvider(id: "kimi", name: "Kimi",
                   baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k",
                   applyHint: "platform.moonshot.cn 申请 Key"),
        AIProvider(id: "openai", name: "OpenAI",
                   baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
                   applyHint: "platform.openai.com 申请 Key"),
        AIProvider(id: "custom", name: "自定义（OpenAI 兼容）",
                   baseURL: "", model: "", applyHint: "任何兼容 /chat/completions 的服务")
    ]

    var isCustom: Bool { id == "custom" }
}

// MARK: - AI 配置

final class AIStore: ObservableObject {
    static let shared = AIStore()

    @Published var enabled: Bool { didSet { save() } }
    @Published var providerId: String { didSet { save() } }
    @Published var baseURL: String { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var apiKey: String { didSet { save() } }

    private let d = UserDefaults.standard

    private init() {
        enabled = d.bool(forKey: "ai.enabled")
        providerId = d.string(forKey: "ai.provider") ?? "deepseek"
        baseURL = d.string(forKey: "ai.base") ?? "https://api.deepseek.com/v1"
        model = d.string(forKey: "ai.model") ?? "deepseek-chat"
        apiKey = d.string(forKey: "ai.key") ?? ""
    }

    private func save() {
        d.set(enabled, forKey: "ai.enabled")
        d.set(providerId, forKey: "ai.provider")
        d.set(baseURL, forKey: "ai.base")
        d.set(model, forKey: "ai.model")
        d.set(apiKey, forKey: "ai.key")
    }

    var ready: Bool {
        enabled
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyPreset(_ p: AIProvider) {
        providerId = p.id
        if !p.isCustom {
            baseURL = p.baseURL
            model = p.model
        }
    }
}

// MARK: - AI 解析

enum AIService {

    enum AIError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String)
        case badFormat(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没配置 AI，去「设置 → AI 智能解析」里填 API Key"
            case .badURL: return "接口地址填得不对"
            case .http(let code, let msg):
                if code == 401 || code == 403 { return "API Key 不对或没权限（\(code)）" }
                return "接口返回 \(code)：\(msg)"
            case .badFormat(let s): return s
            }
        }
    }

    /// 把一段话交给 AI，解析出任务 / 时间 / 重复规则
    static func parse(text: String, now: Date = Date(),
                      completion: @escaping (Result<SmartParseResult, Error>) -> Void) {
        let cfg = AIStore.shared
        guard cfg.ready else {
            completion(.failure(AIError.notConfigured))
            return
        }

        var base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            completion(.failure(AIError.badURL))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                     forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": cfg.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt(now: now)],
                ["role": "user", "content": text]
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(AIError.badFormat("请求组装失败")))
            return
        }
        req.httpBody = payload

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(AIError.badFormat("没收到返回内容")))
                return
            }
            do {
                let content = try extractContent(data)
                let result = try buildResult(content: content, source: text)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// 只发一句「你好」验证配置是否可用
    static func test(completion: @escaping (Result<String, Error>) -> Void) {
        parse(text: "明天下午 3 点提醒我开会") { res in
            switch res {
            case .success(let r):
                completion(.success(r.summaryText()))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    // MARK: 内部

    private static func systemPrompt(now: Date) -> String {
        let stamp = fmt(now, "yyyy-MM-dd HH:mm")
        let week = fmt(now, "EEEE")
        return """
        你是任务解析助手。用户会给你一段文字，可能来自聊天记录、备忘录、通知，或者是截图 OCR 出来的乱文本。
        请把它转成一条提醒任务。

        当前时间：\(stamp) \(week)

        只输出一个 JSON 对象，不要 markdown 代码块，不要任何解释文字。字段如下：
        title：字符串，任务标题，不超过 20 个字，去掉表情和多余符号
        due：字符串，格式 "yyyy-MM-dd HH:mm"。能判断出具体日期就填；能判断日期但原文没给时间就填 09:00；完全判断不出日期就填空字符串 ""
        repeat："none" / "daily" / "weekly" / "weekday" / "monthly" 五选一
        weekdays：字符串数组。仅当 repeat 为 "weekly" 且原文指定了星期几时填写，用「一」「二」「三」「四」「五」「六」「日」，否则给空数组
        reason：字符串，一句话说明你的判断依据，中文

        规则提示：
        - 「明天」「下周一」「3 天后」这类都按当前时间往后算，due 必须是未来的日期
        - 「工作日」「周一到周五」→ repeat 用 "weekday"
        - 「每月 10 号」→ repeat 用 "monthly"，due 填最近的那个 10 号
        - 「每天」→ "daily"；「每周三」→ "weekly" + weekdays ["三"]
        - 原文没有提到任何时间信息时，due 填空字符串，repeat 用 "none"
        """
    }

    private static func extractContent(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badFormat("返回的不是 JSON")
        }
        if let errObj = obj["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            throw AIError.badFormat("接口报错：" + msg)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badFormat("返回里没有内容")
        }
        return content
    }

    private static func buildResult(content: String, source: String) throws -> SmartParseResult {
        guard let jsonText = extractJSONObject(content),
              let dict = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any] else {
            throw AIError.badFormat("AI 没按格式返回，换个说法再试试")
        }

        var r = SmartParseResult()
        r.sourceLabel = "AI"
        r.rawLines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let t = dict["title"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            r.titleSuggestion = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let due = dict["due"] as? String, !due.trimmingCharacters(in: .whitespaces).isEmpty {
            r.dueDate = parseDateTime(due)
            if let ev = r.dueDate {
                // AI 返回的是事件时间，提醒同样提前 5 分钟
                r.eventDate = ev
                r.dueDate = ev.addingTimeInterval(-300)
                r.tips.append("提醒时间已设为事件开始前 5 分钟")
            } else {
                r.tips.append("AI 给的时间「\(due)」没读懂，请手动确认")
            }
        }
        if let rep = dict["repeat"] as? String {
            r.repeatMode = RepeatMode(rawValue: rep.trimmingCharacters(in: .whitespaces).lowercased()) ?? RepeatMode.none
        }
        if let wds = dict["weekdays"] as? [String] {
            var out: [Int] = []
            for w in wds {
                if let n = weekdayNumber(w.trimmingCharacters(in: .whitespaces)), !out.contains(n) {
                    out.append(n)
                }
            }
            r.weekdays = out.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }
        }
        if let reason = dict["reason"] as? String, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            r.tips.append(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }

    private static func extractJSONObject(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }

    private static func parseDateTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        for p in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss",
                  "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH", "yyyy-MM-dd"] {
            f.dateFormat = p
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
