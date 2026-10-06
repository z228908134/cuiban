import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingAdd = false
    @State private var editing: TaskItem? = nil
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
                                .font(.system(size: 13))
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
        }
        .navigationViewStyle(.stack)
        .onReceive(timer) { now = $0 }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("还没有任务").font(.system(size: 15, weight: .medium))
            Text("点右下角 + 添加，到点不完成就一路催你")
                .font(.system(size: 12))
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
                    .font(.system(size: 22))
                    .foregroundColor(t.isDone ? .green : (t.isOverdue ? .red : .secondary))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(t.title.isEmpty ? "（未命名）" : t.title)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(t.isDone)
                    .foregroundColor(t.isDone ? .secondary : .primary)
                Text(dueLine(t))
                    .font(.system(size: 12))
                    .foregroundColor(t.isOverdue ? .red : .secondary)
                if !t.photos.isEmpty {
                    PhotoStrip(names: t.photos, size: 38, maxCount: 4)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 4)

            if !t.isDone {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("每 \(t.resolvedInterval(store.settings.defaultIntervalMinutes)) 分钟")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if t.nagCount > 0 {
                        Text("催 \(t.nagCount) 次")
                            .font(.system(size: 11, weight: .bold))
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
        .onTapGesture { editing = t }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.delete(id: t.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                store.snooze(id: t.id)
            } label: {
                Label("延后", systemImage: "clock.arrow.circlepath")
            }
            .tint(.orange)
        }
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
