import Foundation

// MARK: - 笔记模型

struct NoteItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    /// 附在笔记上的照片（AttachmentsStore 里的文件名）
    var photos: [String] = []
    /// 富文本样式片段 JSON（NoteStyle 数组：加粗/斜体/下划线/删除线/高亮/等宽）
    var styleData: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 有标题就用标题，没标题就拿正文里第一条「有意义的行」当标题。
    /// 过滤掉勾选框标记行、纯 URL 行、纯日期行——这些当标题看着像乱码。
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let lines = NoteSummary.meaningfulLines(body)
        return lines.first.map { String($0.prefix(24)) } ?? "无标题"
    }

    /// 摘要：只取正文里有意义的行，最多两行，不再把整段压成一行。
    /// 有标题时正文全部可用；无标题时第一行已被当作标题，摘要从第二行起，避免重复。
    var snippet: String {
        var lines = NoteSummary.meaningfulLines(body)
        guard !lines.isEmpty else { return "（正文为空）" }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines = Array(lines.dropFirst())
            if lines.isEmpty { return "（无更多内容）" }
        }
        return String(lines.prefix(2).joined(separator: " ").prefix(80))
    }
}

// MARK: - 笔记摘要挑选

/// 从笔记正文里挑出「值得显示在列表上」的行。
/// 之前是把整段正文的换行全替换成空格，结果勾选框标记、日期、URL 全挤在一行像乱码。
enum NoteSummary {
    /// 勾选框标记字符（显示层已转成 ☐ / ☑，这里直接按字符判断）
    private static let marks: Set<Character> = ["\u{2610}", "\u{2611}", "\u{2612}", "\u{2B1C}"]

    /// 去掉行首的勾选框标记，保留正文
    private static func stripMark(_ line: String) -> String {
        var s = Substring(line)
        while let first = s.first {
            if first == " " || first == "\t" { s = s.dropFirst() }
            else if marks.contains(first) { s = s.dropFirst() }
            else { break }
        }
        return String(s).trimmingCharacters(in: .whitespaces)
    }

    /// 这一行是不是纯链接（http/https 开头且没别的实质内容）
    private static func isBareURL(_ s: String) -> Bool {
        let low = s.lowercased()
        guard low.hasPrefix("http://") || low.hasPrefix("https://")
                || low.hasPrefix("www.") else { return false }
        // 去掉链接本身后如果还剩实质文字，就不算纯链接
        let rest = s.replacingOccurrences(
            of: #"https?://[^\s]+|www\.[^\s]+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty
    }

    /// 这一行是不是纯日期 / 时间（例：10月7日 09:11、2026-10-07 09:11:22、2026年10月7日 星期三）
    ///
    /// 不用正则逐字符匹配：`星期` / `礼拜` 在 Swift 里是**多个字素簇**（一整个汉字），
    /// 正则的字符类会按 unicode scalar 处理，很容易漏判。改成「逐个 token 判断」更稳。
    private static func isBareDate(_ s: String) -> Bool {
        // 允许出现的词与符号：数字、数字汉字（星期三里的「三」）、年月日时分秒、
        // 星期/周、上午下午、日期分隔符
        let allowedWords = ["年", "月", "日", "号", "点", "时", "分", "秒",
                            "星期", "礼拜", "周",
                            "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
                            "上午", "下午", "晚上", "凌晨"]
        var rest = s
        for w in allowedWords {
            rest = rest.replacingOccurrences(of: w, with: "")
        }
        // 剩下的只允许数字和日期分隔符出现
        let okChars = Set("0123456789 -/:.、,，")
        let leftovers = rest.filter { !okChars.contains($0) }
        // 至少要有一个数字，否则「月月」之类不算日期
        return leftovers.isEmpty && rest.contains(where: { $0.isNumber })
    }

    /// 笔记正文 → 有意义的行（已剥掉勾选框标记、滤掉纯 URL / 纯日期 / 空行）
    static func meaningfulLines(_ body: String) -> [String] {
        TextEditBridge.displayFriendly(body)
            .components(separatedBy: .newlines)
            .map { stripMark($0) }
            .filter { !$0.isEmpty }
            .filter { !isBareURL($0) && !isBareDate($0) }
    }
}

// MARK: - 笔记仓库

final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [NoteItem] = []

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("cuiban_notes.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([NoteItem].self, from: data) {
            // 旧版本勾选框写法（私有区字符 / ⬜️/✅/- [ ]）迁移成新标记并落盘
            notes = list.map { n in
                var m = n
                m.body = TextEditBridge.migrate(m.body)
                return m
            }
            save()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(notes) { try? d.write(to: file) }
    }

    var sorted: [NoteItem] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func note(id: String) -> NoteItem? {
        notes.first { $0.id == id }
    }

    func upsert(_ note: NoteItem) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.append(note)
        }
        save()
    }

    func delete(ids: [String]) {
        let gone = notes.filter { ids.contains($0.id) }.flatMap { $0.photos }
        if !gone.isEmpty {
            AttachmentStore.delete(gone)
        }
        notes.removeAll { ids.contains($0.id) }
        save()
    }

    /// 备份恢复：整体替换（不再被引用的照片会被清掉）
    func replaceAll(_ list: [NoteItem]) {
        let old = Set(notes.flatMap { $0.photos })
        let new = Set(list.flatMap { $0.photos })
        let gone = old.subtracting(new)
        if !gone.isEmpty {
            AttachmentStore.delete(Array(gone))
        }
        notes = list
        save()
    }
}

// MARK: - 笔记模板

struct NoteTemplate: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var body: String
}

final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published var templates: [NoteTemplate] = []

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("cuiban_note_templates.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([NoteTemplate].self, from: data) {
            templates = list
        } else {
            templates = TemplateStore.builtin
            save()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(templates) { try? d.write(to: file) }
    }

    func upsert(_ t: NoteTemplate) {
        if let i = templates.firstIndex(where: { $0.id == t.id }) {
            templates[i] = t
        } else {
            templates.append(t)
        }
        save()
    }

    func delete(_ id: String) {
        templates.removeAll { $0.id == id }
        save()
    }

    /// 内置模板（首次启动写入，之后可随意改删）
    static let builtin: [NoteTemplate] = [
        NoteTemplate(
            name: "会议纪要",
            body: "主题：\n时间：\n参会人：\n\n会议目标：\n\n预期成果与关键节点：\n\n会议记录整理：\n\n会后通知：\n"
        ),
        NoteTemplate(
            name: "每周工作总结",
            body: "本周工作总结及完成度：\n\n本周最有成就感的事情：\n\n本周遇到的工作上的阻碍：\n\n总结与反思：\n"
        ),
        NoteTemplate(
            name: "阅读笔记",
            body: "书名：\n作者：\n\n灵感摘要：\n\n读后感悟：\n"
        ),
        NoteTemplate(
            name: "月刷卡任务",
            body: "⬜️ 广发华为为 card 刷 1 万得 100 元\n⬜️ 广发 oppo card 刷 2 万返现 100 元\n⬜️ 广发车主卡刷 5000 任惠荟逛非加油类积分返现 50 元\n"
        ),
        NoteTemplate(
            name: "每日待办",
            body: "⬜️ \n⬜️ \n⬜️ \n"
        )
    ]
}
