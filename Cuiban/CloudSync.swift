import Foundation

// MARK: - 数据变化通知
//
// 任务 / 笔记 / 卡片任何一处保存都会发这个通知，根视图统一监听后触发同步。
// 这样不必在每个页面里都塞同步调用，也不漏「某条路径忘了同步」。
extension Notification.Name {
    static let cuibanDataChanged = Notification.Name("cuiban.dataChanged")
    /// 同步目标（文件夹 / WebDAV）配置变了。设置页监听它刷新「已连接」状态——
    /// 配置是在二级页里改的，主页面收不到任何 SwiftUI 状态变化通知。
    static let cloudConfigChanged = Notification.Name("cuiban.cloudConfigChanged")
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
/// 同步方式：folder = 系统文件里选的目录；webdav = 直连 NAS 的 WebDAV
    var mode: String = "folder"
        /// 同步文件夹路径（mode == folder 时有效，空 = 未开启）
        var folder: String = ""
      /// WebDAV 地址，如 http://192.168.1.10:5005/cuiban-sync（mode == webdav 时有效）
   var webdavURL: String = ""
        var webdavUser: String = ""
        /// 目标文件名（飞牛上会生成一个带时间戳的目录，Windows 端指到这个目录）
        var remoteName: String = "cuiban-data.json"
        /// 是否包含照片
        var includePhotos: Bool = true
        /// 自动同步
        var autoSync: Bool = true

        var isOn: Bool {
            if mode == "webdav" { return !webdavURL.isEmpty }
    return !folder.isEmpty
        }

        /// 设置页显示的「同步位置」
        var displayTarget: String {
        mode == "webdav"
       ? "\(webdavURL)/\(remoteName)"
       : folder
        }
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
NotificationCenter.default.post(name: .cloudConfigChanged, object: nil)
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
        c.mode = "folder"
    c.folder = folder
        c.includePhotos = includePhotos
 c.autoSync = autoSync
        config = c
    }

    /// 配置 WebDAV 目标。密码不进 UserDefaults，单独放 Keychain。
    static func configureWebDAV(url: String, user: String, password: String,
    includePhotos: Bool, autoSync: Bool) {
      var c = config
        c.mode = "webdav"
        c.webdavURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        c.webdavUser = user
        c.includePhotos = includePhotos
        c.autoSync = autoSync
        config = c
     Keychain.set(password, for: webdavPasswordKey)
    }

    private static var webdavPasswordKey: String { "cloudsync.webdav.password" }

    /// 当前 WebDAV 密码（存 Keychain，取不到当空串）
    static var webdavPassword: String {
        Keychain.get(webdavPasswordKey) ?? ""
    }

    static var webdavClient: WebDAVClient? {
        let c = config
        guard c.mode == "webdav", !c.webdavURL.isEmpty else { return nil }
        return WebDAVClient(baseURL: c.webdavURL,
                            user: c.webdavUser,
        password: webdavPassword,
        fileName: c.remoteName.isEmpty ? "cuiban-data.json" : c.remoteName)
    }

    static func disable() {
        var c = config
        c.folder = ""
        c.webdavURL = ""
        config = c
        Keychain.remove(webdavPasswordKey)
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

    /// 远端文件是否已经存在（设置页「从同步文件夹拉取」用它判空）
    static func remoteFileExists() -> Bool {
        let c = config
        if c.mode == "webdav" {
guard let cli = webdavClient else { return false }
        return ((try? cli.download()) ?? nil) != nil
    }
        guard let u = localRemoteURL else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    private static var localRemoteURL: URL? {
   let c = config
  guard c.mode != "webdav", !c.folder.isEmpty else { return nil }
        return URL(fileURLWithPath: (c.folder as NSString)
            .appendingPathComponent(c.remoteName.isEmpty ? "cuiban-data.json" : c.remoteName))
    }

  // MARK: 读写远端（本地文件夹和 WebDAV 统一走这里）

    /// 读远端内容。返回 nil = 远端还没有数据
    private static func readRemote() -> Data? {
   let c = config
        if c.mode == "webdav" {
          guard let cli = webdavClient else { return nil }
            return try? cli.download()
        }
        guard let u = localRemoteURL else { return nil }
        return try? Data(contentsOf: u)
    }

/// 写远端
    private static func writeRemote(_ data: Data) throws {
        let c = config
        if c.mode == "webdav" {
      guard let cli = webdavClient else { throw WebDAVClient.WebDAVError.badURL }
   try cli.upload(data)
      return
        }
        guard let u = localRemoteURL else { throw WebDAVClient.WebDAVError.badURL }
    // 先写临时文件再替换，避免中途断网写坏文件
        let tmp = u.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: u.path) {
_ = try FileManager.default.replaceItemAt(u, withItemAt: tmp)
        } else {
         try FileManager.default.moveItem(at: tmp, to: u)
        }
    }

    // MARK: 远端历史备份（同 cuiban-data.json 同格式，按时间戳命名）

    /// 历史文件前缀（和主文件区分开，listRemoteBackups 靠它筛选）
    private static let historyPrefix = "cuiban-backup-"
    private static let historySuffix = ".json"

    /// 远端历史备份的份数上限（跟着 AppSettings.maxBackups 走）
    private static func historyKeep() -> Int {
        let v = UserDefaults.standard.integer(forKey: "cuiban.cloudHistoryKeep")
        return v > 0 ? v : 20
    }

    static var historyKeepBindingValue: Int { historyKeep() }

static func setHistoryKeep(_ v: Int) {
        UserDefaults.standard.set(max(1, v), forKey: "cuiban.cloudHistoryKeep")
        // 修剪要发 PROPFIND + DELETE，绝不能挡着用户拨 Picker 的手
        DispatchQueue.global(qos: .utility).async {
            pruneRemoteHistory()
        }
    }

    private static func historyName(_ d: Date) -> String {
        "\(historyPrefix)\(stampFor(d))\(historySuffix)"
    }

    private static func stampFor(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// 同步成功后额外存一份带时间戳的历史文件（失败不影响主同步）
    private static func writeRemoteHistory(_ data: Data) {
        let name = historyName(Date())
        do {
            let c = config
    if c.mode == "webdav" {
      guard let cli = webdavClient else { return }
       try cli.upload(data, as: name)
  } else {
                guard let dir = localRemoteDir else { return }
   let u = dir.appendingPathComponent(name)
                try data.write(to: u, options: .atomic)
            }
    bumpHistoryCount()
        } catch {
      print("写远端历史备份失败：\(error.localizedDescription)")
        }
    }

    private static var localRemoteDir: URL? {
        let c = config
        guard c.mode != "webdav", !c.folder.isEmpty else { return nil }
        return URL(fileURLWithPath: c.folder, isDirectory: true)
    }

    // MARK: 历史份数记账
    //
    // 原来每次同步完都要 PROPFIND 列一次目录才能知道几份了，
    // 等于凭空多一个网络往返（同步本身已经是 2 个了）。
    // 改成：写一份就在本地记一笔，只有「记着可能超限」时才真的去列目录核对。
    // 计数不可信（用户可能在 NAS 上手动删文件）时，下次设置页会重新校准。

    private static var historyCountKey: String { "cloudsync.historyCount" }
    /// 记不准/未初始化时用 -1 表示「需要列目录校准」
    private static var countedHistory: Int {
        get { UserDefaults.standard.integer(forKey: historyCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: historyCountKey) }
    }

    private static func bumpHistoryCount() {
        let n = countedHistory
        countedHistory = n < 0 ? n : n + 1
        // 记着可能超限才去核对（留 2 份的余量，少问一次是一次网络往返）
        if countedHistory > historyKeep() {
            pruneRemoteHistory()
        }
    }

    /// 远端现有的历史备份文件名（已按时间从新到旧排好）
    static func remoteHistoryNames() -> [String] {
        let c = config
        if c.mode == "webdav" {
            guard let cli = webdavClient,
 let names = cli.listFileNames() else { return [] }
    let filtered = names
     .filter { $0.hasPrefix(historyPrefix) && $0.hasSuffix(historySuffix) }
  .sorted(by: >)
   // 列过了就顺手校准本地计数
      if !filtered.isEmpty || names.isEmpty {
          countedHistory = filtered.count
      }
            return filtered
        }
        guard let dir = localRemoteDir,
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
     return []
  }
        let filtered = names
      .filter { $0.hasPrefix(historyPrefix) && $0.hasSuffix(historySuffix) }
 .sorted(by: >)
        countedHistory = filtered.count
 return filtered
    }

    /// 远端历史备份份数（给设置页显示）。
    /// 返回 -1 表示「本地没记账、要去列目录」
    static func remoteHistoryCountIfKnown() -> Int {
        countedHistory
    }

    /// 远端历史备份份数（一定准确，但要发网络请求）
    static func remoteHistoryCount() -> Int {
        remoteHistoryNames().count
    }

    /// 删掉超出上限的旧历史（只留最新的 N 份）
    private static func pruneRemoteHistory() {
        let keep = historyKeep()
        let names = remoteHistoryNames() // 内部会校准 countedHistory
        guard names.count > keep else { return }
        let excess = names.dropFirst(keep)
        let c = config
        if c.mode == "webdav" {
    guard let cli = webdavClient else { return }
            for n in excess { cli.deleteFile(named: n) }
        } else {
         guard let dir = localRemoteDir else { return }
            for n in excess {
     try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
         }
        }
        countedHistory = keep
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
                // 走带缓存的编码：照片不变就不重新读盘 + base64
                if let b64 = AttachmentStore.base64(n) {
                    photos[n] = b64
                }
            }
            p.photos = photos
        }
        return p
    }

/// 把 payload 编成 JSON（WebDAV 和本地文件夹用的是同一份字节）
private static func encode(_ p: BackupPayload) throws -> Data {
        let enc = JSONEncoder()
        // 不要 prettyPrinted：照片已经 base64 进来了（体积 ×1.33），
        // 再美化一次白白让内存峰值和编码耗时翻倍
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(p)
    }

    /// 解析远端内容
    private static func decode(_ data: Data?) -> BackupPayload? {
        guard let data, !data.isEmpty else { return nil }
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
            case .pushed(let n): return "已上传 \(n) 个任务到 NAS"
case .pulled(let n): return "已从 NAS 下载 \(n) 个任务"
            case .merged: return "已把 NAS 上的改动合并进来"
            case .failed(let e): return "同步失败：\(e)"
            }
        }
    }

/// 手动同步：先尝试上传本地，再检查远端有没有更新
    @discardableResult
    static func syncNow() -> SyncResult {
        let c = config
        guard c.isOn else { return .off }

        // 远端还没有 → 直接推上去
        guard let remoteData = readRemote(), !remoteData.isEmpty else {
            return push()
        }

        // 远端有：比较「远端 payload 的 exportedAt」和「本地上次同步时间」
        guard let rp = decode(remoteData) else {
            return .failed("远端的数据文件读不出来（可能被别的程序写坏了）")
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
            _ = BackupStore.restore(payload: rp)
            stampLocalFiles()
            var m2 = meta
            m2.lastSyncAt = Date()
            m2.lastAction = "已下载"
            meta = m2
            return .pulled(rp.tasks.count)
        case (false, true):
            return push()
        case (true, true):
        // 两边都改过：以远端为准推上去（本地那份会被下次同步带回来，
   // 这里先保住远端已有的数据，避免丢东西）
      return push()
        }
    }

private static func push() -> SyncResult {
        let p = currentPayload()
        do {
            let data = try encode(p)
            try writeRemote(data)
        // 顺带存一份带时间戳的历史，失败不影响主同步结果
    writeRemoteHistory(data)
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

    /// 只拉不推（设置页「用远端覆盖本机」用）
    @discardableResult
    static func pullOnly() -> SyncResult {
        guard config.isOn else { return .off }
        guard let data = readRemote(), !data.isEmpty else {
            return .failed("远端还没有数据")
        }
        guard let rp = decode(data) else {
            return .failed("远端的数据文件读不出来")
        }
        _ = BackupStore.restore(payload: rp)
        stampLocalFiles()
        var m = meta
        m.lastSyncAt = Date()
        m.lastAction = "已下载"
        meta = m
        return .pulled(rp.tasks.count)
    }

    /// 数据变化后自动同步（节流 30 秒，避免每次改动都写网络）
    ///
    /// **绝不能在主线程跑**：一次 syncNow() 在 WebDAV 下是 4~6 个串行网络往返
    /// （GET / PUT 主文件 / PUT 历史 / PROPFIND 列目录 / 可能 DELETE 修剪），
    /// 每个都 sem.wait() 阻塞。用户每打几个字就冻一下就是这么来的。
    /// 节流只限制频率，不解决线程问题。
    private static var lastAutoAt: Date = .distantPast
    private static let autoThrottle: TimeInterval = 30
    /// 进程启动时刻，用来给「自动同步」留一段冷静期（详见 autoSyncIfNeeded）
    private static let launchedAt = Date()
    /// 正在跑的同步，用来防止并发（后台化之后可能重入）
    private static let syncLock = NSLock()
    private static var syncRunning = false

    static func autoSyncIfNeeded() {
        // 进程启动后的头几秒不自动同步。进 App 那一下本来就最忙
        // （读数据、建首帧、排通知），而一次同步要打包全部照片
        // （几十 MB 的读盘 + base64 + JSON 编码），撞在一起就是
        // 「白屏好几秒、进去还卡」。首屏那次同步交给 syncOnLaunch。
        guard Date().timeIntervalSince(launchedAt) > 5 else { return }
        // UserDefaults + 读三个文件的 stat：这一步很轻，主线程可以做
        let c = config
        guard c.isOn, c.autoSync else { return }
        guard Date().timeIntervalSince(lastAutoAt) > autoThrottle else { return }
        guard hasLocalChanges() else { return }
        lastAutoAt = Date()
        // 网络部分丢后台
        DispatchQueue.global(qos: .utility).async {
            guard beginSync() else { return }
            defer { endSync() }
            _ = syncNow()
        }
    }

    /// 进 App 时的首次同步：等界面彻底稳住再跑
    static func syncOnLaunch() {
        // 原来是 0.8 秒 —— 正好和首帧渲染、列表构建、通知排程撞在一起。
        // 而且它一跑就要打包全部照片（固定几十 MB 的成本），
        // 所以往后放到 3 秒，让用户先看到能操作的界面。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            guard beginSync() else { return }
            defer { endSync() }
            _ = syncNow()
        }
    }

    private static func beginSync() -> Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        if syncRunning { return false }
        syncRunning = true
        return true
    }

    private static func endSync() {
        syncLock.lock()
        syncRunning = false
        syncLock.unlock()
    }

    /// 一键检查：先拉后推（设置页「立即同步」按钮）
    static func syncAndReport() -> String {
    let r = syncNow()
   // 拉下来之后本地也会变，再推一次把两端对齐
 if case .pulled = r {
  _ = push()
        }
        return r.text
    }
}
