import Foundation
import SwiftUI
import UserNotifications

// MARK: - 重复方式

enum RepeatMode: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, weekday, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .weekday: return "工作日"
        case .monthly: return "每月"
        }
    }
}

// MARK: - 任务

struct TaskItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var note: String = ""
    var dueDate: Date = Date()
    /// 0 表示跟随全局默认
    var intervalMinutes: Int = 0
    var repeatMode: RepeatMode = .none
    /// 每周重复时具体是哪几天（Calendar 口径：1=周日 ... 7=周六），空表示「每周同一天」
    var weekdays: [Int] = []
    /// 附在任务上的照片（存在沙盒 attachments/ 里的文件名）
    var photos: [String] = []
    var isDone: Bool = false
    var doneAt: Date? = nil
    var createdAt: Date = Date()
    /// 已经被催了多少次
    var nagCount: Int = 0
    /// 最近一次催促时间
    var lastNagAt: Date? = nil
    /// 延后到这个时间之前不再打扰
    var snoozeUntil: Date? = nil
    /// 「已抢到」的时间。非 nil 表示这次机会已经抓住：
    /// 任务不消失（留在清单的「已抢到」分组里），但提醒节奏从
    /// 「每 N 分钟」降为「每天一次」，直到下次机会时间（hitDeadline）自动收起。
    var hitAt: Date? = nil

    /// 真正生效的到期时间（考虑延后）
    var effectiveDue: Date {
        if let s = snoozeUntil, s > dueDate { return s }
        return dueDate
    }

    /// 已抢到：本轮机会拿到了，改走每日提醒，不再算「逾期」
    var isHit: Bool { hitAt != nil }

    /// 已抢到的任务不该继续报「逾期」——它已经拿到了，只是还在跟进
    var isOverdue: Bool { !isDone && !isHit && effectiveDue <= Date() }

    /// 已抢到阶段的截止时间：下次机会到来的时刻。
    ///
    /// 重复任务按重复规则往后一步（每月抢购 → 下个月同一天同一时刻）；
    /// 不重复的按「一个月」算（活动持续一月的场景），到点自动收尾。
    var hitDeadline: Date {
        if repeatMode != .none { return stepForward(from: dueDate) }
        return Calendar.current.date(byAdding: .month, value: 1, to: dueDate)
            ?? dueDate.addingTimeInterval(2592000)
    }

    func resolvedInterval(_ fallback: Int) -> Int {
        intervalMinutes > 0 ? intervalMinutes : max(1, fallback)
    }

    /// 当前真正生效的催促间隔（分钟）。
    /// 已抢到之后固定 1440（每天一次），其余情况按任务自己的间隔。
    func nagIntervalMinutes(_ fallback: Int) -> Int {
        isHit ? 1440 : resolvedInterval(fallback)
    }

    /// 催促节奏的说明文案，列表 / 详情 / 催促页共用
    func nagIntervalText(_ fallback: Int) -> String {
        isHit ? "每天提醒" : "每 \(resolvedInterval(fallback)) 分钟"
    }

    /// 按重复规则往后走一步
    func stepForward(from date: Date, calendar cal: Calendar = .current) -> Date {
        switch repeatMode {
        case .none:
            return date
        case .daily:
            return cal.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        case .weekday:
            var d = date
            repeat {
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            } while cal.isDateInWeekend(d)
            return d
        case .weekly:
            if weekdays.isEmpty {
                return cal.date(byAdding: .weekOfYear, value: 1, to: date) ?? date.addingTimeInterval(604800)
            }
            let set = Set(weekdays)
            var d = date
            repeat {
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            } while !set.contains(cal.component(.weekday, from: d))
            return d
        case .monthly:
            return cal.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(2592000)
        }
    }

    /// 从当前到期时间开始，按重复规则推算出 `end` 之前的每一次日期（不含已完成的）
    func projectedDates(until end: Date, maxCount: Int = 400) -> [Date] {
        guard repeatMode != .none, !isDone else { return [] }
        let cal = Calendar.current
        let now = Date()
        var d = effectiveDue
        var guardCount = 0
        while d <= now && guardCount < maxCount {
            let next = stepForward(from: d, calendar: cal)
            if next <= d { return [] }
            d = next
            guardCount += 1
        }
        var out: [Date] = []
        while d < end && guardCount < maxCount {
            out.append(d)
            let next = stepForward(from: d, calendar: cal)
            if next <= d { break }
            d = next
            guardCount += 1
        }
        return out
    }
}

// 容错解码：老版本存下来的 JSON 缺少新加的字段也不会导致整个列表读不出来
extension TaskItem {
    enum CodingKeys: String, CodingKey {
        case id, title, note, dueDate, intervalMinutes, repeatMode, weekdays, photos,
             isDone, doneAt, createdAt, nagCount, lastNagAt, snoozeUntil, hitAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TaskItem()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate) ?? d.dueDate
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        repeatMode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? d.repeatMode
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? d.weekdays
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? d.photos
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? d.isDone
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        nagCount = try c.decodeIfPresent(Int.self, forKey: .nagCount) ?? d.nagCount
        lastNagAt = try c.decodeIfPresent(Date.self, forKey: .lastNagAt)
        snoozeUntil = try c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        hitAt = try c.decodeIfPresent(Date.self, forKey: .hitAt)
    }
}

// MARK: - 外观

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var shortLabel: String {
        switch self {
        case .system: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// nil 表示交给系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 设置

struct AppSettings: Codable, Equatable {
    var defaultIntervalMinutes: Int = 5
    var snoozeMinutes: Int = 10
    var soundEnabled: Bool = true
    /// 后台常驻：让 App 留在后台按秒计时，实现真正「一直催」
    var keepAlive: Bool = true
    /// 外观：跟随系统 / 浅色 / 深色
    var theme: ThemeMode = .system
    /// 自动备份到 App 本地（Documents/Backups）
    var autoBackup: Bool = true
/// 备份文件里是否内嵌照片
    var backupIncludePhotos: Bool = true
    /// 本地备份最多留几份（超出删最旧的）。0 或非法值按 keepDefault 兜底。
    var maxBackups: Int = 20
    /// 全局字号系数（1.0 = 标准）。真正的值存在 FontScale（UserDefaults）里，
    /// 这里跟着存一份，为了跟备份/恢复走
    var fontScale: Double = 1.0

    init() {}

    // 容错解码：以后再加设置项，老版本存的设置也不会被清空
    enum CodingKeys: String, CodingKey {
        case defaultIntervalMinutes, snoozeMinutes, soundEnabled, keepAlive, theme,
       autoBackup, backupIncludePhotos, maxBackups, fontScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
   let d = AppSettings()
        defaultIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultIntervalMinutes) ?? d.defaultIntervalMinutes
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? d.keepAlive
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? d.theme
        autoBackup = try c.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? d.autoBackup
        backupIncludePhotos = try c.decodeIfPresent(Bool.self, forKey: .backupIncludePhotos) ?? d.backupIncludePhotos
  maxBackups = try c.decodeIfPresent(Int.self, forKey: .maxBackups) ?? d.maxBackups
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? d.fontScale
    }
}

// MARK: - 数据仓库

final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published var tasks: [TaskItem] = []
    @Published var settings = AppSettings()
    @Published var authStatus: UNAuthorizationStatus = .notDetermined
    @Published var pendingNotificationCount: Int = 0

    private let tasksFile: URL
    private let settingsFile: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        tasksFile = dir.appendingPathComponent("cuiban_tasks.json")
        settingsFile = dir.appendingPathComponent("cuiban_settings.json")
        load()
    }

    // MARK: 持久化

    private func load() {
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: tasksFile),
           let list = try? dec.decode([TaskItem].self, from: data) {
            tasks = list
        }
        if let data = try? Data(contentsOf: settingsFile),
           let s = try? dec.decode(AppSettings.self, from: data) {
            settings = s
        }
    }

/// 所有改数据的路径最终都会走到这里，所以查询缓存在这里统一失效
    private func save() {
        invalidateQueryCache()
        let t = tasks
        let s = settings
        // 全量 JSON 编码 + 磁盘写 + 发全局通知，放后台。
        // AlarmLoop 每秒会调 markNagged → save()，原来每秒都在主线程做一遍
        // pretty-print 编码 + 两次文件写，用户打字时能感觉到周期性卡顿。
        DispatchQueue.global(qos: .utility).async {
       let enc = JSONEncoder()
  // 主数据文件不需要人看，prettyPrinted 会让体积和耗时都翻倍
     enc.outputFormatting = [.sortedKeys]
            if let d = try? enc.encode(t) { try? d.write(to: self.tasksFile) }
            if let d = try? enc.encode(s) { try? d.write(to: self.settingsFile) }
        BackupStore.autoBackupIfNeeded(tasks: t, settings: s)
   }
        // 通知改异步投递：post 是同步的，会直接调用 RootView 的 onReceive →
    // autoSyncIfNeeded。原来会把网络 IO 拉回主线程。
        DispatchQueue.main.async {
   NotificationCenter.default.post(name: .cuibanDataChanged, object: nil)
    }
    }

    func persistSettings() {
        save()
    }

    func updateSettingsPublic(_ s: AppSettings) {
        settings = s
        save()
        // 字号跟着设置走：恢复备份后能自动还原
        if abs(s.fontScale - FontScale.shared.value) > 0.001 {
            FontScale.shared.value = s.fontScale
        }
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { list in
            DispatchQueue.main.async { self.pendingNotificationCount = list.count }
        }
    }

    // MARK: 查询
    //
    // pending / overdue / upcoming / finished 都是 O(n log n)，
    // 而 body 里 `overdue` 单这一处就被引用了 3 次（App.swift 的 badge、
    // TaskListView 的行和分区）。原来每个都是独立计算 = 每秒重复 filter+sort 十几次，
    // 任务多的时候肉眼可见地卡。
    //
    // 现在 tasks 一变就缓存一份 pending，overdue/upcoming 从它派生（只是 filter，不再排序）。
    // finished 单独缓存（倒序排法不一样）。改一处任务后缓存失效重算。
    private var pendingCache: [TaskItem]?
    private var finishedCache: [TaskItem]?

    /// 调用方在修改 tasks 后必须调它，否则缓存里的旧数据会让界面不更新
    func invalidateQueryCache() {
        pendingCache = nil
        finishedCache = nil
    }

    var pending: [TaskItem] {
        if let c = pendingCache { return c }
        let c = tasks.filter { !$0.isDone }.sorted { $0.effectiveDue < $1.effectiveDue }
        pendingCache = c
        return c
    }

    /// 已抢到：单独一组展示。它们的 effectiveDue 已经过去（抢购时刻过了），
    /// 但既不算逾期也不该掉出列表 —— 漏掉 upcoming 会让任务凭空消失。
    var hit: [TaskItem] { pending.filter { $0.isHit } }
    var overdue: [TaskItem] { pending.filter { !$0.isHit && $0.effectiveDue <= Date() } }
    var upcoming: [TaskItem] { pending.filter { !$0.isHit && $0.effectiveDue > Date() } }

    /// 只要数量时用它：不用建中间数组
    var overdueCount: Int {
        var n = 0
        let now = Date()
        for t in pending where !t.isHit && t.effectiveDue <= now { n += 1 }
        return n
    }

    var finished: [TaskItem] {
        if let c = finishedCache { return c }
        let c = tasks.filter { $0.isDone }.sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
        finishedCache = c
        return c
    }

    func task(id: String?) -> TaskItem? {
        guard let id = id else { return nil }
        return tasks.first { $0.id == id }
    }

    private func index(of id: String) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    // MARK: 修改

    func upsert(_ task: TaskItem) {
        if let i = index(of: task.id) {
            tasks[i] = task
        } else {
            tasks.append(task)
        }
        save()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    func delete(id: String) {
        if let i = index(of: id) {
            AttachmentStore.delete(tasks[i].photos)
        }
        tasks.removeAll { $0.id == id }
        save()
        AlarmCenter.shared.dismiss()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    func complete(id: String?) {
        guard let id = id, let i = index(of: id) else { return }
        let old = tasks[i]
        tasks[i].isDone = true
        tasks[i].doneAt = Date()
        tasks[i].snoozeUntil = nil

        if old.repeatMode != .none, let next = nextOccurrence(of: old) {
            var n = old
            n.id = UUID().uuidString
            n.isDone = false
            n.doneAt = nil
            n.dueDate = next
            n.snoozeUntil = nil
            n.nagCount = 0
            n.lastNagAt = nil
            n.createdAt = Date()
            // 下一条是新机会，必须从「未抢到」开始重新高频催抢
            n.hitAt = nil
            tasks.append(n)
        }

        save()
        AlarmCenter.shared.dismiss(id: id)
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    func uncomplete(id: String) {
        guard let i = index(of: id) else { return }
        tasks[i].isDone = false
        tasks[i].doneAt = nil
        save()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    // MARK: 已抢到（抢购类任务用）
    //
    // 场景：每月一次机会的抢购 / 报名，活动本身持续一整月。
    // 抢中之后任务不该消失（还得跟一个月），但也不该继续每 N 分钟催 ——
    // 所以点「已抢到」把它切成「每天提醒一次」，到下月机会时刻自动收起，
    // 重复规则会顺手把下个月的抢购任务排出来。

    /// 标记已抢到：留在清单里，提醒降频成每天一次
    func markHit(id: String?) {
        guard let id = id, let i = index(of: id) else { return }
        tasks[i].hitAt = Date()
        tasks[i].snoozeUntil = nil
        // 关键：把 lastNagAt 设成现在，否则 AlarmLoop 下一刻就会判定
        // 「从没催过」→ 立刻弹一次催促页，刚点完又被打扰。
        tasks[i].lastNagAt = Date()
        save()
        AlarmCenter.shared.dismiss(id: id)
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    /// 撤销已抢到：回到高频催促
    func undoHit(id: String?) {
        guard let id = id, let i = index(of: id) else { return }
        tasks[i].hitAt = nil
        tasks[i].lastNagAt = nil
        save()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    /// 已抢到的任务到了下次机会时刻：自动收起这一条。
    ///
    /// 走完 complete() 就会把下一条排出来（重复任务），新任务从「未抢到」
    /// 起步继续高频催抢；不重复的任务则就此完成，不再每天提醒。
    /// AlarmLoop 每秒会 call 一次，所以内部先做一次极便宜的判断再动手。
    func rollOverHitTasks() {
        guard tasks.contains(where: { $0.isHit && !$0.isDone }) else { return }
        let now = Date()
        for t in tasks where t.isHit && !t.isDone && t.hitDeadline <= now {
            complete(id: t.id)
        }
    }

    func snooze(id: String?, minutes: Int? = nil) {
        guard let id = id, let i = index(of: id) else { return }
        let m = minutes ?? settings.snoozeMinutes
        let base = max(Date(), tasks[i].effectiveDue)
        tasks[i].snoozeUntil = base.addingTimeInterval(Double(max(1, m)) * 60)
        tasks[i].lastNagAt = Date()
        tasks[i].nagCount += 1
        save()
        AlarmCenter.shared.dismiss(id: id)
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    /// 记一次催促
/// 催促页开着时 AlarmLoop 每秒可能调一次。
    /// 内存态立刻更新（界面上的计数要马上长），落盘节流 10 秒——
    /// 这个字段丢一点无所谓，崩溃时最多少记几次。
    func markNagged(id: String) {
        guard let i = index(of: id) else { return }
        tasks[i].nagCount += 1
        tasks[i].lastNagAt = Date()
        invalidateQueryCache()

        let now = Date()
        if nagPersistLock == nil {
            nagPersistLock = now
        }
        if now.timeIntervalSince(nagPersistLock!) < 10 { return }
        nagPersistLock = now
        save()
    }

    private var nagPersistLock: Date?

    // MARK: 重复任务的下一次时间

    private func nextOccurrence(of t: TaskItem) -> Date? {
        guard t.repeatMode != .none else { return nil }
        let cal = Calendar.current
        var d = t.effectiveDue
        for _ in 0..<400 {
            switch t.repeatMode {
            case .none:
                return nil
            case .daily:
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            case .weekly:
                if t.weekdays.isEmpty {
                    d = cal.date(byAdding: .weekOfYear, value: 1, to: d) ?? d.addingTimeInterval(604800)
                } else {
                    let set = Set(t.weekdays)
                    repeat {
                        d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
                    } while !set.contains(cal.component(.weekday, from: d))
                }
            case .weekday:
                repeat {
                    d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
                } while cal.isDateInWeekend(d)
            case .monthly:
                d = cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(2592000)
            }
            if d > Date() { return d }
        }
        return d
    }

    // MARK: 通知授权

    func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { self.refreshAuth() }
        }
    }

    func refreshAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { self.authStatus = s.authorizationStatus }
        }
    }

    var authText: String {
        switch authStatus {
        case .authorized: return "已开启"
        case .denied: return "被拒绝（去 设置 → 通知 → 催办 里打开）"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时授权"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    func clearFinished() {
        let gone = tasks.filter { $0.isDone }.flatMap { $0.photos }
        AttachmentStore.delete(gone)
        tasks.removeAll { $0.isDone }
        save()
    }

    func clearAll() {
        AttachmentStore.delete(tasks.flatMap { $0.photos })
        tasks.removeAll()
        save()
        AlarmCenter.shared.dismiss()
        NotificationScheduler.rescheduleAll(tasks: [], settings: settings, catchUp: true)
    }

    /// 用备份整体替换当前数据（照片缺失的会被跳过，不会报错）
    func replaceAll(tasks newTasks: [TaskItem], settings newSettings: AppSettings) {
        let oldPhotos = Set(tasks.flatMap { $0.photos })
        let newPhotos = Set(newTasks.flatMap { $0.photos })
        let gone = oldPhotos.subtracting(newPhotos)
        if !gone.isEmpty {
            AttachmentStore.delete(Array(gone))
        }
        tasks = newTasks
        settings = newSettings
        save()
        AlarmCenter.shared.dismiss()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    /// 所有任务正在引用的照片文件名
    var usedPhotoNames: Set<String> {
        Set(tasks.flatMap { $0.photos })
    }

    /// 清理没有任何任务引用的照片，返回清理数量
    @discardableResult
    func vacuumPhotos() -> Int {
        AttachmentStore.vacuum(keeping: usedPhotoNames)
    }
}

// MARK: - 催促中心

final class AlarmCenter: ObservableObject {
    static let shared = AlarmCenter()

    @Published var activeTaskId: String? = nil

    func show(taskId: String?) {
        guard let taskId = taskId else { return }
        guard let t = TaskStore.shared.task(id: taskId), !t.isDone else { return }
        guard activeTaskId != taskId else { return }
        activeTaskId = taskId
        if TaskStore.shared.settings.soundEnabled {
            AlarmSound.shared.start()
        }
    }

    func dismiss(id: String? = nil) {
        if let id = id, let cur = activeTaskId, cur != id { return }
        activeTaskId = nil
        AlarmSound.shared.stop()
    }
}

// MARK: - 催促循环

final class AlarmLoop {
    static let shared = AlarmLoop()

    private var timer: Timer?
    private var lastRearmAt = Date.distantPast

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let store = TaskStore.shared
        let now = Date()

        // 0. 后台常驻时周期性重排通知，让催促可以无限延续
        rearmIfNeeded()

        // 0.5 已抢到的任务到了下次机会时刻就自动收起（内部有廉价短路判断，
        //     没有「已抢到」任务时只是一次 contains 扫描）
        rollOverIfNeeded(store: store)

        // 1. 已有催促页时：到间隔就再记一次，界面上的计数会自己长
        if let activeId = AlarmCenter.shared.activeTaskId {
            guard let t = store.task(id: activeId) else {
                AlarmCenter.shared.dismiss()
                return
            }
            if t.isDone {
                AlarmCenter.shared.dismiss(id: activeId)
                return
            }
            let step = Double(t.nagIntervalMinutes(store.settings.defaultIntervalMinutes)) * 60.0
            if let last = t.lastNagAt, now.timeIntervalSince(last) >= step {
                store.markNagged(id: activeId)
            }
            return
        }

        // 2. 找出该催的任务：普通任务优先，已抢到的（每天一次）排在后面。
        //    pending 是按到期时间排的，已抢到的到期时间在过去会顶到最前面，
        //    直接取 first 会让「已抢到」的每日提醒抢在真正紧急的任务之前。
        let step = { (t: TaskItem) -> Double in
            Double(t.nagIntervalMinutes(store.settings.defaultIntervalMinutes)) * 60.0
        }
        let isDue: (TaskItem) -> Bool = { t in
            guard t.effectiveDue <= now else { return false }
            guard let last = t.lastNagAt else { return true }
            return now.timeIntervalSince(last) >= step(t)
        }
        let all = store.pending
        if let next = all.first(where: { !$0.isHit && isDue($0) })
            ?? all.first(where: { $0.isHit && isDue($0) }) {
            store.markNagged(id: next.id)
            AlarmCenter.shared.show(taskId: next.id)
        }
    }

    private var lastRolloverAt = Date.distantPast

    /// 「已抢到」任务的下月切换不用每秒算，30 秒检查一次足够精确
    private func rollOverIfNeeded(store: TaskStore) {
        guard Date().timeIntervalSince(lastRolloverAt) >= 30 else { return }
        lastRolloverAt = Date()
        store.rollOverHitTasks()
    }

    /// 后台常驻时周期性重排，让催促无限延续下去
    func rearmIfNeeded() {
        let store = TaskStore.shared
        guard store.settings.keepAlive else { return }
        guard Date().timeIntervalSince(lastRearmAt) >= 60 else { return }
        lastRearmAt = Date()
        NotificationScheduler.rescheduleAll(tasks: store.tasks, settings: store.settings, catchUp: false)
    }
}
