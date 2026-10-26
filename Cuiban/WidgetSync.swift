import Foundation
import WidgetKit

/// 主 App → 桌面/锁屏小组件的数据桥。
/// 主 App 每次落盘后把「接下来要催什么」的快照写进 App Group 的
/// UserDefaults，小组件进程从同一容器读取。
/// 注意：小组件是独立进程、独立编译目标，拿不到主 App 的代码 ——
/// 快照结构在 Widget/NagWidget.swift 里有同构副本，两边字段要一起改。
enum WidgetSync {
    static let appGroup = "group.com.cuiban.app"
    static let snapshotKey = "widget_snapshot"
    static let updatedKey = "widget_updated"

    struct Entry: Codable {
        let id: String
        let title: String
        let due: Date
        let overdue: Bool
    }

    /// 把最临近的 8 条未完成任务写进共享容器并刷新时间线
    static func push(tasks: [TaskItem]) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let soon = tasks
            .filter { !$0.isDone }
            .sorted { $0.effectiveDue < $1.effectiveDue }
            .prefix(8)
            .map {
                Entry(id: $0.id,
                      title: $0.title.isEmpty ? "（未命名）" : $0.title,
                      due: $0.effectiveDue,
                      overdue: $0.isOverdue)
            }
        defaults.set(try? JSONEncoder().encode(soon), forKey: snapshotKey)
        defaults.set(Date(), forKey: updatedKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // 数据一落盘就写一次（save() 每秒都可能被 AlarmLoop 触发），
    // 所以限流：最快 45 秒写一次共享容器 + 刷一次时间线。
    private static var lastPushAt = Date.distantPast

    /// 只在主线程调用（save() 的 main.async 块里）
    static func pushThrottled(tasks: [TaskItem]) {
        guard Date().timeIntervalSince(lastPushAt) > 45 else { return }
        lastPushAt = Date()
        push(tasks: tasks)
    }
}
