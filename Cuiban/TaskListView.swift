import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingAdd = false
    @State private var editing: TaskItem? = nil
    @State private var detail: TaskItem? = nil
    @State private var showFinished = false

    var body: some View {
        // 三份列表各算一次就好。原来 body 里 `store.overdue` / `upcoming` /
        // `finished` 被反复引用（overdue 3 次、finished 3 次），每引用一次
        // 就要 filter 一遍。收成局部常量后每次重绘只算一次。
        let overdue = store.overdue
        let upcoming = store.upcoming
        let hit = store.hit
        let finished = store.finished

        return NavigationView {
            List {
                if !overdue.isEmpty {
                    Section {
                        ForEach(overdue) { t in
                            row(t)
                        }
                    } header: {
                        Label("逾期未完成 · \(overdue.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }

                Section {
                    if upcoming.isEmpty && overdue.isEmpty && hit.isEmpty {
                        emptyHint
                    } else {
                        ForEach(upcoming) { t in
                            row(t)
                        }
                    }
                } header: {
                    Text("待办")
                }

                // 已抢到：机会已经拿下，但活动还在继续，改成每天提醒。
                // 单独一组，既不混进「逾期」（会造成焦虑），也不会掉出列表。
                if !hit.isEmpty {
                    Section {
                        ForEach(hit) { t in
                            row(t)
                        }
                    } header: {
                        Label("已抢到 · 每天提醒 · \(hit.count)", systemImage: "checkmark.seal.fill")
                            .foregroundColor(Color(red: 0.05, green: 0.43, blue: 0.34))
                    }
                }

                if !finished.isEmpty {
                    Section {
                        ForEach(showFinished ? finished : Array(finished.prefix(2))) { t in
                            row(t)
                        }
                        Button {
                            showFinished.toggle()
                        } label: {
                            Text(showFinished ? "收起已完成" : "展开已完成 (\(finished.count))")
                                .font(.app(13))
                        }
                    } header: {
                        Text("已完成")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("催办清单")
            // 和日历页一致：标题顶格居中显示（inline 模式下 navigationTitle 默认居中）
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                FabButton { showingAdd = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .sheet(isPresented: $showingAdd) {
                AddTaskView()
            }
            .sheet(item: $editing) { t in
                AddTaskView(editing: t)
            }
            .sheet(item: $detail) { t in
                TaskDetailView(task: t)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.app(34))
                .foregroundColor(.secondary)
            Text("还没有任务").font(.app(15, weight: .medium))
            Text("点右下角 + 添加，到点不完成就一路催你")
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 12) {
            Button {
                if t.isDone { store.uncomplete(id: t.id) } else { store.complete(id: t.id) }
            } label: {
                Image(systemName: rowIcon(t))
                    .font(.app(22))
                    .foregroundColor(rowIconColor(t))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(t.title.isEmpty ? "（未命名）" : t.title)
                    .font(.app(16, weight: .semibold))
                    .strikethrough(t.isDone)
                    .foregroundColor(t.isDone ? .secondary : .primary)
                dueBadge(t)
            }

            Spacer(minLength: 4)

            if !t.isDone {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(t.nagIntervalText(store.settings.defaultIntervalMinutes))
                        .font(.app(11))
                        .foregroundColor(t.isHit ? Color(red: 0.05, green: 0.43, blue: 0.34) : .secondary)
                    if t.nagCount > 0 && !t.isHit {
                        Text("催 \(t.nagCount) 次")
                            .font(.app(11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { detail = t }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 蓝 / 橙 / 红三色，纯图标 + 圆形底。
            // 注意：不能给删除用 role: .destructive —— 系统会强制把 tint 覆盖成灰色，
            // 三个按钮就全灰了（之前就是这样）。所以一律普通 Button + 显式 .tint。
            // 显示顺序 = 声明顺序的倒序（trailing 边从内到外排），所以想显示成
            // 「编辑 → 延后 → 删除」就得反着声明。
            Button {
                store.delete(id: t.id)
            } label: {
                swipeIcon("trash")
            }
            .tint(Color(red: 0.90, green: 0.23, blue: 0.22))

            Button {
                store.snooze(id: t.id)
            } label: {
                swipeIcon("alarm")
            }
            .tint(Color(red: 0.98, green: 0.58, blue: 0.00))

            // 已抢到 / 撤销已抢到。抢购类任务用：抢中之后任务不消失，
            // 催促降频成每天一次（沿用任务原本的时分），到下月机会时刻自动收起。
            if !t.isDone {
                Button {
                    if t.isHit {
                        store.undoHit(id: t.id)
                    } else {
                        store.markHit(id: t.id)
                    }
                } label: {
                    swipeIcon(t.isHit ? "arrow.uturn.backward" : "checkmark.seal.fill")
                }
                .tint(t.isHit
                      ? Color(red: 0.42, green: 0.44, blue: 0.47)
                      : Color(red: 0.05, green: 0.53, blue: 0.42))
            }

            Button {
                editing = t
            } label: {
                swipeIcon("square.and.pencil")
            }
            .tint(Color(red: 0.19, green: 0.47, blue: 0.96))
        }
    }

    /// 左滑按钮里的图标。底色交给系统按 .tint 上色，
    /// 这里不要自绘背景，也不要给按钮加 .buttonStyle(.plain)——plain 会关掉 tint 上色、按钮全灰。
    private func swipeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.app(19, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
    }

    /// 已抢到的青色：既不刺眼又能一眼看出「这条已经拿下了」
    static let hitTint = Color(red: 0.05, green: 0.43, blue: 0.34)

    /// 行首状态图标：完成 / 已抢到 / 未完成
    private func rowIcon(_ t: TaskItem) -> String {
        if t.isDone { return "checkmark.circle.fill" }
        if t.isHit { return "checkmark.seal.fill" }
        return "circle"
    }

    /// 行首图标颜色：已完成绿 / 已抢到青 / 逾期红 / 其余次要色。
    /// 写成函数而不是嵌套三元——嵌套三元 + 简写颜色（.red 这类）
    /// 会让类型推断变脆，编译容易报 ambiguous。
    private func rowIconColor(_ t: TaskItem) -> Color {
        if t.isDone { return .green }
        if t.isHit { return TaskListView.hitTint }
        if t.isOverdue { return .red }
        return .secondary
    }

    /// 时间高亮标签：清单列表 / 详情页 / 日历共用 DueBadge，这里只包一层保持调用点简洁。
    /// 不传 now：标签自己走表，清单页不再为它每秒重建整棵列表。
    private func dueBadge(_ t: TaskItem) -> some View {
        DueBadge(task: t, size: 11)
    }

    // 时间文案统一走 DueBadge，不再保留纯文字版本
}

// MARK: - 任务详情页
//
// 点清单里的任务先进这里看，不直接进编辑页；编辑入口：
//   1. 详情页右上角「编辑」
//   2. 清单页该任务左滑的「编辑」

struct TaskDetailView: View {
    @EnvironmentObject var store: TaskStore
    /// 详情页打开期间列表里的任务可能被改，每次渲染都从 store 取最新
    let task: TaskItem

    @State private var editing: TaskItem? = nil
    @State private var viewerOpen = false
    @State private var viewerStart = 0

    private var current: TaskItem { store.task(id: task.id) ?? task }

    private var statusIcon: String {
        if current.isDone { return "checkmark.circle.fill" }
        if current.isHit { return "checkmark.seal.fill" }
        if current.isOverdue { return "exclamationmark.circle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if current.isDone { return .green }
        if current.isHit { return TaskListView.hitTint }
        if current.isOverdue { return .red }
        return .secondary
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    infoBlock
                    hitBlock
                    if !current.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        noteBlock
                    }
                    if !current.photos.isEmpty {
                        photoBlock
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editing = current
                    } label: {
                        Text("编辑")
                            .font(.app(16, weight: .semibold))
                    }
                }
            }
            .sheet(item: $editing) { t in
                AddTaskView(editing: t)
            }
            .fullScreenCover(isPresented: $viewerOpen) {
                PhotoViewer(
                    images: current.photos.compactMap { AttachmentStore.load($0) },
                    titles: current.photos.indices.map { "第 \($0 + 1) 张，共 \(current.photos.count) 张" },
                    start: viewerStart
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 标题

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.app(24))
                .foregroundColor(statusColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(current.title.isEmpty ? "（未命名）" : current.title)
                    .font(.app(20, weight: .semibold))
                    .strikethrough(current.isDone)
                    .foregroundColor(current.isDone ? .secondary : .primary)
                // 和清单列表用同一套高亮标签，详情页不再退回纯文字
                DueBadge(task: current, size: 13)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    // MARK: 时间 / 重复 / 间隔

    private var infoBlock: some View {
        VStack(spacing: 0) {
            infoRow(icon: "bell", label: "提醒时间", value: timeLabel(current.effectiveDue))
            Divider().padding(.leading, 38)
            infoRow(icon: "repeat", label: "重复",
                    value: repeatText(current))
            Divider().padding(.leading, 38)
            infoRow(icon: "timer", label: "催促间隔",
                    value: current.isDone
                        ? "—"
                        : current.nagIntervalText(store.settings.defaultIntervalMinutes))
            if current.isHit {
                Divider().padding(.leading, 38)
                infoRow(icon: "hand.raised", label: "抢到时间",
                        value: current.hitAt.map { timeLabel($0) } ?? "—")
                Divider().padding(.leading, 38)
                infoRow(icon: "calendar.badge.clock", label: "每天提醒至",
                        value: timeLabel(current.hitDeadline))
            }
            if current.nagCount > 0 {
                Divider().padding(.leading, 38)
                infoRow(icon: "megaphone", label: "已催促", value: "\(current.nagCount) 次")
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    // MARK: 已抢到（每月一次机会的抢购 / 报名类任务）

    @ViewBuilder
    private var hitBlock: some View {
        if !current.isDone {
            VStack(alignment: .leading, spacing: 10) {
                Text(current.isHit ? "已抢到，改成每天提醒了" : "抢到了就点一下，别再高频催")
                    .font(.app(15, weight: .semibold))
                Text(current.isHit
                     ? "任务会留在清单的「已抢到」里，每天 \(fmt(current.dueDate, "HH:mm")) 提醒一次；"
                        + "到 \(timeLabel(current.hitDeadline)) 自动收起，那时会重新开始催抢。"
                     : "适合「活动持续一月、但一月只有一次机会」的任务。点了之后任务不消失，"
                        + "提醒从每 \(current.resolvedInterval(store.settings.defaultIntervalMinutes)) 分钟降为每天一次"
                        + "（沿用任务本身的时分），到下次机会时刻自动收起。")
                    .font(.app(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if current.isHit {
                        store.undoHit(id: current.id)
                    } else {
                        store.markHit(id: current.id)
                    }
                } label: {
                    Text(current.isHit ? "撤销已抢到" : "已抢到")
                        .font(.app(15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(current.isHit
                                    ? Color(UIColor.tertiarySystemFill)
                                    : Color(red: 0.05, green: 0.53, blue: 0.42))
                        .foregroundColor(current.isHit ? .primary : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.app(14))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.app(14))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.app(14, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func repeatText(_ t: TaskItem) -> String {
        switch t.repeatMode {
        case .none:
            return "不重复"
        case .daily:
            return "每天"
        case .weekday:
            return "工作日"
        case .weekly:
            if t.weekdays.isEmpty { return "每周" }
            let names = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]
            let sorted = t.weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }
            return "每周 " + sorted.map { "周\(names[$0] ?? "?")" }.joined(separator: "、")
        case .monthly:
            return "每月"
        }
    }

    private func dueLine(_ t: TaskItem) -> String {
        if t.isDone {
            if let d = t.doneAt { return "已完成 · " + timeLabel(d) }
            return "已完成"
        }
        let due = t.effectiveDue
        let now = Date()
        let diff = due.timeIntervalSince(now)
        if diff <= 0 {
            return timeLabel(due) + " · 已逾期 " + human(-diff)
        }
        return timeLabel(due) + " · 还有 " + human(diff)
    }

    // MARK: 备注

    private var noteLines: [String] {
        current.note
            .components(separatedBy: "\n")
    }

    private var noteBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("备注", systemImage: "text.alignleft")
                .font(.app(13, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(noteLines.enumerated()), id: \.offset) { _, line in
                    noteLineView(line)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    /// 备注里的勾选行：画出来的方框 + 勾了整句删除线置灰，和笔记编辑器一致
    @ViewBuilder
    private func noteLineView(_ line: String) -> some View {
        let info = TextEditBridge.markInfo(in: line)
        let checked = info?.checked ?? false
        if let body = TextEditBridge.stripMark(in: line) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.app(14))
                    .foregroundColor(checked ? .blue : .secondary)
                    .padding(.top, 2.5)
                if body.isEmpty {
                    Rectangle().fill(Color.clear).frame(height: 1)
                } else {
                    Text(body)
                        .font(.app(15))
                        .strikethrough(checked)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(checked ? .secondary : .primary)
                }
            }
        } else {
            Text(line)
                .font(.app(15))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 照片

    private var photoBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("照片 · \(current.photos.count) 张", systemImage: "photo.on.rectangle.angled")
                .font(.app(13, weight: .medium))
                .foregroundColor(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(current.photos.indices, id: \.self) { i in
                    if let img = AttachmentStore.load(current.photos[i]) {
                        Button {
                            viewerStart = i
                            viewerOpen = true
                        } label: {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }
}
