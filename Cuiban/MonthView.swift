import SwiftUI

private struct DayEntry: Identifiable {
    let id: String
    let task: TaskItem
    let date: Date
    let projected: Bool
}

struct MonthView: View {
    @EnvironmentObject var store: TaskStore
    /// 联网更新的法定节假日；数据到位后本视图自动刷新
    @StateObject private var holidayService = HolidayService.shared

    @State private var anchor: Date = Date()
    @State private var selected: Date = Calendar.current.startOfDay(for: Date())
    @State private var editing: TaskItem? = nil
    @State private var showingAdd = false

    private let cal = Calendar.current
    private let weekNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                weekHeader
                gridView
                Divider()
                daySection
            }
            .navigationTitle("日历")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                FabButton { showingAdd = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let t = Date()
                        anchor = t
                        selected = cal.startOfDay(for: t)
                    } label: {
                        Text("今天")
                    }
                }
            }
            .sheet(item: $editing) { t in
                AddTaskView(editing: t)
            }
            .sheet(isPresented: $showingAdd) {
                AddTaskView()
            }
            .onAppear {
                holidayService.refreshIfNeeded()
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 顶部月份切换

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(fmt(anchor, "yyyy 年 M 月"))
                    .font(.system(size: 17, weight: .semibold))
                Text(monthSummary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekNames, id: \.self) { n in
                Text(n)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    private var gridView: some View {
        let days = monthDays
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                         spacing: 2) {
            ForEach(days.indices, id: \.self) { i in
                if let d = days[i] {
                    dayCell(d)
                } else {
                    Color.clear.frame(height: 58)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func dotsView(_ items: [DayEntry]) -> some View {
        let dots = Array(items.prefix(3))
        return HStack(spacing: 3) {
            ForEach(dots.indices, id: \.self) { i in
                Circle()
                    .fill(dotColor(dots[i]))
                    .frame(width: 4.5, height: 4.5)
            }
        }
        .frame(height: 6)
    }

    private func dayCell(_ d: Date) -> some View {
        let key = cal.startOfDay(for: d)
        let items = entries[key] ?? []
        let isSelected = cal.isDate(d, inSameDayAs: selected)
        let isToday = cal.isDateInToday(d)
        let badge = LunarCalendar.holidayBadge(for: key)
        let sub = LunarCalendar.subtitle(for: key)
        // 放假日的数字用节日橙，一眼看出连休
        let numberColor: Color = isSelected
            ? .white
            : (badge == "休" ? LunarCalendar.festivalColor : (isToday ? brandColor : .primary))

        return Button {
            selected = key
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Text("\(cal.component(.day, from: d))")
                        .font(.system(size: 15, weight: isSelected || isToday ? .bold : .regular))
                        .foregroundColor(numberColor)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(isSelected ? brandColor
                                          : (isToday ? brandColor.opacity(0.13) : Color.clear))
                        )

                    if let b = badge {
                        Text(b)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(b == "休" ? LunarCalendar.restColor
                                                       : LunarCalendar.workColor))
                            .offset(x: 6, y: -4)
                    }
                }

                Text(sub.text)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : sub.color)
                    .lineLimit(1)

                dotsView(items)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ e: DayEntry) -> Color {
        if e.task.isDone { return Color.gray.opacity(0.55) }
        if e.task.isOverdue { return .red }
        if e.projected { return brandColor.opacity(0.55) }
        return brandColor
    }

    // MARK: - 选中那天的列表

    private var daySection: some View {
        let items = dayEntries
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(fmt(selected, "M月d日 EEEE"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(items.isEmpty ? "没有任务" : "\(items.count) 个任务")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

                if items.isEmpty {
                    Text("这一天还没有安排，点右下角 + 新建，或在「清单」里把任务挪过来。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                } else {
                    ForEach(items) { e in
                        entryRow(e)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func entryRow(_ e: DayEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                if e.task.isDone {
                    store.uncomplete(id: e.task.id)
                } else if !e.projected {
                    store.complete(id: e.task.id)
                }
            } label: {
                Image(systemName: e.task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundColor(e.task.isDone ? .green : (e.task.isOverdue && !e.projected ? .red : .secondary))
            }
            .buttonStyle(.plain)
            .disabled(e.projected)

            VStack(alignment: .leading, spacing: 3) {
                Text(e.task.title.isEmpty ? "（未命名）" : e.task.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(e.task.isDone ? .secondary : .primary)
                    .strikethrough(e.task.isDone)

                HStack(spacing: 6) {
                    Text(fmt(e.date, "HH:mm"))
                    if e.projected {
                        Text("重复\(repeatLabel(e.task.repeatMode, weekdays: e.task.weekdays))")
                    }
                    if e.task.isOverdue && !e.task.isDone && !e.projected {
                        Text("已逾期").foregroundColor(.red)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)

                if !e.task.photos.isEmpty {
                    PhotoStrip(names: e.task.photos, size: 34, maxCount: 4)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { editing = e.task }
    }

    // MARK: - 数据

    private var monthDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: anchor) else { return [] }
        let first = interval.start
        let count = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
        let leading = cal.component(.weekday, from: first) - 1
        var arr: [Date?] = Array(repeating: nil, count: max(0, leading))
        for i in 0..<count {
            arr.append(cal.date(byAdding: .day, value: i, to: first))
        }
        while arr.count % 7 != 0 { arr.append(nil) }
        return arr
    }

    private var entries: [Date: [DayEntry]] {
        guard let interval = cal.dateInterval(of: .month, for: anchor) else { return [:] }
        let start = interval.start
        let end = interval.end
        var map: [Date: [DayEntry]] = [:]

        for t in store.tasks {
            if t.repeatMode == .none || t.isDone {
                let d = t.effectiveDue
                if d >= start && d < end {
                    map[cal.startOfDay(for: d), default: []].append(
                        DayEntry(id: t.id + "-0", task: t, date: d, projected: false)
                    )
                }
            } else {
                for (i, d) in t.projectedDates(until: end).enumerated() where d >= start && d < end {
                    map[cal.startOfDay(for: d), default: []].append(
                        DayEntry(id: t.id + "-\(i)", task: t, date: d, projected: true)
                    )
                }
            }
        }
        return map
    }

    private var dayEntries: [DayEntry] {
        (entries[cal.startOfDay(for: selected)] ?? []).sorted { $0.date < $1.date }
    }

    private var monthSummary: String {
        let n = entries.values.reduce(0) { $0 + $1.count }
        return n == 0 ? "本月没有任务" : "本月共 \(n) 个任务"
    }

    // MARK: - 翻月

    private func shift(_ delta: Int) {
        guard let newAnchor = cal.date(byAdding: .month, value: delta, to: anchor) else { return }
        anchor = newAnchor
        let day = cal.component(.day, from: selected)
        if let interval = cal.dateInterval(of: .month, for: newAnchor) {
            let maxDay = cal.range(of: .day, in: .month, for: newAnchor)?.count ?? 28
            let target = min(day, maxDay)
            selected = cal.date(byAdding: .day, value: target - 1, to: interval.start) ?? interval.start
        }
    }
}
