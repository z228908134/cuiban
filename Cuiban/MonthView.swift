import SwiftUI

private struct DayEntry: Identifiable {
    let id: String
    let task: TaskItem
    let date: Date
    let projected: Bool
}

/// 日历页（参考滴答清单）：
/// - 月历格子：大号公历 + 小号农历/节日（节日绿字）+ 休/班徽章 + 周任务圆点
/// - 周日那列显示周数（39周）
/// - 月末用下月日期补齐最后一行（置灰）
/// - 上滑收起成周条，下滑展开；周条 + 下方当天任务列表
/// - 当天没有任务时显示「你这一天没有任务 / 放松一下吧」空状态
struct MonthView: View {
    @EnvironmentObject var store: TaskStore
    /// 联网更新的法定节假日；数据到位后本视图自动刷新
    @StateObject private var holidayService = HolidayService.shared

    @State private var anchor: Date = Date()
    @State private var selected: Date = Calendar.current.startOfDay(for: Date())
    @State private var editing: TaskItem? = nil
    @State private var detail: TaskItem? = nil
    @State private var showingAdd = false
    /// true = 收起成周条（上滑）；默认进来就是周视图
    @State private var collapsed = true

    private let cal = Calendar.current
    private let weekNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                weekHeader
                calendarArea
                    .gesture(swipeGesture)
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
            .sheet(item: $detail) { t in
                TaskDetailView(task: t)
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

    // MARK: - 顶部月份切换（滴答式：居中大标题）

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.app(15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(collapsed
                 ? fmt(selected, "yyyy 年 M 月")
                 : fmt(anchor, "yyyy 年 M 月"))
                .font(.app(17, weight: .semibold))

            Spacer()

            Button { shift(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.app(15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekNames, id: \.self) { n in
                Text(n)
                    .font(.app(12))
                    .foregroundColor(.secondary.opacity(0.85))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 月历 / 周条

    @ViewBuilder
    private var calendarArea: some View {
        if collapsed {
            weekGrid
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    collapsed = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.app(12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            monthGrid
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                  spacing: 0) {
            ForEach(monthCells, id: \.self) { d in
                dayCell(d, dimmed: !cal.isDate(d, equalTo: anchor, toGranularity: .month))
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// 收起后的周条：所选日期所在的那一周
    private var weekGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                  spacing: 0) {
            ForEach(weekCells, id: \.self) { d in
                dayCell(d, dimmed: false)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func dotsView(_ items: [DayEntry]) -> some View {
        let dots = Array(items.prefix(3))
        return HStack(spacing: 3) {
            ForEach(dots.indices, id: \.self) { i in
                Circle()
                    .fill(dotColor(dots[i]))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 5)
    }

    /// 单个日期格子（滴答式：数字在上，农历/节日在下，休班徽章在右上）
    private func dayCell(_ d: Date, dimmed: Bool) -> some View {
        let key = cal.startOfDay(for: d)
        let items = entries[key] ?? []
        let isSelected = cal.isDate(d, inSameDayAs: selected)
        let isToday = cal.isDateInToday(d)
        let badge = LunarCalendar.holidayBadge(for: key)
        let sub = LunarCalendar.subtitle(for: key)
        let isSunday = cal.component(.weekday, from: d) == 1
        let isWeekend = cal.isDateInWeekend(d)

        // 数字颜色：选中/今日白字橙圈；周末与法定假日橙红；平时黑
        let numberColor: Color = isSelected || isToday
            ? .white
            : (isWeekend || badge != nil ? LunarCalendar.festivalColor : .primary)

        // 数字下那行：周日显示周数，其余显示农历/节气/节日
        let subText = isSunday
            ? "\(cal.component(.weekOfYear, from: d))周"
            : sub.text
        let subColor: Color = isSunday
            ? .secondary.opacity(0.55)
            : sub.color

        return Button {
            selected = key
            if !cal.isDate(d, equalTo: anchor, toGranularity: .month) {
                anchor = d
            }
        } label: {
            VStack(spacing: 1) {
                ZStack(alignment: .topTrailing) {
                    Text("\(cal.component(.day, from: d))")
                        .font(.app(17, weight: isSelected || isToday ? .semibold : .regular))
                        .foregroundColor(dimmed ? numberColor.opacity(0.35) : numberColor)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(
                                (isSelected || isToday) ? brandColor : Color.clear
                            )
                        )

                    if let b = badge {
                        Text(b)
                            .font(.app(7.5, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 12, height: 12)
                            .background(RoundedRectangle(cornerRadius: 3).fill(
                                b == "休" ? LunarCalendar.restColor : LunarCalendar.workColor
                            ))
                            .offset(x: 9, y: -4)
                    }
                }

                Text(subText)
                    .font(.app(9))
                    .foregroundColor(dimmed ? subColor.opacity(0.4) : subColor)
                    .lineLimit(1)

                dotsView(items)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
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

    // MARK: - 滑动手势：左右翻页，上滑收起，下滑展开

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                let hw = abs(v.translation.width)
                let hh = abs(v.translation.height)
                if hw > hh, hw > 50 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        shift(v.translation.width < 0 ? 1 : -1)
                    }
                } else if hh > hw, hh > 40 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        collapsed = v.translation.height < 0
                    }
                }
            }
    }

    // MARK: - 选中那天的列表

    private var daySection: some View {
        let items = dayEntries
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, collapsed ? 8 : 22)
                        .padding(.bottom, 30)
                } else {
                    HStack {
                        Text(fmt(selected, "M月d日 EEEE"))
                            .font(.app(15, weight: .semibold))
                        Spacer()
                        Text("\(items.count) 个任务")
                            .font(.app(12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    ForEach(items) { e in
                        SwipeableRow(
                            onTap: { detail = e.task },
                            onEdit: { editing = e.task },
                            onDelete: { store.delete(id: e.task.id) }
                        ) {
                            entryRow(e)
                        }
                        Divider().padding(.leading, 16)
                    }
                    Color.clear.frame(height: 24)
                }
            }
        }
    }

    /// 滴答式空状态：日历卡片插画 + 「你这一天没有任务 / 放松一下吧」
    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: 180, height: 126)
                    .rotationEffect(.degrees(-7))
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(brandColor)
                        .frame(width: 112, height: 20)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                        .frame(width: 112, height: 74)
                        .overlay(
                            Image(systemName: "checkmark.circle")
                                .font(.app(20))
                                .foregroundColor(brandColor)
                        )
                        .shadow(color: .black.opacity(0.07), radius: 7, y: 4)
                }
                .offset(y: -4)
            }
            Text("你这一天没有任务")
                .font(.app(16, weight: .medium))
            Text("放松一下吧")
                .font(.app(13))
                .foregroundColor(.secondary)
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
                    .font(.app(21))
                    .foregroundColor(e.task.isDone ? .green : (e.task.isOverdue && !e.projected ? .red : .secondary))
            }
            .buttonStyle(.plain)
            .disabled(e.projected)

            VStack(alignment: .leading, spacing: 3) {
                Text(e.task.title.isEmpty ? "（未命名）" : e.task.title)
                    .font(.app(15, weight: .semibold))
                    .foregroundColor(e.task.isDone ? .secondary : .primary)
                    .strikethrough(e.task.isDone)

                HStack(spacing: 6) {
                    Text(fmt(e.date, "HH:mm"))
                        .font(.app(11, weight: .semibold))
                        .foregroundColor(e.projected
                                         ? Color(red: 0.09, green: 0.37, blue: 0.65)
                                         : (e.task.isOverdue && !e.task.isDone
                                            ? Color(red: 0.64, green: 0.18, blue: 0.18)
                                            : Color.secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(
                                e.projected
                                ? Color(red: 0.90, green: 0.95, blue: 0.99)
                                : (e.task.isOverdue && !e.task.isDone
                                   ? Color(red: 0.99, green: 0.92, blue: 0.92)
                                   : Color.primary.opacity(0.06))
                            )
                        )
                    if e.projected {
                        Text("重复\(repeatLabel(e.task.repeatMode, weekdays: e.task.weekdays))")
                    }
                    if e.task.isOverdue && !e.task.isDone && !e.projected {
                        Text("已逾期").foregroundColor(.red)
                    }
                }
                .font(.app(11))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.app(12))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: - 数据

    /// 本月格子（含前后补位）：补位用相邻月的真实日期，置灰显示
    private var monthCells: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: anchor) else { return [] }
        let first = interval.start
        let count = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
        let leading = cal.component(.weekday, from: first) - 1
        var arr: [Date] = []
        // 上月补位
        for i in (1...max(0, leading)).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: first) {
                arr.append(d)
            }
        }
        for i in 0..<count {
            if let d = cal.date(byAdding: .day, value: i, to: first) {
                arr.append(d)
            }
        }
        // 下月补齐最后一行
        var tail = (7 - arr.count % 7) % 7
        var last = interval.end
        while tail > 0 {
            arr.append(last)
            if let next = cal.date(byAdding: .day, value: 1, to: last) { last = next }
            tail -= 1
        }
        return arr
    }

    /// 收起时：所选日期所在周的 7 天
    private var weekCells: [Date] {
        guard let interval = cal.dateInterval(of: .weekOfYear, for: selected) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var entries: [Date: [DayEntry]] {
        // 覆盖网格里可能出现的相邻月日期
        guard let interval = cal.dateInterval(of: .month, for: anchor) else { return [:] }
        let start = cal.date(byAdding: .day, value: -10, to: interval.start) ?? interval.start
        let end = cal.date(byAdding: .day, value: 14, to: interval.end) ?? interval.end
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

    // MARK: - 翻页（展开=按月，收起=按周）

    private func shift(_ delta: Int) {
        if collapsed {
            if let d = cal.date(byAdding: .day, value: delta * 7, to: selected) {
                selected = cal.startOfDay(for: d)
                anchor = d
            }
            return
        }
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

// MARK: - 左滑操作行（ScrollView 里没有系统 swipeActions，自绘实现）

/// 左滑露出「编辑 / 删除」，再滑回或点击收起；交互对齐系统 List 的左滑
private struct SwipeableRow<Content: View>: View {
    var onTap: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var revealed = false
    @State private var isDragging = false
    @State private var dragX: CGFloat = 0
    private let revealWidth: CGFloat = 128

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Button {
                    close()
                    onEdit()
                } label: {
                    op(icon: "pencil", title: "编辑", color: Color(red: 0.2, green: 0.5, blue: 1.0))
                        .frame(width: 64)
                }
                .buttonStyle(.plain)
                Button {
                    close()
                    onDelete()
                } label: {
                    op(icon: "trash", title: "删除", color: .red)
                        .frame(width: 64)
                }
                .buttonStyle(.plain)
            }
            content()
                .background(Color(UIColor.systemBackground))
                .offset(x: offset)
                .contentShape(Rectangle())
                .onTapGesture {
                    if revealed {
                        close()
                    } else {
                        onTap()
                    }
                }
                .gesture(swipe)
        }
        .clipped()
    }

    private var offset: CGFloat {
        let base: CGFloat = revealed ? -revealWidth : 0
        return isDragging ? min(0, max(-revealWidth - 40, base + dragX)) : base
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { revealed = false }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                // 垂直滑动交给 ScrollView，只有横向为主时才接管
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                isDragging = true
                dragX = v.translation.width
            }
            .onEnded { v in
                guard isDragging else { return }
                isDragging = false
                dragX = 0
                let target = (revealed ? -revealWidth : 0) + v.translation.width
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    revealed = target < -revealWidth / 2
                }
            }
    }

    private func op(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.app(15, weight: .medium))
            Text(title)
                .font(.app(11, weight: .medium))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color)
    }
}
