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

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = TextEditBridge.displayFriendly(body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        return firstLine.isEmpty ? "无标题" : String(firstLine.prefix(20))
    }

    var snippet: String {
        let b = TextEditBridge.displayFriendly(body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return "（正文为空）" }
        return b.replacingOccurrences(of: "\n", with: " ")
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
