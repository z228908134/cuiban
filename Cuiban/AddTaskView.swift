import SwiftUI

struct AddTaskView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TaskItem
    @State private var customInterval: String = ""
    @State private var useCustom = false

    var isEditing: Bool { draft.title != "" && store.task(id: draft.id) != nil }

    init(editing: TaskItem? = nil) {
        if let e = editing {
            _draft = State(initialValue: e)
            _useCustom = State(initialValue: e.intervalMinutes > 0 &&
                               ![1, 2, 3, 5, 10, 15, 20, 30, 60].contains(e.intervalMinutes))
            _customInterval = State(initialValue: e.intervalMinutes > 0 ? String(e.intervalMinutes) : "")
        } else {
            var d = TaskItem()
            d.dueDate = Date().addingTimeInterval(30 * 60)
            _draft = State(initialValue: d)
        }
    }

    private let presetIntervals = [1, 2, 3, 5, 10, 15, 20, 30, 60]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("做什么")) {
                    TextField("任务标题", text: $draft.title)
                    TextField("备注（可选）", text: $draft.note)
                }

                Section(header: Text("什么时候")) {
                    DatePicker(
                        "提醒时间",
                        selection: $draft.dueDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .environment(\.locale, Locale(identifier: "zh_CN"))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quick("10 分钟后", 600)
                            quick("30 分钟后", 1800)
                            quick("1 小时后", 3600)
                            quick("今晚 21:00", eveningOffset(21))
                            quick("明早 09:00", morningOffset())
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section(header: Text("没完成就多久催一次"), footer: Text("任务到期后会先响一次，之后每隔这个间隔再催，直到你点「完成」。")) {
                    Picker("提醒间隔", selection: intervalBinding) {
                        Text("跟随默认（\(store.settings.defaultIntervalMinutes) 分钟）").tag(0)
                        ForEach(presetIntervals, id: \.self) { m in
                            Text("每 \(m) 分钟").tag(m)
                        }
                        Text("自定义").tag(-1)
                    }

                    if useCustom {
                        HStack {
                            TextField("间隔分钟数", text: $customInterval)
                                .keyboardType(.numberPad)
                            Text("分钟").foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("重复")) {
                    Picker("重复方式", selection: $draft.repeatMode) {
                        ForEach(RepeatMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    if draft.repeatMode != .none {
                        Text("点「完成」后会自动生成下一次任务")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑任务" : "新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .font(.system(size: 17, weight: .semibold))
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: {
                if useCustom { return -1 }
                return draft.intervalMinutes
            },
            set: { v in
                if v == -1 {
                    useCustom = true
                    draft.intervalMinutes = Int(customInterval) ?? 1
                } else {
                    useCustom = false
                    customInterval = ""
                    draft.intervalMinutes = v
                }
            }
        )
    }

    private func save() {
        var t = draft
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.note = t.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if useCustom, let n = Int(customInterval), n >= 1 {
            t.intervalMinutes = min(n, 1440)
        } else if !useCustom && draft.intervalMinutes == -1 {
            t.intervalMinutes = 0
        }
        if t.dueDate < Date().addingTimeInterval(-60) && !t.isDone {
            t.dueDate = Date().addingTimeInterval(60)
            t.snoozeUntil = nil
        }
        store.upsert(t)
        dismiss()
    }

    private func quick(_ label: String, _ offset: TimeInterval) -> some View {
        Button {
            draft.dueDate = Date().addingTimeInterval(offset)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(brandColor.opacity(0.12))
                .foregroundColor(brandColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func eveningOffset(_ hour: Int) -> TimeInterval {
        let cal = Calendar.current
        var c = DateComponents()
        c.hour = hour
        c.minute = 0
        if let d = cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) {
            return d.timeIntervalSinceNow
        }
        return 3600
    }

    private func morningOffset() -> TimeInterval {
        let cal = Calendar.current
        var c = DateComponents()
        c.hour = 9
        c.minute = 0
        if let d = cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) {
            return d.timeIntervalSinceNow
        }
        return 3600
    }
}
