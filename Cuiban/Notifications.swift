import Foundation
import UserNotifications

/// 本地通知排程。
///
/// iOS 对单个 App 的待发通知有 64 条硬上限，所以策略是「把未来一段时间内的催促
/// 全部预先排好」，同时在后台常驻模式下每分钟重排一次，让催促永不枯竭。
enum NotificationScheduler {

    static let categoryId = "CUIBAN_TASK"
    static let actionDone = "CUIBAN_DONE"
    static let actionSnooze = "CUIBAN_SNOOZE"
    static let actionLater = "CUIBAN_LATER"

    static let idPrefix = "cb."
    /// 系统上限 64，留几条余量
    static let totalSlots = 60
    /// 单个任务最多占多少条：任务很少时别让一个任务把配额一次吃光
    static let maxSlotsPerTask = 12

    static func center() -> UNUserNotificationCenter { UNUserNotificationCenter.current() }

    // MARK: 注册按钮

    static func registerCategories() {
        let done = UNNotificationAction(identifier: actionDone, title: "✅ 标记完成", options: [])
        let snooze = UNNotificationAction(identifier: actionSnooze, title: "😴 延后一会儿", options: [])
        let later = UNNotificationAction(identifier: actionLater, title: "🔔 打开看看", options: [])
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [done, snooze, later],
            intentIdentifiers: [],
            options: []
        )
        center().setNotificationCategories([category])
    }

    static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        center().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    static func soundName() -> UNNotificationSound {
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: "nag.wav"))
    }

    // MARK: 重排（去抖 + 后台）
    //
    // 保存任务 / 完成 / 延后 / 改设置都会调进来。一次重排 =
    // 查一次待发 → removePendingNotificationRequests（最多 60 条）→
    // 再 add 最多 60 条，全是跨进程调用。原来是同步执行在调用点那一帧上，
    // 一次改动就能让「保存」按钮卡住好几百毫秒，连着改几次更明显。
    //
    // 现在：延后 0.4 秒合并（同一批改动只排一次）+ 整体丢到串行后台队列，
    // 调用方立刻返回，界面不受影响。AlarmLoop 每分钟的周期性重排同样受益。
    private static let rescheduleQueue = DispatchQueue(label: "cuiban.reschedule", qos: .utility)
    private static let rescheduleLock = NSLock()
    private static var pendingReschedule: DispatchWorkItem?

    /// - Parameter catchUp: true 表示刚从后台回到前台 / 数据被改动，
    ///   此时对已经逾期的任务立刻补一次提醒（5 秒后）；
    ///   false 表示后台周期性重排，只沿用原有的时间网格，避免重复轰炸。
    static func rescheduleAll(tasks: [TaskItem], settings: AppSettings, catchUp: Bool) {
        // 值类型快照，交给后台队列时不会有数据竞争
        let snapshot = tasks
        let s = settings
        let item = DispatchWorkItem {
            performReschedule(tasks: snapshot, settings: s, catchUp: catchUp)
        }
        rescheduleLock.lock()
        pendingReschedule?.cancel()
        pendingReschedule = item
        rescheduleLock.unlock()
        rescheduleQueue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private static func performReschedule(tasks: [TaskItem], settings: AppSettings, catchUp: Bool) {
        let c = center()
        c.getPendingNotificationRequests { pending in
            let old = pending.map { $0.identifier }.filter { $0.hasPrefix(idPrefix) }
            if !old.isEmpty {
                c.removePendingNotificationRequests(withIdentifiers: old)
            }

            let active = tasks.filter { !$0.isDone }
            guard !active.isEmpty else { return }

            // 槽位按紧迫程度竞标分配（见 allocate 注释），不再按任务数平均切
            for (t, slots) in allocate(active) where slots > 0 {
                schedule(t, settings: settings, limit: slots, catchUp: catchUp)
            }
        }
    }

    // MARK: 槽位分配
    //
    // 原来是「60 ÷ 任务数，再夹到 6~12 条」，这个平均法在任务多时会直接崩：
    // 任务数一过 10，60/12 = 5 被下限抬回 6，12 个任务就是 72 条 ——
    // 超过系统 64 条硬上限，多出来的由 iOS 直接丢弃，丢的还是「最晚触发」
    // 那几条（也就是截止最远的任务），我们完全控制不了。15 个任务要丢 26 条。
    //
    // 现在按紧迫度竞标：每个任务先算一个权重，然后反复把下一个槽位发给
    // 「权重 ÷ (已分到 + 1)」最大的那个，直到 60 个槽位分完。
    //   · 越急的任务分得越密（已逾期 > 1 小时内 > 1 天内 > 3 天内 > 1 周内 > 更远）
    //   · 每个任务至少 1 条占位，不会出现「完全没提醒」
    //   · 总量恒等于 60，任务再多也不越界
    //   · 后台常驻每分钟重排一次，任务临近时权重自然升高，会自动被喂更多槽位
    static func allocate(_ active: [TaskItem]) -> [(TaskItem, Int)] {
        let now = Date()

        // 任务数超过槽位总数：只保最紧急的前 60 个，各 1 条。
        // 剩下的等前面的完成腾出配额、下一轮重排再轮到（App 列表里照样看得到）。
        if active.count > totalSlots {
            let urgent = active.sorted { $0.effectiveDue < $1.effectiveDue }.prefix(totalSlots)
            return urgent.map { ($0, 1) }
        }

        var slots: [String: Int] = [:]
        for t in active { slots[t.id] = 0 }

        var budget = totalSlots
        while budget > 0 {
            var best: TaskItem? = nil
            var bestScore = -1.0
            for t in active {
                let n = slots[t.id] ?? 0
                if n >= maxSlotsPerTask { continue }
                let score = Double(urgency(t, now: now)) / Double(n + 1)
                if score > bestScore + 0.000001 {
                    bestScore = score
                    best = t
                } else if abs(score - bestScore) <= 0.000001,
                          let b = best, n < (slots[b.id] ?? 0) {
                    // 同权重时优先补给分得少的，避免同紧急度的任务也分得忽多忽少
                    best = t
                }
            }
            guard let pick = best else { break }
            slots[pick.id, default: 0] += 1
            budget -= 1
        }

        return active.map { ($0, slots[$0.id] ?? 0) }
    }

    /// 紧迫度权重，越近越大
    private static func urgency(_ t: TaskItem, now: Date) -> Int {
        let dt = t.effectiveDue.timeIntervalSince(now)
        if dt <= 0 { return 6 }                  // 已逾期
        if dt <= 3600 { return 5 }               // 1 小时内
        if dt <= 24 * 3600 { return 4 }          // 1 天内
        if dt <= 3 * 24 * 3600 { return 3 }      // 3 天内
        if dt <= 7 * 24 * 3600 { return 2 }      // 1 周内
        return 1                                 // 更远的先占 1 条
    }

    static func schedule(_ task: TaskItem, settings: AppSettings, limit: Int, catchUp: Bool) {
        let c = center()
        let minutes = task.resolvedInterval(settings.defaultIntervalMinutes)
        let step = Double(minutes) * 60.0

        // 时间网格以「到期时间」为锚点，保证反复重排也不会跑偏
        var fire = task.effectiveDue
        var index = 0

        if catchUp {
            let floor = Date().addingTimeInterval(5)
            if fire < floor {
                fire = floor
                index = 0
            }
        } else {
            let floor = Date().addingTimeInterval(70)
            while fire < floor {
                fire = fire.addingTimeInterval(step)
                index += 1
            }
        }

        for i in 0..<limit {
            let content = UNMutableNotificationContent()
            content.title = "⏰ " + task.title
            if index + i == 0 {
                content.body = "到点了，该做了。"
            } else {
                content.body = "已经催你 \(index + i + 1) 次了，还没完成。"
            }
            content.categoryIdentifier = categoryId
            content.threadIdentifier = task.id
            content.userInfo = ["taskId": task.id]
            if settings.soundEnabled {
                content.sound = soundName()
            }
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fire
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(idPrefix)\(task.id).\(i)",
                content: content,
                trigger: trigger
            )
            c.add(request)
            fire = fire.addingTimeInterval(step)
        }
    }

    // MARK: 立即补一发（后台常驻模式用）

    static func fireNow(_ task: TaskItem, settings: AppSettings) {
        let content = UNMutableNotificationContent()
        content.title = "⏰ " + task.title
        content.body = "已经催你 \(task.nagCount) 次了，还没完成。"
        content.categoryIdentifier = categoryId
        content.threadIdentifier = task.id
        content.userInfo = ["taskId": task.id]
        if settings.soundEnabled {
            content.sound = soundName()
        }
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(idPrefix)now.\(task.id).\(task.nagCount)",
            content: content,
            trigger: trigger
        )
        center().add(request)
    }

    // MARK: 测试

    static func testFire(in seconds: TimeInterval = 5) {
        let content = UNMutableNotificationContent()
        content.title = "⏰ 测试提醒"
        content.body = "看到通知并听到警报声，说明催办已经准备好了。"
        content.sound = soundName()
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center().add(UNNotificationRequest(identifier: "\(idPrefix)test", content: content, trigger: trigger))
    }
}
