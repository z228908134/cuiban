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

    // MARK: 重排

    /// - Parameter catchUp: true 表示刚从后台回到前台 / 数据被改动，
    ///   此时对已经逾期的任务立刻补一次提醒（5 秒后）；
    ///   false 表示后台周期性重排，只沿用原有的时间网格，避免重复轰炸。
    static func rescheduleAll(tasks: [TaskItem], settings: AppSettings, catchUp: Bool) {
        let c = center()
        c.getPendingNotificationRequests { pending in
            let old = pending.map { $0.identifier }.filter { $0.hasPrefix(idPrefix) }
            if !old.isEmpty {
                c.removePendingNotificationRequests(withIdentifiers: old)
            }

            let active = tasks.filter { !$0.isDone }.sorted { $0.effectiveDue < $1.effectiveDue }
            guard !active.isEmpty else { return }

            let per = max(6, min(totalSlots, totalSlots / max(1, active.count)))
            for t in active {
                schedule(t, settings: settings, limit: per, catchUp: catchUp)
            }
        }
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
