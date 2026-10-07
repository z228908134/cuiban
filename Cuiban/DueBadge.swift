import SwiftUI

/// 时间高亮标签：清单列表、任务详情、日历当天列表共用同一套配色与文案规则。
///
/// 配色分档：逾期红底 / 今天·明天橙底 / 更远蓝底 / 已完成灰底。
/// 标签只包住「时间」本身，「还有 20 小时」这类倒计时说明留在标签外，
/// 避免一整行都是底色、视觉噪音过重。
struct DueBadge: View {
    let task: TaskItem
    let now: Date
    /// 字号档：列表行 11pt，详情页 13pt
    var size: CGFloat = 11
    /// 覆盖显示的时间（日历里「重复推算」的当天时间不是 effectiveDue，用这个）
    var timeOverride: Date? = nil
    /// 覆盖倒计时说明（重复推算的任务还没到点，不该显示「还有 x 小时」）
    var extraOverride: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(parts.time)
                .font(.app(size, weight: .semibold))
                .foregroundColor(parts.fg)
                .padding(.horizontal, size >= 13 ? 8 : 6)
                .padding(.vertical, size >= 13 ? 3 : 2)
                .background(
                    RoundedRectangle(cornerRadius: size >= 13 ? 6 : 5).fill(parts.bg)
                )
            if !parts.extra.isEmpty {
                Text(parts.extra)
                    .font(.app(size))
                    .foregroundColor(task.isDone ? Color.secondary.opacity(0.7) : .secondary)
            }
        }
    }

    /// 文案拆成「标签本体 + 补充说明」两部分，按紧急程度分色
    private var parts: (time: String, extra: String, fg: Color, bg: Color) {
        if let t = timeOverride {
            // 日历的重复推算：按给定的当天时间上色，未到点就是蓝色
            let diff = t.timeIntervalSince(now)
            if diff <= 0 {
                return (timeLabel(t), extraOverride ?? "",
                        Color(red: 0.64, green: 0.18, blue: 0.18),
                        Color(red: 0.99, green: 0.92, blue: 0.92))
            }
            return (timeLabel(t), extraOverride ?? "",
                    Color(red: 0.09, green: 0.37, blue: 0.65),
                    Color(red: 0.90, green: 0.95, blue: 0.99))
        }
        if task.isDone {
            let s = task.doneAt.map { "已完成 · " + timeLabel($0) } ?? "已完成"
            return (s, "", Color.secondary, Color.primary.opacity(0.06))
        }
        let due = task.effectiveDue
        let diff = due.timeIntervalSince(now)
        // 逾期：红底
        if diff <= 0 {
            return ("已逾期 " + human(-diff), timeLabel(due),
                    Color(red: 0.64, green: 0.18, blue: 0.18),
                    Color(red: 0.99, green: 0.92, blue: 0.92))
        }
        // 今天 / 明天：橙底
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: due)).day ?? 0
        if days <= 1 {
            return ("今天 " + timeLabel(due), "还有 " + human(diff),
                    Color(red: 0.52, green: 0.31, blue: 0.04),
                    Color(red: 0.98, green: 0.91, blue: 0.84))
        }
        // 更远的：蓝底
        return (timeLabel(due), "还有 " + human(diff),
                Color(red: 0.09, green: 0.37, blue: 0.65),
                Color(red: 0.90, green: 0.95, blue: 0.99))
    }
}
