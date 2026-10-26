import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingAdd = false
    @State private var editing: TaskItem? = nil
    @State private var detail: TaskItem? = nil
    @State private var showFinished = false
    @State private var query = ""
    /// 删除后的撤销提示条：非 nil 时显示，5.5 秒后自动收起
    @State private var deletedTitle: String? = nil
    @State private var toastToken = UUID()
    // 多选模式：批量完成 / 延后 / 删除
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmBatchDelete = false

    /// 搜索过滤：标题或备注命中都算；空白搜索词直接放行
    private func match(_ t: TaskItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return t.title.localizedCaseInsensitiveContains(q)
            || t.note.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        // 三份列表各算一次就好。原来 body 里 `store.overdue` / `upcoming` /
        // `finished` 被反复引用（overdue 3 次、finished 3 次），每引用一次
        // 就要 filter 一遍。收成局部常量后每次重绘只算一次。
        let overdue = store.overdue.filter(match)
        let upcoming = store.upcoming.filter(match)
        let hit = store.hit.filter(match)
        let finished = store.finished.filter(match)

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
                            .foregroundColor(Palette.hitGreen)
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
            .pullToRevealSearch()
            // .automatic = 系统原生行为：平时收起不占位置，下拉才露出搜索框。
            // 不要改成 .always（会常驻占一行，用户明确不要）。
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索标题 / 备注")
            .navigationTitle("催办清单")
            // 和日历页一致：标题顶格居中显示（inline 模式下 navigationTitle 默认居中）
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selecting {
                        Button(allSelected ? "全不选" : "全选") {
                            if allSelected { selected = [] } else { selected = Set(allVisibleIds) }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "完成" : "多选") {
                        selecting.toggle()
                        if !selecting { selected = [] }
                    }
                }
            }
            .confirmationDialog(
                "删除选中的 \(selected.count) 条任务？",
                isPresented: $confirmBatchDelete,
                titleVisibility: .visible
            ) {
                Button("删除 \(selected.count) 条", role: .destructive) {
                    store.deleteMany(ids: Array(selected))
                    selected = []
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些任务及其照片会被直接删除，无法恢复。")
            }
            .overlay(alignment: .bottomTrailing) {
                FabButton { showingAdd = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .overlay(alignment: .bottom) {
                if let title = deletedTitle {
                    HStack(spacing: 14) {
                        Text("已删除「\(title)」")
                            .font(.app(13))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Button("撤销") {
                            // 照片还在撤销窗口里，原位放回即可
                            store.undoDelete()
                            deletedTitle = nil
                        }
                        .font(.app(14, weight: .semibold))
                        .foregroundColor(Palette.actionBlue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color(UIColor.darkGray)))
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: deletedTitle)
            .overlay(alignment: .bottom) {
                if selecting && !selected.isEmpty {
                    batchBar
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected)
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

    // MARK: 多选

    /// 可见（含搜索过滤后）的全部任务 id，给「全选」用
    private var allVisibleIds: [String] {
        [store.overdue, store.upcoming, store.hit, store.finished]
            .flatMap { $0.filter(match) }
            .map { $0.id }
    }

    private var allSelected: Bool {
        !selected.isEmpty && selected.count == allVisibleIds.count
    }

    /// 底部批量操作条：完成 / 延后 / 删除
    private var batchBar: some View {
        HStack(spacing: 10) {
            batchBtn("checkmark.circle.fill", "完成 \(selected.count)", Palette.hitGreen) {
                store.completeMany(ids: Array(selected))
                selected = []
            }
            batchBtn("alarm.fill", "延后", Palette.snoozeOrange) {
                store.snoozeMany(ids: Array(selected))
                selected = []
            }
            batchBtn("trash.fill", "删除", Palette.deleteRed) {
                confirmBatchDelete = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 64)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func batchBtn(_ icon: String, _ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.app(13, weight: .semibold))
                Text(label).font(.app(14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 12) {
            if selecting {
                // 多选模式：勾选圈替代完成圈，点行任意处都是勾选/取消
                Image(systemName: selected.contains(t.id) ? "checkmark.circle.fill" : "circle")
                    .font(.app(22))
                    .foregroundColor(selected.contains(t.id)
                                     ? Palette.actionBlue
                                     : Color.secondary.opacity(0.6))
            } else {
                Button {
                    if t.isDone { store.uncomplete(id: t.id) } else { store.complete(id: t.id) }
                } label: {
                    Image(systemName: rowIcon(t))
                        .font(.app(22))
                        .foregroundColor(rowIconColor(t))
                }
                .buttonStyle(.plain)
            }

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
                        .foregroundColor(t.inHitGroup ? TaskListView.hitTint : .secondary)
                    if t.inHitGroup {
                        // 一月多次机会时，「下轮什么时候」比「催了几次」有用得多
                        Text("下轮 " + fmt(t.hitDeadline, "M/d HH:mm"))
                            .font(.app(10))
                            .foregroundColor(.secondary)
                    } else if t.isQuotaTask && t.hitCount > 0 {
                        // 配额型还在催抢：把「已抢 2/4」顶上来，比催了几次有用
                        Text("已抢 \(t.hitCount)/\(t.quota)")
                            .font(.app(11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(TaskListView.hitTint.opacity(0.14))
                            .foregroundColor(TaskListView.hitTint)
                            .clipShape(Capsule())
                    } else if t.nagCount > 0 {
                        Text("催 \(t.nagCount) 次")
                            .font(.app(11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .clipShape(Capsule())
                    }
                    // 设了清单结束时间的：把终点也摆在右边，
                    // 一眼能看出这条清单是「有期限的」，不是一直挂着
                    if let e = t.endDate {
                        Text("结束 " + fmt(e, "M/d HH:mm"))
                            .font(.app(10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if selected.contains(t.id) { selected.remove(t.id) } else { selected.insert(t.id) }
            } else {
                detail = t
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !selecting {
            // 蓝 / 橙 / 红三色，纯图标 + 圆形底。
            // 注意：不能给删除用 role: .destructive —— 系统会强制把 tint 覆盖成灰色，
            // 三个按钮就全灰了（之前就是这样）。所以一律普通 Button + 显式 .tint。
            // 显示顺序 = 声明顺序的倒序（trailing 边从内到外排），所以想显示成
            // 「编辑 → 延后 → 删除」就得反着声明。
            Button {
                deletedTitle = t.title
                toastToken = UUID()
                store.delete(id: t.id)
                hideToastLater(token: toastToken)
            } label: {
                swipeIcon("trash")
            }
            .tint(Palette.deleteRed)

            Button {
                store.snooze(id: t.id)
            } label: {
                swipeIcon("alarm")
            }
            .tint(Palette.snoozeOrange)

            // 抢到 / 撤销。只给抢购型任务（「做」的任务没有抢的概念）：
            //   · 单次机会型：抢到后任务不消失，催促降为每天一次，到下轮机会自动收起；
            //   · 配额型（一月 N 次）：每点一次记一次，没满继续按原节奏催。
            if !t.isDone && t.kind == .grabbing {
                Button {
                    if t.inHitGroup {
                        store.undoHit(id: t.id)
                    } else {
                        store.markHit(id: t.id)
                    }
                } label: {
                    swipeIcon(t.inHitGroup ? "arrow.uturn.backward" : "checkmark.seal.fill")
                }
                .tint(t.inHitGroup
                      ? Palette.undoGray
                      : Palette.grabGreen)
            }

            Button {
                editing = t
            } label: {
                swipeIcon("square.and.pencil")
            }
            .tint(Palette.actionBlue)
            }
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
    static let hitTint = Palette.hitGreen

    /// 删除提示条 5.5 秒后自动收起（和 TaskStore 里 6 秒的撤销窗口留出余量）。
    /// 用 token 防止连续删两条时，第一条的定时器把第二条的提示提前收掉。
    private func hideToastLater(token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [self] in
            if token == toastToken { deletedTitle = nil }
        }
    }

    /// 行首状态图标：完成 / 已抢到 / 抢到一部分 / 未完成
    private func rowIcon(_ t: TaskItem) -> String {
        if t.isDone { return "checkmark.circle.fill" }
        if t.inHitGroup { return "checkmark.seal.fill" }
        // 配额型已经抢到几次、但本周期还没抢满：半填充表示「进度中」
        if t.isQuotaTask && t.hitCount > 0 { return "circle.lefthalf.filled" }
        return "circle"
    }

    /// 行首图标颜色：已完成绿 / 已抢到青 / 抢到一部分青 / 逾期红 / 其余次要色。
    /// 写成函数而不是嵌套三元——嵌套三元 + 简写颜色（.red 这类）
    /// 会让类型推断变脆，编译容易报 ambiguous。
    private func rowIconColor(_ t: TaskItem) -> Color {
        if t.isDone { return .green }
        if t.inHitGroup { return TaskListView.hitTint }
        if t.isQuotaTask && t.hitCount > 0 { return TaskListView.hitTint }
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
        if current.inHitGroup { return "checkmark.seal.fill" }
        if current.isQuotaTask && current.hitCount > 0 { return "circle.lefthalf.filled" }
        if current.isOverdue { return "exclamationmark.circle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if current.isDone { return .green }
        if current.inHitGroup { return TaskListView.hitTint }
        if current.isQuotaTask && current.hitCount > 0 { return TaskListView.hitTint }
        if current.isOverdue { return .red }
        return .secondary
    }

    var body: some View {
        NavigationView {
            if store.task(id: task.id) == nil {
                // 详情页开着的时候任务被删掉了（比如日历左滑、
                // 或者另一处的批量清空）：
                // 别拿快照里的僵尸数据继续展示，给个明确的交代。
                goneView
            } else {
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
        }
        .navigationViewStyle(.stack)
    }

    /// 任务已被删除时的占位页
    private var goneView: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash.circle")
                .font(.app(44))
                .foregroundColor(.secondary)
            Text("任务已删除")
                .font(.app(17, weight: .semibold))
            Text("这条任务刚才被删掉了，关掉这页即可。")
                .font(.app(13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
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
            if let e = current.endDate {
                Divider().padding(.leading, 38)
                infoRow(icon: "flag.checkered", label: "清单结束",
                        value: timeLabel(e) + (current.hasEnded() ? "（已结束）" : ""))
            }
            Divider().padding(.leading, 38)
            infoRow(icon: "repeat", label: "重复",
                    value: repeatText(current))
            Divider().padding(.leading, 38)
            infoRow(icon: "timer", label: "催促间隔",
                    value: current.isDone
                        ? "—"
                        : current.nagIntervalText(store.settings.defaultIntervalMinutes))
            if current.isQuotaTask {
                Divider().padding(.leading, 38)
                infoRow(icon: "checkmark.seal", label: "本月机会",
                        value: "已抢 \(current.hitCount)/\(current.quota)"
                            + (current.hitRemaining > 0 ? "，还剩 \(current.hitRemaining) 次" : "，已抢满"))
            }
            if current.inHitGroup {
                Divider().padding(.leading, 38)
                infoRow(icon: "hand.raised", label: "抢到时间",
                        value: current.hitAt.map { timeLabel($0) } ?? "—")
                Divider().padding(.leading, 38)
                infoRow(icon: "calendar.badge.clock", label: "每天提醒至",
                        value: timeLabel(current.hitDeadline))
            } else if current.isQuotaTask {
                Divider().padding(.leading, 38)
                infoRow(icon: "calendar.badge.clock", label: "本周期至",
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
        // 抢购型专属；「做」的任务走到这就该点完成，没有「抢到」的概念
        if !current.isDone && current.kind == .grabbing {
            VStack(alignment: .leading, spacing: 10) {
                Text(hitTitle)
                    .font(.app(15, weight: .semibold))
                Text(hitDesc)
                    .font(.app(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 主按钮：抢到一次就点一次（配额型可累加，单次机会型点一下转每天提醒）
                Button {
                    store.markHit(id: current.id)
                } label: {
                    Text(current.isQuotaFull
                         ? "本月已抢满"
                         : (current.isQuotaTask
                            ? "抢到一次（\(min(current.hitCount + 1, current.quota))/\(current.quota)）"
                            : "已抢到"))
                        .font(.app(15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(current.isQuotaFull
                                    ? Color(UIColor.tertiarySystemFill)
                                    : Palette.grabGreen)
                        .foregroundColor(current.isQuotaFull ? .primary : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(current.isQuotaFull)

                if current.isHit {
                    Button {
                        store.undoHit(id: current.id)
                    } label: {
                        Text(current.isQuotaTask ? "撤销一次（-1）" : "撤销已抢到")
                            .font(.app(14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(UIColor.tertiarySystemFill))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
        }
    }

    private var hitTitle: String {
        if current.isQuotaTask {
            return current.hitCount > 0
                ? "本月已抢 \(current.hitCount)/\(current.quota)"
                : "抢到一次就点一下（本月 \(current.quota) 次机会）"
        }
        return current.inHitGroup ? "已抢到，改成每天提醒了" : "抢到了就点一下，别再高频催"
    }

    private var hitDesc: String {
        let base = baseHitDesc
        guard let e = current.endDate else { return base }
        return base + "已设清单结束时间 \(timeLabel(e))，到点任务自动完成归档，不再开下一轮。"
    }

    private var baseHitDesc: String {
        let interval = current.resolvedInterval(store.settings.defaultIntervalMinutes)
        if current.isQuotaTask {
            return "一个月 \(current.quota) 次机会、每天都能抢的任务用这个：每抢到一次就点一下，"
                + "没抢满会一直按原节奏催（每 \(interval) 分钟）；"
                + "抢满 \(current.quota) 次本周期就毕业，"
                + "没抢满则到 \(timeLabel(current.hitDeadline)) 自动作废、下个周期重新开始。"
                + "点上面的圆圈「完成」只算今天这轮做完，明天照常提醒，"
                + "本周期进度不变；想记录抢到一次就点下面的按钮。"
        }
        if current.inHitGroup {
            return "任务会留在清单的「已抢到」里，每天 \(fmt(current.dueDate, "HH:mm")) 提醒一次；"
                + "到 \(timeLabel(current.hitDeadline)) 自动收起，那时会重新开始催抢。"
        }
        return "抢购 / 报名类任务用：抢到了点一下，任务不消失，提醒从每 \(interval) 分钟降为每天一次"
            + "（沿用任务本身的时分），到下次机会时刻自动收起、重新开始催抢。"
            + "如果一个月有多次机会、每天都能抢，把「本月机会次数」调大即可。"
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
        case .everyNDays:
            let n = max(1, t.dayInterval)
            return n == 1 ? "每天" : "每 \(n) 天（一月约 \(max(1, 30 / n)) 次机会）"
        case .weekday:
            return "工作日"
        case .weekly:
            if t.weekdays.isEmpty { return "每周" }
            let names = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]
            let sorted = t.weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }
            return "每周 " + sorted.map { "周\(names[$0] ?? "?")" }.joined(separator: "、")
        case .monthly:
            return "每月"
        case .monthlyDays:
            let ds = Array(Set(t.monthDays)).filter { (1...31).contains($0) }.sorted()
            guard !ds.isEmpty else { return "每月" }
            return "每月 " + ds.map { "\($0) 号" }.joined(separator: "、")
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
