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

    /// 真正生效的到期时间（考虑延后）
    var effectiveDue: Date {
        if let s = snoozeUntil, s > dueDate { return s }
        return dueDate
    }

    var isOverdue: Bool { !isDone && effectiveDue <= Date() }

    func resolvedInterval(_ fallback: Int) -> Int {
        intervalMinutes > 0 ? intervalMinutes : max(1, fallback)
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
             isDone, doneAt, createdAt, nagCount, lastNagAt, snoozeUntil
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

    init() {}

    // 容错解码：以后再加设置项，老版本存的设置也不会被清空
    enum CodingKeys: String, CodingKey {
        case defaultIntervalMinutes, snoozeMinutes, soundEnabled, keepAlive, theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultIntervalMinutes) ?? d.defaultIntervalMinutes
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? d.keepAlive
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? d.theme
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

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(tasks) { try? d.write(to: tasksFile) }
        if let d = try? enc.encode(settings) { try? d.write(to: settingsFile) }
    }

    func persistSettings() {
        save()
    }

    func updateSettingsPublic(_ s: AppSettings) {
        settings = s
        save()
        NotificationScheduler.rescheduleAll(tasks: tasks, settings: settings, catchUp: true)
    }

    func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { list in
            DispatchQueue.main.async { self.pendingNotificationCount = list.count }
        }
    }

    // MARK: 查询

    var pending: [TaskItem] {
        tasks.filter { !$0.isDone }.sorted { $0.effectiveDue < $1.effectiveDue }
    }
    var overdue: [TaskItem] { pending.filter { $0.effectiveDue <= Date() } }
    var upcoming: [TaskItem] { pending.filter { $0.effectiveDue > Date() } }
    var finished: [TaskItem] {
        tasks.filter { $0.isDone }.sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
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
    func markNagged(id: String) {
        guard let i = index(of: id) else { return }
        tasks[i].nagCount += 1
        tasks[i].lastNagAt = Date()
        save()
    }

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
            let step = Double(t.resolvedInterval(store.settings.defaultIntervalMinutes)) * 60.0
            if let last = t.lastNagAt, now.timeIntervalSince(last) >= step {
                store.markNagged(id: activeId)
            }
            return
        }

        // 2. 找出该催的任务
        let step = { (t: TaskItem) -> Double in
            Double(t.resolvedInterval(store.settings.defaultIntervalMinutes)) * 60.0
        }
        if let next = store.pending.first(where: { t -> Bool in
            guard t.effectiveDue <= now else { return false }
            guard let last = t.lastNagAt else { return true }
            return now.timeIntervalSince(last) >= step(t)
        }) {
            store.markNagged(id: next.id)
            AlarmCenter.shared.show(taskId: next.id)
        }
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
