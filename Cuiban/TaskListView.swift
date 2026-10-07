import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingAdd = false
    @State private var editing: TaskItem? = nil
    @State private var detail: TaskItem? = nil
    @State private var now = Date()
    @State private var showFinished = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                if !store.overdue.isEmpty {
                    Section {
                        ForEach(store.overdue) { t in
                            row(t)
                        }
                    } header: {
                        Label("逾期未完成 · \(store.overdue.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }

                Section {
                    if store.upcoming.isEmpty && store.overdue.isEmpty {
                        emptyHint
                    } else {
                        ForEach(store.upcoming) { t in
                            row(t)
                        }
                    }
                } header: {
                    Text("待办")
                }

                if !store.finished.isEmpty {
                    Section {
                        ForEach(showFinished ? store.finished : Array(store.finished.prefix(2))) { t in
                            row(t)
                        }
                        Button {
                            showFinished.toggle()
                        } label: {
                            Text(showFinished ? "收起已完成" : "展开已完成 (\(store.finished.count))")
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
        .onReceive(timer) { now = $0 }
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
                Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.app(22))
                    .foregroundColor(t.isDone ? .green : (t.isOverdue ? .red : .secondary))
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
                    Text("每 \(t.resolvedInterval(store.settings.defaultIntervalMinutes)) 分钟")
                        .font(.app(11))
                        .foregroundColor(.secondary)
                    if t.nagCount > 0 {
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
            .buttonStyle(.plain)
            .tint(Color(red: 0.90, green: 0.23, blue: 0.22))

            Button {
                store.snooze(id: t.id)
            } label: {
                swipeIcon("alarm")
            }
            .buttonStyle(.plain)
            .tint(Color(red: 0.98, green: 0.58, blue: 0.00))

            Button {
                editing = t
            } label: {
                swipeIcon("square.and.pencil")
            }
            .buttonStyle(.plain)
            .tint(Color(red: 0.19, green: 0.47, blue: 0.96))
        }
    }

    /// 左滑按钮里的白色图标 + 圆形半透明底
    private func swipeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.app(18, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white.opacity(0.25)))
    }

    /// 时间高亮标签：清单列表 / 详情页 / 日历共用 DueBadge，这里只包一层保持调用点简洁
    private func dueBadge(_ t: TaskItem) -> some View {
        DueBadge(task: t, now: now, size: 11)
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

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    infoBlock
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
            Image(systemName: current.isDone
                  ? "checkmark.circle.fill"
                  : (current.isOverdue ? "exclamationmark.circle.fill" : "circle"))
                .font(.app(24))
                .foregroundColor(current.isDone
                                 ? .green
                                 : (current.isOverdue ? .red : .secondary))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(current.title.isEmpty ? "（未命名）" : current.title)
                    .font(.app(20, weight: .semibold))
                    .strikethrough(current.isDone)
                    .foregroundColor(current.isDone ? .secondary : .primary)
                // 和清单列表用同一套高亮标签，详情页不再退回纯文字
                DueBadge(task: current, now: Date(), size: 13)
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
                        : "每 \(current.resolvedInterval(store.settings.defaultIntervalMinutes)) 分钟")
            if current.nagCount > 0 {
                Divider().padding(.leading, 38)
                infoRow(icon: "megaphone", label: "已催促", value: "\(current.nagCount) 次")
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
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
