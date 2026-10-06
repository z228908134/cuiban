import SwiftUI

struct AddTaskView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TaskItem
    @State private var customInterval: String = ""
    @State private var useCustom = false

    // MARK: 照片

    private enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }
    @State private var photoSource: PhotoSource? = nil
    /// 页面上所有照片（老照片 + 刚选的），保存时才落盘
    @State private var photos: [PhotoSlot] = []
    @State private var previewOpen = false
    @State private var previewStart = 0

    // MARK: 识别

    @State private var scanning = false
    @State private var parseSummary: String? = nil
    @State private var tipsShown: [String] = []
    @State private var titleAutoFilled = false

    // MARK: 一句话

    @State private var quickText = ""
    @State private var quickBusy = false

    // MARK: AI（可选）

    @ObservedObject private var ai = AIStore.shared
    @State private var aiBusy = false
    @State private var aiError: String? = nil

    var isEditing: Bool { draft.title != "" && store.task(id: draft.id) != nil }

    private let presetIntervals = [1, 2, 3, 5, 10, 15, 20, 30, 60]

    init(editing: TaskItem? = nil) {
        if let e = editing {
            _draft = State(initialValue: e)
            _useCustom = State(initialValue: e.intervalMinutes > 0 &&
                               ![1, 2, 3, 5, 10, 15, 20, 30, 60].contains(e.intervalMinutes))
            _customInterval = State(initialValue: e.intervalMinutes > 0 ? String(e.intervalMinutes) : "")
            _photos = State(initialValue: e.photos.compactMap { name in
                AttachmentStore.load(name).map { PhotoSlot(image: $0, fileName: name) }
            })
        } else {
            var d = TaskItem()
            d.dueDate = Date().addingTimeInterval(30 * 60)
            _draft = State(initialValue: d)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                quickSection

                photoSection

                resultSection

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

                Section(header: Text("没完成就多久催一次"),
                        footer: Text("任务到期后会先响一次，之后每隔这个间隔再催，直到你点「完成」。")) {
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
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && photos.isEmpty)
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
        .fullScreenCover(isPresented: $previewOpen) {
            PhotoViewer(
                images: photos.map { $0.image },
                titles: photos.indices.map { "第 \($0 + 1) 张，共 \(photos.count) 张" },
                start: previewStart
            )
        }
    }

    // MARK: - 说一句话就能建

    @ViewBuilder
    private var quickSection: some View {
        Section(header: Text("说一句话就能建"),
                footer: Text(ai.ready
                    ? "在本机先解析一遍，再让 AI 复核一次，结果自动填到下面的时间和重复里。"
                    : "把想做的事打进去，比如「明天下午 3 点开会」，本机就能识别出时间。想去「设置 → AI 智能解析」填个 Key，识别会更准。")) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("例如：下周一上午 10 点开周会，每周一次\n想写多长写多长，框会跟着长")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .padding(.top, 11)
                            .padding(.leading, 9)
                            .allowsHitTesting(false)
                    }
                    GrowingTextView(text: $quickText)
                }

                VStack(spacing: 6) {
                    if quickBusy {
                        ProgressView().scaleEffect(0.8)
                            .padding(.top, 10)
                    } else {
                        Button("识别") { runQuick() }
                            .disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .padding(.top, 8)
                    }
                }
            }

            if quickBusy {
                Text("正在解析…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if !quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    quickText = ""
                    parseSummary = nil
                    tipsShown = []
                    aiError = nil
                } label: {
                    Text("清空这句话")
                        .font(.system(size: 13))
                }
            }
        }
    }

    /// 识别结果统一显示在这里（文字识别和图片识别共用）
    @ViewBuilder
    private var resultSection: some View {
        if scanning {
            Section(header: Text("识别结果")) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读图…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        } else if aiBusy {
            Section(header: Text("识别结果")) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("AI 正在复核…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        } else if parseSummary != nil || !tipsShown.isEmpty || aiError != nil {
            Section(header: Text("识别结果"),
                    footer: Text("识别结论已经写进备注，可以随时改。")) {
                if let s = parseSummary {
                    Text(s)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(tipsShown, id: \.self) { t in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(t).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                }

                if let e = aiError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(e).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                }
            }
        }
    }

    private func runQuick() {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickBusy = true
        aiError = nil
        SmartParser.recognize(text: text) { r in
            DispatchQueue.main.async {
                quickBusy = false
                applyLocal(r)
            }
        }
    }

    // MARK: - 图片

    @ViewBuilder
    private var photoSection: some View {
        Section(header: Text("图片"),
                footer: Text("选截图或照片，会在本机读出里面的文字，自动填好上面的时间和重复规则，把结论写进备注；照片本身也会存进任务，清单、日历、催促页上都能看到。全程不联网。")) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { idx, slot in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: slot.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                                    )
                                    .onTapGesture {
                                        previewStart = idx
                                        previewOpen = true
                                    }

                                Button {
                                    removePhoto(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 19))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 7, y: -7)
                            }
                            .padding(.top, 7)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("点图看大图（共 \(photos.count) 张）")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Button {
                photoSource = .library
            } label: {
                Label(photos.isEmpty ? "选照片 / 截图" : "再加一张", systemImage: "photo.on.rectangle.angled")
            }
            if ImagePicker.cameraAvailable {
                Button {
                    photoSource = .camera
                } label: {
                    Label(photos.isEmpty ? "拍照" : "再拍一张", systemImage: "camera")
                }
            }

            if scanning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读图…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            if !photos.isEmpty && !scanning {
                HStack(spacing: 18) {
                    Button("重新识别") { runOCR() }
                        .font(.system(size: 13))
                    Button("清除全部图片") {
                        withAnimation {
                            photos = []
                            parseSummary = nil
                            tipsShown = []
                            aiError = nil
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                }
            }
        }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if draft.note.isEmpty {
                Text("可写备注；用图片或一句话识别时，结果会自动写在这里")
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
        photos.append(PhotoSlot(image: img))
        runOCR()
    }

    /// 单独抽出来，并改用 id 过滤，避免 `remove(at:)` 在 Array 与
    /// RangeReplaceableCollection 两个重载之间产生类型推断歧义
    private func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        let doomed = photos[index].id
        withAnimation {
            photos = photos.filter { $0.id != doomed }
        }
    }

    private func runOCR() {
        guard !photos.isEmpty else { return }
        scanning = true
        parseSummary = nil
        tipsShown = []
        aiError = nil
        let imgs = photos.map { $0.image }
        SmartParser.recognize(images: imgs) { result in
            DispatchQueue.main.async {
                scanning = false
                applyLocal(result)
            }
        }
    }

    /// 本机结果先落地，再看要不要让 AI 复核
    private func applyLocal(_ r: SmartParseResult) {
        tipsShown = r.tips
        if let e = r.errorText, r.rawLines.isEmpty {
            parseSummary = e
            return
        }
        parseSummary = r.summaryText()
        merge(r)

        let source = r.rawLines.joined(separator: "\n")
        if ai.ready, !source.isEmpty {
            refineWithAI(source)
        }
    }

    /// 配了 AI 的话，让 AI 基于原文再解析一遍覆盖本机结果
    private func refineWithAI(_ text: String) {
        aiBusy = true
        aiError = nil
        AIService.parse(text: text) { res in
            DispatchQueue.main.async {
                aiBusy = false
                switch res {
                case .success(let r):
                    merge(r)
                    parseSummary = "AI：" + r.summaryText()
                    tipsShown = r.tips
                case .failure(let e):
                    aiError = "AI 复核没成功，已用本机识别的结果（\(e.localizedDescription)）"
                }
            }
        }
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

        let kept = stripParseBlock(draft.note)
        let block = r.noteBlock()
        draft.note = kept.isEmpty ? block : kept + "\n\n" + block
    }

    private func stripParseBlock(_ s: String) -> String {
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
        if t.title.isEmpty {
            t.title = photos.isEmpty ? "新任务" : "图片任务"
        }

        if useCustom, let n = Int(customInterval), n >= 1 {
            t.intervalMinutes = min(n, 1440)
        } else if !useCustom && draft.intervalMinutes == -1 {
            t.intervalMinutes = 0
        }

        if t.repeatMode != .weekly { t.weekdays = [] }

        // 照片：新选的落盘，老的沿用，被删掉的从磁盘清掉
        var names: [String] = []
        var kept = photos
        for i in kept.indices {
            if let n = kept[i].fileName {
                names.append(n)
            } else if let n = AttachmentStore.save(kept[i].image) {
                kept[i].fileName = n
                names.append(n)
            }
        }
        t.photos = names
        let before = Set(store.task(id: t.id)?.photos ?? [])
        let removed = before.subtracting(Set(names))
        if !removed.isEmpty {
            AttachmentStore.delete(Array(removed))
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

// MARK: - 多行自高输入框

/// iOS 15 的 TextField 不支持多行，用 UITextView 包一层。
/// 关掉滚动后系统会按内容回报 intrinsicContentSize，输入框就跟着文字长高。
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = .label
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
            tv.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ p: GrowingTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
        }
    }
}
