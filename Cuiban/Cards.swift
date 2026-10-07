import SwiftUI
import UIKit

// MARK: - 卡片类型

/// 卡片类型（参考卡片备份的分类）
enum CardType: String, Codable, CaseIterable, Identifiable, Equatable {
    case debit = "储蓄卡"
    case credit = "信用卡"
    case passbook = "银行存折"
    case brokerage = "证券账户"
    case other = "其它"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - 卡片模型

/// 一张备份卡片：银行 / 卡号 / 户主 / 备注 / 图片
struct CardItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var type: CardType = .debit
    /// 开户行（浦发、工行…）
    var bank: String = ""
    /// 卡号（只存数字，展示时分组）
    var number: String = ""
    /// 户主（非必填）
    var holder: String = ""
    /// 备注（非必填）
    var note: String = ""
    /// 图片（存 Documents/attachments 下的文件名）
    var photos: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 卡号每 4 位一组，空格分隔
    var numberGrouped: String {
        let digits = number.filter { $0.isNumber }
        guard !digits.isEmpty else { return number }
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, i % 4 == 0 { out += " " }
            out.append(c)
        }
        return out
    }

    /// 列表副标题：类型 银行 备注
    var subtitle: String {
        var parts: [String] = [type.label]
        if !bank.isEmpty { parts.append(bank) }
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " ")
    }

    /// 编辑页的「图片」入口标题
    var photoEntryText: String {
        photos.isEmpty ? "图片" : "图片 · \(photos.count) 张"
    }

    var displayName: String {
        if !bank.isEmpty { return bank }
        if !number.isEmpty { return numberGrouped }
        return "未命名卡片"
    }

    /// 「复制全部」的内容：一眼能贴给别人的完整信息
    var copyAllText: String {
        var lines: [String] = []
        lines.append("\(type.label) · \(bank.isEmpty ? "未填银行" : bank)")
        if !number.isEmpty { lines.append("卡号 " + numberGrouped) }
        if !holder.isEmpty { lines.append("户主 " + holder) }
        if !note.isEmpty { lines.append("备注 " + note) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 卡片仓库

final class CardStore: ObservableObject {
    static let shared = CardStore()

    @Published var cards: [CardItem] = []

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("cuiban_cards.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([CardItem].self, from: data) {
            cards = list
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(cards) { try? d.write(to: file, options: .atomic) }
    }

    /// 筛选后的卡片（type = nil 表示全部）
    func filtered(_ type: CardType?, keyword: String = "") -> [CardItem] {
        var list = cards
        if let t = type {
            list = list.filter { $0.type == t }
        }
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            list = list.filter {
                $0.bank.contains(kw) || $0.number.contains(kw) || $0.holder.contains(kw)
                    || $0.note.contains(kw)
            }
        }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    func count(_ type: CardType?) -> Int {
        guard let t = type else { return cards.count }
        return cards.filter { $0.type == t }.count
    }

    func upsert(_ c: CardItem) {
        var v = c
        v.updatedAt = Date()
        if let i = cards.firstIndex(where: { $0.id == v.id }) {
            cards[i] = v
        } else {
            cards.insert(v, at: 0)
        }
        save()
    }

    func delete(id: String) {
        if let c = cards.first(where: { $0.id == id }), !c.photos.isEmpty {
            AttachmentStore.delete(c.photos)
        }
        cards.removeAll { $0.id == id }
        save()
    }

    /// 备份恢复：整体替换（不再被引用的图片清掉）
    func replaceAll(_ list: [CardItem]) {
        let old = Set(cards.flatMap { $0.photos })
        let new = Set(list.flatMap { $0.photos })
        let gone = old.subtracting(new)
        if !gone.isEmpty { AttachmentStore.delete(Array(gone)) }
        cards = list
        save()
    }
}
