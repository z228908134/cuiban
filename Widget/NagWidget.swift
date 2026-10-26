import WidgetKit
import SwiftUI

// 催办小组件：桌面 + 锁屏。
// 数据来自主 App 写进 App Group 的快照（见主 App 的 WidgetSync.swift），
// 字段结构和主 App 侧的 WidgetSync.Entry 保持同构 —— 两边要一起改。

struct WEntry: Codable, Identifiable {
    let id: String
    let title: String
    let due: Date
    let overdue: Bool
}

/// 从 App Group 容器读快照。拿不到容器（未授权/没装主 App）就返回空，
/// 界面上显示引导文案，不会崩。
private enum SnapshotStore {
    static let appGroup = "group.com.cuiban.app"

    static func load() -> [WEntry] {
        guard let d = UserDefaults(suiteName: appGroup)?.data(forKey: "widget_snapshot"),
              let list = try? JSONDecoder().decode([WEntry].self, from: d) else { return [] }
        return list
    }

    static var updatedAt: Date? {
        UserDefaults(suiteName: appGroup)?.object(forKey: "widget_updated") as? Date
    }
}

struct NagTimelineEntry: TimelineEntry {
    let date: Date
    let items: [WEntry]
    /// 从来没同步过（用户还没打开过主 App）
    let neverSynced: Bool
}

struct NagProvider: TimelineProvider {
    private func makeEntry(date: Date) -> NagTimelineEntry {
        let items = SnapshotStore.load()
        return NagTimelineEntry(date: date, items: items, neverSynced: SnapshotStore.updatedAt == nil)
    }

    func placeholder(in context: Context) -> NagTimelineEntry {
        NagTimelineEntry(date: Date(), items: NagProvider.sample, neverSynced: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (NagTimelineEntry) -> Void) {
        completion(context.isPreview
                   ? NagTimelineEntry(date: Date(), items: NagProvider.sample, neverSynced: false)
                   : makeEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NagTimelineEntry>) -> Void) {
        // 快照是静态的，主 App 改数据会主动 reload；
        // 这里每半小时兜底刷一次（时间流逝导致的逾期状态变化）
        var entries: [NagTimelineEntry] = []
        let now = Date()
        for m in stride(from: 0, through: 180, by: 30) {
            entries.append(makeEntry(date: now.addingTimeInterval(Double(m) * 60)))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// 相册里的预览样张
    static let sample: [WEntry] = [
        WEntry(id: "s1", title: "抢购开闹钟", due: Date().addingTimeInterval(600), overdue: false),
        WEntry(id: "s2", title: "提交日报", due: Date().addingTimeInterval(3600), overdue: false),
        WEntry(id: "s3", title: "回邮件", due: Date().addingTimeInterval(-1800), overdue: true),
    ]
}

// MARK: - 视图

private func hhmm(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

/// iOS 17 起小组件必须用 containerBackground，16 及以下用普通背景
private extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget) { Color(UIColor.systemBackground) }
        } else {
            background(Color(UIColor.systemBackground))
        }
    }
}

private struct TaskRow: View {
    let e: WEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(hhmm(e.due))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(e.overdue ? .red : .secondary)
                .fixedSize()
            Text(e.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyState: View {
    let neverSynced: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.badge")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(neverSynced ? "打开催办 App 同步一次" : "暂时没有要催的任务")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SmallView: View {
    let entry: NagTimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("接下来要催", systemImage: "bell.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange)
            if entry.items.isEmpty {
                EmptyState(neverSynced: entry.neverSynced)
            } else {
                ForEach(Array(entry.items.prefix(3))) { TaskRow(e: $0) }
                Spacer(minLength: 0)
                Text("\(entry.items.count) 条待催")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(2)
        .widgetBackground()
    }
}

private struct MediumView: View {
    let entry: NagTimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("接下来要催", systemImage: "bell.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)
            if entry.items.isEmpty {
                EmptyState(neverSynced: entry.neverSynced)
            } else {
                ForEach(Array(entry.items.prefix(4))) { TaskRow(e: $0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(2)
        .widgetBackground()
    }
}

// MARK: 锁屏 accessory 家族（iOS 16+）

private struct InlineView: View {
    let entry: NagTimelineEntry

    var body: some View {
        if entry.items.isEmpty {
            Text("催办：没有待办")
        } else {
            let e = entry.items[0]
            Text("\(hhmm(e.due)) \(e.title)")
        }
    }
}

private struct RectangularView: View {
    let entry: NagTimelineEntry

    var body: some View {
        if entry.items.isEmpty {
            VStack(alignment: .leading) {
                Text("催办").font(.system(size: 12, weight: .bold))
                Text(entry.neverSynced ? "打开 App 同步一次" : "没有待催任务")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entry.items.prefix(3))) { e in
                    HStack(spacing: 4) {
                        Text(hhmm(e.due))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(e.overdue ? .red : .secondary)
                            .fixedSize()
                        Text(e.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct CircularView: View {
    let entry: NagTimelineEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("\(entry.items.count)")
                    .font(.system(size: 16, weight: .bold))
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

// MARK: - Widget 注册

struct NagWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NagTimelineEntry

    @ViewBuilder
    var body: some View {
        switch family {
        case .systemSmall: SmallView(entry: entry)
        case .systemMedium: MediumView(entry: entry)
        case .accessoryInline: InlineView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryCircular: CircularView(entry: entry)
        default: SmallView(entry: entry)
        }
    }
}

struct NagWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NagWidget", provider: NagProvider()) { entry in
            NagWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("催办")
        .description("接下来要催的任务，桌面和锁屏一眼看到。")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular, .accessoryCircular,
        ])
    }
}

@main
struct CuibanWidgetBundle: WidgetBundle {
    var body: some Widget {
        NagWidget()
    }
}
