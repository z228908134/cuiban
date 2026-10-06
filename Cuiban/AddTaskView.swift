import SwiftUI

struct AddTaskView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TaskItem
    @State private var customInterval: String = ""
    @State private var useCustom = false

    // 图片识别相关
    private enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }
    @State private var photoSource: PhotoSource? = nil
    @State private var pickedImage: UIImage? = nil
    @State private var scanning = false
    @State private var parseSummary: String? = nil
    @State private var tipsShown: [String] = []
    @State private var titleAutoFilled = false

    // AI 相关
    @ObservedObject private var ai = AIStore.shared
    @State private var aiInput = ""
    @State private var aiBusy = false
    @State private var aiError: String? = nil

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
                if ai.enabled { aiSection }

                photoSection

                Section(header: Text("做什么")) {
                    TextField("任务标题", text: $draft.title)
                }

                Section(header: Text("备注")) {
                    noteEditor
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

                Section(header: Text("重复"), footer: Text(repeatFooter)) {
                    Picker("重复方式", selection: $draft.repeatMode) {
                        ForEach(RepeatMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    if draft.repeatMode == .weekly {
                        weekdayChips
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
        .sheet(item: $photoSource) { src in
            ImagePicker(sourceType: src == .camera ? .camera : .photoLibrary) { img in
                photoSource = nil
                handlePicked(img)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - AI 智能解析

    @ViewBuilder
    private var aiSection: some View {
        Section(header: Text("用一句话说"),
                footer: Text("打一句话让 AI 帮你抽时间、标题和重复规则；选图识别时也会让 AI 再复核一遍。需要联网，用的是你自己在「设置」里填的 API。")) {
            HStack(spacing: 8) {
                TextField("例如：下周一上午 10 点开周会，每周一次", text: $aiInput)
                    .submitLabel(.done)
                    .onSubmit { runAIText() }
                if aiBusy {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button("解析") { runAIText() }
                        .disabled(aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let e = aiError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(e).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundColor(.red)
            }
        }
    }

    private func runAIText() {
        let text = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        aiBusy = true
        aiError = nil
        AIService.parse(text: text) { res in
            DispatchQueue.main.async {
                aiBusy = false
                switch res {
                case .success(let r):
                    merge(r)
                    parseSummary = "AI：" + r.summaryText()
                case .failure(let e):
                    aiError = e.localizedDescription
                }
            }
        }
    }

    /// 图片 OCR 之后，可选地让 AI 再解析一遍
    private func refineWithAI(_ text: String) {
        guard ai.ready, !text.isEmpty else { return }
        aiBusy = true
        AIService.parse(text: text) { res in
            DispatchQueue.main.async {
                aiBusy = false
                switch res {
                case .success(let r):
                    merge(r)
                    parseSummary = "AI：" + r.summaryText()
                case .failure(let e):
                    aiError = "AI 复核失败，已用本机识别的结果（\(e.localizedDescription)）"
                }
            }
        }
    }

    // MARK: - 从图片识别

    @ViewBuilder
    private var photoSection: some View {
        Section(header: Text("从图片识别"),
                footer: Text("选一张截图或照片，在本机读出里面的文字，自动填好上面的提醒时间和重复规则，并把结论写进备注。全程不联网。")) {
            if let img = pickedImage {
                HStack(alignment: .top, spacing: 12) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 8) {
                        if scanning {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("正在读图…")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        } else if aiBusy {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("AI 正在复核…")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        } else if let s = parseSummary {
                            Text(s)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 18) {
                            Button("重新识别") { runOCR() }
                                .disabled(scanning)
                            Button("换一张") { photoSource = .library }
                            Button("清除") { clearPhoto() }
                                .foregroundColor(.red)
                        }
                        .font(.system(size: 13))
                    }
                }
            } else {
                Button {
                    photoSource = .library
                } label: {
                    Label("选照片 / 截图", systemImage: "photo.on.rectangle.angled")
                }
                if ImagePicker.cameraAvailable {
                    Button {
                        photoSource = .camera
                    } label: {
                        Label("拍照识别", systemImage: "camera")
                    }
                }
            }

            ForEach(tipsShown, id: \.self) { t in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(t).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundColor(.orange)
            }
        }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if draft.note.isEmpty {
                Text("可写备注；用图片识别时结果会自动写在这里")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft.note)
                .font(.system(size: 15))
                .frame(minHeight: 96)
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { wd in
                Button {
                    toggleWeekday(wd)
                } label: {
                    Text(chipName(wd))
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(draft.weekdays.contains(wd) ? brandColor : Color.gray.opacity(0.16))
                        .foregroundColor(draft.weekdays.contains(wd) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var repeatFooter: String {
        if draft.repeatMode == .weekly, draft.weekdays.isEmpty {
            return "没有选具体星期几，就按提醒时间那天每周重复一次。"
        }
        if draft.repeatMode != .none {
            return "点「完成」后会自动生成下一次任务"
        }
        return "只提醒这一次"
    }

    private func chipName(_ wd: Int) -> String {
        switch wd {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return "?"
        }
    }

    private func toggleWeekday(_ wd: Int) {
        if let i = draft.weekdays.firstIndex(of: wd) {
            draft.weekdays.remove(at: i)
        } else {
            draft.weekdays.append(wd)
        }
        draft.weekdays.sort { (($0 + 5) % 7) < (($1 + 5) % 7) }
    }

    // MARK: - 识别流程

    private func handlePicked(_ img: UIImage) {
        pickedImage = img
        runOCR()
    }

    private func runOCR() {
        guard let img = pickedImage else { return }
        scanning = true
        parseSummary = nil
        tipsShown = []
        SmartParser.recognize(image: img) { result in
            DispatchQueue.main.async {
                scanning = false
                applyResult(result)
            }
        }
    }

    private func applyResult(_ r: SmartParseResult) {
        tipsShown = r.tips

        if let e = r.errorText, r.rawLines.isEmpty {
            parseSummary = e
            return
        }
        parseSummary = r.summaryText()
        merge(r)

        // 配了 AI 的话，再让 AI 基于 OCR 原文复核一遍
        refineWithAI(r.rawLines.joined(separator: "\n"))
    }

    /// 把识别结果落到表单上（时间、重复、标题、备注）
    private func merge(_ r: SmartParseResult) {
        if let d = r.dueDate { draft.dueDate = d }
        if let m = r.repeatMode { draft.repeatMode = m }
        draft.weekdays = (r.repeatMode == .weekly) ? r.weekdays : []

        let titleEmpty = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let t = r.titleSuggestion, titleEmpty || titleAutoFilled {
            draft.title = t
            titleAutoFilled = true
        }

        let kept = stripImageBlock(draft.note)
        let block = r.noteBlock()
        draft.note = kept.isEmpty ? block : kept + "\n\n" + block
    }

    private func clearPhoto() {
        pickedImage = nil
        parseSummary = nil
        tipsShown = []
        aiError = nil
        draft.note = stripImageBlock(draft.note)
    }

    private func stripImageBlock(_ s: String) -> String {
        guard let r = s.range(of: parseBlockMarker) else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 其它

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
        if t.repeatMode != .weekly { t.weekdays = [] }
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
