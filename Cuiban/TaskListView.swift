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
            .navigationTitle("催办")
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
        .listRowBackground(Color.clear)
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
            Button(role: .destructive) {
                store.delete(id: t.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editing = t
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            .tint(.blue)
            Button {
                store.snooze(id: t.id)
            } label: {
                Label("延后", systemImage: "clock.arrow.circlepath")
            }
            .tint(.orange)
        }
    }

    /// 时间高亮标签：逾期红、当天橙、以后蓝、已完成灰。
    /// 标签只包住时间本身，「还有 20 小时」这类说明留在标签外，避免一整行都是底色。
    private func dueBadge(_ t: TaskItem) -> some View {
        let parts = dueParts(t)
        return HStack(spacing: 5) {
            Text(parts.time)
                .font(.app(11, weight: .semibold))
                .foregroundColor(parts.fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(parts.bg)
                )
            if !parts.extra.isEmpty {
                Text(parts.extra)
                    .font(.app(11))
                    .foregroundColor(t.isDone ? Color.secondary.opacity(0.7) : .secondary)
            }
        }
    }

    /// 时间文案拆成「标签本体 + 补充说明」两部分，按紧急程度分色
    private func dueParts(_ t: TaskItem) -> (time: String, extra: String, fg: Color, bg: Color) {
        if t.isDone {
            let s = t.doneAt.map { "已完成 · " + timeLabel($0) } ?? "已完成"
            return (s, "", Color.secondary, Color.primary.opacity(0.06))
        }
        let due = t.effectiveDue
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

    private func dueLine(_ t: TaskItem) -> String {
        if t.isDone {
            if let d = t.doneAt { return "已完成 · " + timeLabel(d) }
            return "已完成"
        }
        let due = t.effectiveDue
        let diff = due.timeIntervalSince(now)
        if diff <= 0 {
            return timeLabel(due) + " · 已逾期 " + human(-diff)
        }
        return timeLabel(due) + " · 还有 " + human(diff)
    }
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
                Text(dueLine(current))
                    .font(.app(13))
                    .foregroundColor(current.isDone
                                     ? .secondary
                                     : (current.isOverdue ? .red : .secondary))
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
