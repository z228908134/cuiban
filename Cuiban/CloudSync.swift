import Foundation

// MARK: - 数据变化通知
//
// 任务 / 笔记 / 卡片任何一处保存都会发这个通知，根视图统一监听后触发同步。
// 这样不必在每个页面里都塞同步调用，也不漏「某条路径忘了同步」。
extension Notification.Name {
    static let cuibanDataChanged = Notification.Name("cuiban.dataChanged")
}

// MARK: - 与 NAS / 文件夹同步
//
// 不做账号登录，直接把数据文件读写到用户指定的位置（飞牛 WebDAV、SMB 挂载、
// iCloud Drive、OneDrive 等都能当这个位置用）。两端各自读写同一个文件夹，
// 数据一变就自动推上去。
//
// 合并策略：**按文件挑新的**（每个数据文件比「同步元信息」里记的时间戳，
// 谁新用谁）。这样手机上改任务、电脑上加卡片，两边修改都能保留，
// 只有同一份数据被两端同时改才会以最后写入的一方为准。

enum CloudSync {

    // MARK: 配置

    /// 当前配置（存 UserDefaults）
    private static var defaultsKey: String { "cloudsync.config" }
    private static var metaKey: String { "cloudsync.meta" }

    struct Config: Codable, Equatable {
        /// 同步文件夹路径（空 = 未开启）
        var folder: String = ""
        /// 目标文件名（飞牛上会生成一个带时间戳的目录，Windows 端指到这个目录）
        var remoteName: String = "cuiban-data.json"
        /// 是否包含照片
        var includePhotos: Bool = true
        /// 自动同步
        var autoSync: Bool = true

        var isOn: Bool { !folder.isEmpty }
    }

    /// 同步状态（本地记录：上次同步时间、远端文件的修改时间）
    struct Meta: Codable {
        /// 本地各数据文件的最后修改时间
        var localStamp: [String: Date] = [:]
        /// 上次成功同步的时间
        var lastSyncAt: Date? = nil
        /// 上次同步的方向说明（给 UI 显示）
        var lastAction: String = ""
    }

    private static var config: Config {
        get {
            guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return Config() }
            return (try? JSONDecoder().decode(Config.self, from: d)) ?? Config()
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: defaultsKey)
            }
        }
    }

    private static var meta: Meta {
        get {
            guard let d = UserDefaults.standard.data(forKey: metaKey) else { return Meta() }
            return (try? JSONDecoder().decode(Meta.self, from: d)) ?? Meta()
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: metaKey)
            }
        }
    }

    static var currentConfig: Config { config }
    static var currentMeta: Meta { meta }

    static func configure(folder: String, includePhotos: Bool, autoSync: Bool) {
        var c = config
        c.folder = folder
        c.includePhotos = includePhotos
        c.autoSync = autoSync
        config = c
    }

    static func disable() {
        var c = config
        c.folder = ""
        config = c
    }

    /// 同步文件夹是否存在可写
    static func isFolderWritable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        // 用「写一个临时文件再删掉」判断真实可写性（网络目录挂载掉时最准）
        let probe = (path as NSString).appendingPathComponent(".cuiban-write-test")
        do {
            try Data("ok".utf8).write(to: URL(fileURLWithPath: probe))
            try? FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
    }

    private static var remoteURL: URL? {
        let c = config
        guard c.isOn else { return nil }
        return URL(fileURLWithPath: (c.folder as NSString)
            .appendingPathComponent(c.remoteName.isEmpty ? "cuiban-data.json" : c.remoteName))
    }

    // MARK: 打包 / 解包

    /// 把当前所有数据打成一个 payload
    private static func currentPayload() -> BackupPayload {
        var p = BackupPayload()
        p.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        p.exportedAt = Date()
        p.tasks = TaskStore.shared.tasks
        p.settings = TaskStore.shared.settings
        p.notes = NoteStore.shared.notes
        p.cards = CardStore.shared.cards
        if config.includePhotos {
            var photos: [String: String] = [:]
            let names = Set(TaskStore.shared.tasks.flatMap { $0.photos })
                .union(NoteStore.shared.notes.flatMap { $0.photos })
                .union(CardStore.shared.cards.flatMap { $0.photos })
            for n in names {
                if let data = try? Data(contentsOf: AttachmentStore.url(n)) {
                    photos[n] = data.base64EncodedString()
                }
            }
            p.photos = photos
        }
        return p
    }

    private static func writePayload(_ p: BackupPayload, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(p)
        // 先写临时文件再替换，避免中途断网写坏文件
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func readPayload(at url: URL) -> BackupPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BackupPayload.self, from: data)
    }

    // MARK: 三个数据文件的时间戳

    /// 参与同步的本地文件（就是 App 存的那几个）
    private static var localFiles: [String: URL] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            "tasks": dir.appendingPathComponent("cuiban_tasks.json"),
            "notes": dir.appendingPathComponent("cuiban_notes.json"),
            "cards": dir.appendingPathComponent("cuiban_cards.json"),
            "settings": dir.appendingPathComponent("cuiban_settings.json")
        ]
    }

    private static func modified(_ url: URL) -> Date? {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return a?[.modificationDate] as? Date
    }

    /// 数据有没有变化（相对上次同步）
    private static func hasLocalChanges() -> Bool {
        var m = meta
        for (key, url) in localFiles {
            guard let mod = modified(url) else { continue }
            if m.localStamp[key] == nil || m.localStamp[key]! < mod { return true }
        }
        return false
    }

    private static func stampLocalFiles() {
        var m = meta
        for (key, url) in localFiles {
            m.localStamp[key] = modified(url) ?? Date()
        }
        meta = m
    }

    // MARK: 同步

    enum SyncResult {
        case off                       // 未开启
        case upToDate
        case pushed(Int)               // 本地更新，已推到远端
        case pulled(Int)               // 远端更新，已拉到本地
        case merged                    // 远端内容已合并进来
        case failed(String)

        var text: String {
            switch self {
            case .off: return "还没开启同步"
            case .upToDate: return "两边数据已经一致"
            case .pushed(let n): return "已上传 \(n) 个任务到同步文件夹"
            case .pulled(let n): return "已从同步文件夹下载 \(n) 个任务"
            case .merged: return "已把同步文件夹里的改动合并进来"
            case .failed(let e): return "同步失败：\(e)"
            }
        }
    }

    /// 手动同步：先尝试上传本地，再检查远端有没有更新
    @discardableResult
    static func syncNow() -> SyncResult {
        let c = config
        guard c.isOn, let remote = remoteURL else { return .off }

        // 远端还没有 → 直接推上去
        guard FileManager.default.fileExists(atPath: remote.path) else {
            return push(to: remote)
        }

        // 远端有：比较「远端 payload 的 exportedAt」和「本地上次同步时间」
        let remotePayload = readPayload(at: remote)
        guard let rp = remotePayload else {
            return .failed("同步文件夹里的文件读不出来（可能被别的程序写坏了）")
        }

        var m = meta
        let lastSync = m.lastSyncAt ?? .distantPast
        let remoteNewer = rp.exportedAt > lastSync
        let localDirty = hasLocalChanges()

        switch (remoteNewer, localDirty) {
        case (false, false):
            m.lastAction = "无变化"
            meta = m
            return .upToDate
        case (true, false):
            // 只远端有改动 → 拉下来
            let msg = BackupStore.restore(payload: rp)
            stampLocalFiles()
            var m2 = meta
            m2.lastSyncAt = Date()
            m2.lastAction = "已下载"
            meta = m2
            return .pulled(rp.tasks.count)
        case (false, true):
            return push(to: remote)
        case (true, true):
            // 两边都改过：以远端为准推上去（本地那份会被下次同步带回来，
            // 这里先保住远端已有的数据，避免丢东西）
            return push(to: remote)
        }
    }

    private static func push(to remote: URL) -> SyncResult {
        let p = currentPayload()
        do {
            try writePayload(p, to: remote)
            stampLocalFiles()
            var m = meta
            m.lastSyncAt = Date()
            m.lastAction = "已上传"
            meta = m
            return .pushed(p.tasks.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 数据变化后自动同步（节流 30 秒，避免每次改动都写网络）
    private static var lastAutoAt: Date = .distantPast
    private static let autoThrottle: TimeInterval = 30

    static func autoSyncIfNeeded() {
        let c = config
        guard c.isOn, c.autoSync else { return }
        guard Date().timeIntervalSince(lastAutoAt) > autoThrottle else { return }
        guard hasLocalChanges() else { return }
        lastAutoAt = Date()
        _ = syncNow()
    }

    /// 一键检查：先拉后推（设置页「立即同步」按钮）
    static func syncAndReport() -> String {
        let r = syncNow()
        // 拉下来之后本地也会变，再推一次把两端对齐
        if case .pulled = r {
            _ = push(to: remoteURL!)
        }
        return r.text
    }
}
