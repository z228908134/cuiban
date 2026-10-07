import Foundation
import UIKit

// MARK: - 备份数据结构

/// 备份文件里的全部内容（一个 .json 就是完整快照）
struct BackupPayload: Codable {
    var app: String = "cuiban"
    var appVersion: String = ""
    var exportedAt: Date = Date()
    var tasks: [TaskItem] = []
    var settings: AppSettings = AppSettings()
    /// 照片文件名 -> JPEG base64（关闭「包含照片」时为空字典）
    var photos: [String: String] = [:]
    /// 笔记（v1.4 起包含）
    var notes: [NoteItem]? = nil
    /// 卡片备份（v1.6.14 起包含）
    var cards: [CardItem]? = nil
}

/// 一份本地备份的条目（设置页展示用）
struct BackupEntry: Identifiable {
    let id: URL
    let url: URL
    let date: Date
    let sizeText: String
    let title: String
}

// MARK: - 备份中心

enum BackupStore {

    /// 本地自动备份保留的份数
    static let keepDefault = 10
    /// 自动备份节流：10 分钟内的多次改动合并为一份
    static let autoThrottle: TimeInterval = 10 * 60

    private static var lastAutoAt: Date {
        get { UserDefaults.standard.object(forKey: "backup.lastAutoAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "backup.lastAutoAt") }
    }

    /// 上一次成功导出到「文件 / iCloud 云盘」的时间
    static var lastExportAt: Date? {
        get { UserDefaults.standard.object(forKey: "backup.lastExportAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "backup.lastExportAt") }
    }

    static var backupsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: 自动备份

    /// 数据变更后由 TaskStore.save() 调用；有节流，实际写盘放后台线程
    static func autoBackupIfNeeded(tasks: [TaskItem], settings: AppSettings) {
        guard settings.autoBackup else { return }
        guard Date().timeIntervalSince(lastAutoAt) >= autoThrottle else { return }
        lastAutoAt = Date()
        let t = tasks
        let s = settings
        DispatchQueue.global(qos: .utility).async {
            _ = writeBackup(tasks: t, settings: s, tag: "自动", keep: keepDefault)
        }
    }

    // MARK: 写备份

    /// 写一份本地备份，并按 keep 修剪旧的
    @discardableResult
    static func writeBackup(tasks: [TaskItem], settings: AppSettings,
                            tag: String, keep: Int = keepDefault) -> URL? {
        let payload = buildPayload(tasks: tasks, settings: settings)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload) else { return nil }
        let url = backupsDir.appendingPathComponent("催办备份-\(stamp(Date()))-\(tag).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        if keep > 0 { prune(keep: keep) }
        return url
    }

    /// 生成用于导出到「文件 / iCloud 云盘」的临时文件（不占本地备份份数）
    static func makeExportFile(tasks: [TaskItem], settings: AppSettings) -> URL? {
        let payload = buildPayload(tasks: tasks, settings: settings)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("催办备份-\(stamp(Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func buildPayload(tasks: [TaskItem], settings: AppSettings) -> BackupPayload {
        var payload = BackupPayload()
        payload.appVersion = appVersion
        payload.exportedAt = Date()
        payload.tasks = tasks
        payload.settings = settings
        if settings.backupIncludePhotos {
            var photos: [String: String] = [:]
            let names = Set(tasks.flatMap { $0.photos })
                .union(CardStore.shared.cards.flatMap { $0.photos })
                .union(NoteStore.shared.notes.flatMap { $0.photos })
            for n in names {
                if let data = try? Data(contentsOf: AttachmentStore.url(n)) {
                    photos[n] = data.base64EncodedString()
                }
            }
            payload.photos = photos
        }
        payload.notes = NoteStore.shared.notes
        payload.cards = CardStore.shared.cards
        return payload
    }

    // MARK: 读取与恢复

    static func readPayload(at url: URL) -> BackupPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BackupPayload.self, from: data)
    }

    /// 执行恢复（必须在主线程调用）；返回给用户看的说明
    static func restore(payload: BackupPayload) -> String {
        var restoredPhotos = 0
        for (name, b64) in payload.photos {
            let dest = AttachmentStore.url(name)
            guard !FileManager.default.fileExists(atPath: dest.path),
                  let data = Data(base64Encoded: b64) else { continue }
            if (try? data.write(to: dest, options: .atomic)) != nil {
                restoredPhotos += 1
            }
        }
        TaskStore.shared.replaceAll(tasks: payload.tasks, settings: payload.settings)
        if let ns = payload.notes {
            NoteStore.shared.replaceAll(ns)
        }
        if let cs = payload.cards {
            CardStore.shared.replaceAll(cs)
        }
        var s = "已恢复 \(payload.tasks.count) 个任务"
        if let ns = payload.notes, !ns.isEmpty { s += "、\(ns.count) 条笔记" }
        if let cs = payload.cards, !cs.isEmpty { s += "、\(cs.count) 张卡片" }
        if restoredPhotos > 0 { s += "、\(restoredPhotos) 张照片" }
        if payload.tasks.isEmpty { s += "（备份里没有任务，相当于清空）" }
        return s
    }

    // MARK: 列表与清理

    static func listBackups() -> [BackupEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupsDir.path) else { return [] }
        var out: [BackupEntry] = []
        for n in names where n.hasPrefix("催办备份-") && n.hasSuffix(".json") {
            let url = backupsDir.appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(BackupEntry(id: url, url: url, date: date,
                                   sizeText: sizeText(size), title: n))
        }
        return out.sorted { $0.date > $1.date }
    }

    static func prune(keep: Int) {
        let entries = listBackups()
        guard entries.count > keep else { return }
        for e in entries.suffix(entries.count - keep) {
            try? FileManager.default.removeItem(at: e.url)
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: d)
    }
}
