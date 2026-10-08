import SwiftUI

// MARK: - 样式模型

/// 富文本样式片段：按字符区间存储，随笔记一起持久化。
/// 滴答式真样式（不是往文字里插 ** 之类的符号）。
struct NoteStyle: Codable, Equatable {
    var l: Int = 0      // 起点（UTF-16 坐标）
    var n: Int = 0      // 长度
    var b: Bool = false // 加粗
    var i: Bool = false // 斜体
    var u: Bool = false // 下划线
    var s: Bool = false // 删除线
    var h: Bool = false // 高亮底色
    var m: Bool = false // 等宽（代码）

    static func encode(_ list: [NoteStyle]) -> String {
        guard let d = try? JSONEncoder().encode(list) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    static func decode(_ s: String?) -> [NoteStyle] {
        guard let d = s?.data(using: .utf8),
              let list = try? JSONDecoder().decode([NoteStyle].self, from: d) else { return [] }
        return list
    }
}

// MARK: - 笔记列表

struct NotesView: View {
    @EnvironmentObject var noteStore: NoteStore
    @State private var showingAdd = false
    @State private var editing: NoteItem? = nil

    var body: some View {
        // 排序只算一次。原来 ForEach 里直接写 noteStore.sorted，
        // 列表每次重绘都要重排一遍，笔记多了就是白耗。
        let items = noteStore.sorted
        return NavigationView {
            Group {
                if noteStore.notes.isEmpty {
                    emptyHint
                } else {
                    List {
                        ForEach(items) { n in
                            row(n)
                        }
                        .onDelete { idx in
                            noteStore.delete(ids: idx.map { items[$0].id })
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("笔记")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                FabButton { showingAdd = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .sheet(isPresented: $showingAdd) {
                NoteEditorView(note: nil)
                    .environmentObject(noteStore)
            }
            .sheet(item: $editing) { n in
                NoteEditorView(note: n)
                    .environmentObject(noteStore)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.app(34))
                .foregroundColor(.secondary)
            Text("还没有笔记")
                .font(.app(15, weight: .medium))
            Text("点右下角 + 记一条，想法、备忘都能写")
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ n: NoteItem) -> some View {
        // 用 contentShape + onTapGesture 而不是 Button 包裹：
        // Button 会吃掉左滑手势，导致 swipeActions 划不出来
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(n.displayTitle)
                    .font(.app(16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !n.photos.isEmpty {
                    Image(systemName: "photo.on.rectangle")
                        .font(.app(10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            if !n.snippet.isEmpty {
                Text(n.snippet)
                    .font(.app(13))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .lineLimit(2)
            }

            // 更新时间的胶囊标签：今天橙、7 天内蓝、更早灰
            // （和清单页的时间高亮是同一套「彩色小标签」语言）
            Text(fmt(n.updatedAt, "M月d日 HH:mm"))
                .font(.app(11, weight: .semibold))
                .foregroundColor(timeTagFg(n.updatedAt))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(timeTagBg(n.updatedAt))
                )
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { editing = n }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 与清单页 / 卡片页一致：编辑在前、删除在后，
            // 声明要反着写（显示顺序 = 声明顺序的倒序）
            Button {
                let ids = [n.id]
                noteStore.delete(ids: ids)
            } label: {
                noteSwipeIcon("trash")
            }
            .tint(Color(red: 0.90, green: 0.23, blue: 0.22))

            Button {
                editing = n
            } label: {
                noteSwipeIcon("square.and.pencil")
            }
            .tint(Color(red: 0.19, green: 0.47, blue: 0.96))
        }
    }

    /// 左滑按钮里的白色图标 + 圆形半透明底（与清单页同一规格）
/// 左滑按钮里的图标。底色交给系统按 .tint 上色，
    /// 这里不要自绘背景，也不要给按钮加 .buttonStyle(.plain)——plain 会关掉 tint 上色、按钮全灰。
    private func noteSwipeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.app(19, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
    }

    /// 更新时间的标签配色：今天橙、7 天内蓝、更早灰
    private func timeTagBg(_ d: Date) -> Color {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: d)
        ).day ?? 0
        if days <= 0 {
            return Color(red: 0.98, green: 0.91, blue: 0.84)
        }
        if days <= 7 { return Color(red: 0.90, green: 0.95, blue: 0.99) }
        return Color.primary.opacity(0.06)
    }

    private func timeTagFg(_ d: Date) -> Color {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: d)
        ).day ?? 0
        if days <= 0 { return Color(red: 0.52, green: 0.31, blue: 0.04) }
        if days <= 7 { return Color(red: 0.09, green: 0.37, blue: 0.65) }
        return .secondary
    }
}

// MARK: - 笔记编辑器

struct NoteEditorView: View {
    @EnvironmentObject var noteStore: NoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// nil = 新建
    let note: NoteItem?

    @State private var title: String
    @State private var bodyText: String
    @State private var photos: [String]
    @State private var styleData: String
    /// 保存落地后的笔记 id（新建时第一次保存就记住，避免关闭时再存出一条重复）
    @State private var savedID: String?
    /// 当前选区生效的样式（工具栏按钮高亮用）
    @State private var activeTraits: Set<String> = []
    @State private var photoSource: PhotoSource? = nil
    @State private var showTemplates = false
    /// 「存为模板」的命名弹窗
    @State private var saveAsTemplateSheet = false
    @State private var bridge: TextEditBridge

    /// 自动保存：内容每变一次 +1，.task(id:) 靠它做「停手 1.2 秒才落盘」的防抖。
    /// 只靠 onDisappear 存不住——用户从多任务界面直接杀进程时根本不会触发。
    @State private var dirtyToken = 0
    /// 上次真正落盘时的内容指纹，用来判断「其实没改过」而跳过无谓写入
    @State private var lastSaved: String

    private enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }

    init(note: NoteItem?) {
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _bodyText = State(initialValue: TextEditBridge.migrate(note?.body ?? ""))
        _photos = State(initialValue: note?.photos ?? [])
        _styleData = State(initialValue: note?.styleData ?? "[]")
        _savedID = State(initialValue: note?.id)
        // 初始指纹按「编辑器的实际初始值」算，而不是空串：
        // 否则打开一条笔记什么都不改，关闭时也会被判成「改过了」而重写一遍
        _lastSaved = State(initialValue: Self.fingerprint(
            title: note?.title ?? "",
            body: TextEditBridge.migrate(note?.body ?? ""),
            photos: note?.photos ?? [],
            style: note?.styleData ?? "[]"))
        let br = TextEditBridge()
        br.styles = NoteStyle.decode(note?.styleData)
        _bridge = State(initialValue: br)
    }

    /// 内容指纹：四个字段拼一起，够用且比逐字段比较省事
    private static func fingerprint(title: String, body: String,
                                    photos: [String], style: String) -> String {
        "\(title)\u{1}\(body)\u{1}\(photos.joined(separator: ","))\u{1}\(style)"
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextField("笔记标题", text: $title)
                    .font(.app(20, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                bodyEditor

                if !photos.isEmpty {
                    photoStrip
                }

                Divider()

                // 格式工具栏（参考滴答清单）
                formatBar
            }
            .navigationTitle(note == nil ? "新建笔记" : "编辑笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { saveAndClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showTemplates = true
                    } label: {
                        // 用图标按钮而不是文字，标题栏才不会被「使用模板」四个字挤偏
                        Image(systemName: "text.badge.plus")
                            .font(.app(17))
                    }
                }
            }
            .sheet(item: $photoSource) { src in
                ImagePicker(sourceType: src == .camera ? .camera : .photoLibrary) { img in
                    photoSource = nil
                    if let name = AttachmentStore.save(img) {
                        photos.append(name)
                    }
                }
                .ignoresSafeArea()
            }
.sheet(isPresented: $showTemplates) {
      TemplatePickerView { t in
      applyTemplate(t)
        }
          }
          .sheet(isPresented: $saveAsTemplateSheet) {
      SaveAsTemplateSheet(
            defaultName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    ? String(displayTitleForTemplate.prefix(20))
    : title,
              templateBody: bodyText,
        styleData: styleData)
        }
            .onDisappear { saveIfWorth() }
            // 自动保存：标题/正文/样式/图片任一变化都把 dirtyToken 推上去，
            // 下面的 task 会在停手 0.8 秒后落盘（继续输入则 task 被取消重新计时）
            .onChange(of: title) { _ in dirtyToken += 1 }
            .onChange(of: bodyText) { _ in dirtyToken += 1 }
            .onChange(of: styleData) { _ in dirtyToken += 1 }
            .onChange(of: photos) { _ in dirtyToken += 1 }
            .task(id: dirtyToken) {
                guard dirtyToken > 0 else { return }
                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch {
                    return // 期间又改了，重新计时即可
                }
                guard !Task.isCancelled else { return }
                saveIfWorth()
            }
            // App 退到后台 / 熄屏 / 切多任务时立刻落盘：
            // 用户从多任务界面直接划掉 App 走的是这条路径，onDisappear 不会触发
            .onChange(of: scenePhase) { phase in
                if phase != .active { flushSave() }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 正文

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            if bodyText.isEmpty {
                // 纯展示的占位（不拦点击，点它也能唤起键盘）
                Text("记录你的想法，或使用模板")
                    .font(.app(16))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .padding(.top, 10)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)
            }
            NoteBodyEditor(text: $bodyText, styleData: $styleData,
                           activeTraits: $activeTraits, bridge: bridge)
                .padding(.horizontal, 12)
        }
    }

    // MARK: 格式工具栏（对齐滴答清单：真样式开关，选中时按钮高亮）

    private var formatBar: some View {
        HStack(spacing: 0) {
            barIcon("photo.on.rectangle") { photoSource = .library }
            barIcon("clock") { bridge.insert(fmt(Date(), "M月d日 HH:mm ")) }
            barIcon("arrow.uturn.backward") { bridge.undo() }

            barDivider

            barText("H") { bridge.toggleLinePrefix("# ") }
            barText("B", active: activeTraits.contains("b")) { bridge.toggle("b") }
            barText("S", strike: true, active: activeTraits.contains("s")) { bridge.toggle("s") }
            barIcon("highlighter", active: activeTraits.contains("h")) { bridge.toggle("h") }

            barDivider

            barIcon("checkmark.square") { bridge.toggleChecklist() }
            barIcon("list.bullet") { bridge.toggleLinePrefix("- ") }
            barIcon("list.number") { bridge.renumberList() }
            moreMenu
        }
        .frame(height: 42)
        .padding(.horizontal, 2)
    }

    /// 右端 ∨：其余全部功能收进菜单（滴答同款折叠）
    private var moreMenu: some View {
        Menu {
            Button { bridge.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }
            Divider()
            Button { bridge.toggle("i") } label: { Label("斜体", systemImage: "textformat.italic") }
            Button { bridge.toggle("u") } label: { Label("下划线", systemImage: "underline") }
            Button { bridge.toggle("m") } label: { Label("代码", systemImage: "curlybraces") }
            Button { bridge.toggleLinePrefix("> ") } label: { Label("引用", systemImage: "text.quote") }
            Button { bridge.wrap("[", "](https://)") } label: { Label("链接", systemImage: "link") }
            Button { bridge.insert("\n———\n") } label: { Label("分割线", systemImage: "minus") }
            Divider()
            Button { bridge.indent(shift: 1) } label: { Label("增加缩进", systemImage: "increase.indent") }
            Button { bridge.indent(shift: -1) } label: { Label("减少缩进", systemImage: "decrease.indent") }
            Divider()
            Button { bridge.copyAll() } label: { Label("复制全文", systemImage: "doc.on.doc") }
            Button { showTemplates = true } label: { Label("使用模板", systemImage: "doc.plaintext") }
            Button { saveAsTemplateSheet = true } label: { Label("存为模板", systemImage: "plus.rectangle.on.rectangle") }
            if ImagePicker.cameraAvailable {
                Button { photoSource = .camera } label: { Label("拍照", systemImage: "camera") }
            }
            Button { hideKeyboard() } label: { Label("收起键盘", systemImage: "keyboard.chevron.compact.down") }
        } label: {
            Image(systemName: "chevron.down")
                .font(.app(13, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.7, height: 18)
    }

    private func barIcon(_ system: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.app(17, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .accentColor : .primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }

    private func barText(_ s: String, strike: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s)
                .font(.app(15, weight: active ? .bold : .semibold))
                .strikethrough(strike)
                .foregroundColor(active ? .accentColor : .primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos.indices, id: \.self) { i in
                    if let img = AttachmentStore.load(photos[i]) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                photos.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.app(16))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: 模板

    /// 存为模板时用的默认名：优先标题，没有标题就拿正文第一条有意义行的前 20 字
    private var displayTitleForTemplate: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let first = NoteSummary.meaningfulLines(bodyText).first {
            return String(first.prefix(20))
        }
        return "我的模板"
    }

private func applyTemplate(_ t: NoteTemplate) {
        let tb = TextEditBridge.migrate(t.body)
        let cur = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.isEmpty {
            bodyText = tb
            // 模板带的样式一起还原（老模板没有样式就保持现在的）
            if let sd = t.styleData, !sd.isEmpty, sd != "[]" {
                styleData = sd
                bridge.styles = NoteStyle.decode(sd)
            }
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    title = t.name
            }
        } else {
    bodyText = bodyText + "\n\n" + tb
        }
    }

    private func saveAndClose() {
        flushSave()
        dismiss()
    }

    /// 立刻落盘（关闭 / 退后台）。不管有没有改动都走一遍 saveIfWorth，
    /// 由内容指纹去判断要不要真的写。
    private func flushSave() {
        saveIfWorth()
    }

    /// 空笔记不保存；有内容才写库。内容没变过则跳过，避免无谓的磁盘写入和 updatedAt 抖动
    /// （updatedAt 变了笔记列表会重新排序，老笔记会被顶到最前面）。
    private func saveIfWorth() {
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !photos.isEmpty

        // 已经存过、现在被清空了 → 直接把这条笔记删掉。
        // 不这么做的话：写了内容自动存过一次，之后全选删除，杀进程时
        // 走 saveIfWorth 的空内容 guard 直接返回，旧文字就留在库里了。
        if !hasContent {
            if let sid = savedID, noteStore.note(id: sid) != nil {
                noteStore.delete(ids: [sid])
                lastSaved = ""
            }
            return
        }

        let fp = Self.fingerprint(title: title, body: bodyText,
                                  photos: photos, style: styleData)
        guard fp != lastSaved else { return }
        lastSaved = fp

        var n = note ?? NoteItem()
        // 关闭按钮和 onDisappear 都会走到这里：新建时复用第一次保存的 id，
        // 否则 NoteItem() 每次都是新 UUID，会存出两条一模一样的笔记
        if let sid = savedID {
            n.id = sid
            n.createdAt = noteStore.note(id: sid)?.createdAt ?? n.createdAt
        }
        n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.body = bodyText
        n.photos = photos
        n.styleData = styleData

        // 被删掉的照片顺手从磁盘清掉
        let old = Set(note?.photos ?? [])
        let cur = Set(photos)
        let gone = old.subtracting(cur)
        if !gone.isEmpty {
            AttachmentStore.delete(Array(gone))
        }

        n.updatedAt = Date()
        noteStore.upsert(n)
        savedID = n.id
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - 正文编辑控件

/// 正文用 UITextView（SwiftUI 的 TextEditor 拿不到选区，做不了格式工具）。
/// bridge 负责从工具栏对正文做真样式 / 插入 / 行前缀操作。
/// 样式（加粗/斜体/下划线/删除线/高亮/等宽）按字符区间存进 NoteStyle，
/// 显示时套到 attributedText 上，保存时随笔记持久化。
struct NoteBodyEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var styleData: String
    @Binding var activeTraits: Set<String>
    var bridge: TextEditBridge

    /// 字体只取系统字族（苹方 / SF），不自造字体，也不写死具体字体名。
    /// 字号、字重、行距全部由系统度量决定，我们只在其上加一点行距留白。
    static var baseFont: UIFont { UIFont.app(16) }

    /// 行距：滴答清单那种「行与行之间有呼吸」的观感。
    /// 系统字体的默认行高已经很紧（16pt 正文实际行高约 19pt），
    /// 再加上勾选框用了 22~24pt 的大字号，行与行几乎贴在一起。
    /// 这里按字号给一个固定比例的额外行距，字号跟着全局缩放走，行距也跟着等比放大。
    static var lineSpacing: CGFloat { 8 * FontScale.current }

    /// 正文统一段落样式：只用系统度量 + 额外行距，不指定字体名
    static func paragraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.lineHeightMultiple = 1
        p.paragraphSpacing = 0
        p.hyphenationFactor = 0
        return p
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = CheckboxTextView()
        tv.font = Self.baseFont
        tv.textColor = .label
        tv.backgroundColor = .clear
        // 新输入的行也走同一套行距：段落样式通过 typingAttributes 下发，
        // 回车新起一行时会继承它（restyle 里给整段文本也挂了同一份样式）
        tv.typingAttributes = Self.attrsFor([])
        tv.delegate = context.coordinator
        bridge.textView = tv
        let binding = $text
        bridge.onEdited = { t in
            if binding.wrappedValue != t {
                binding.wrappedValue = t
            }
        }
        let styleBinding = $styleData
        bridge.onStylesChanged = { s in
            if styleBinding.wrappedValue != s {
                styleBinding.wrappedValue = s
            }
        }
        let activeBinding = $activeTraits
        bridge.onSelectionChanged = { t in
            if activeBinding.wrappedValue != t {
                activeBinding.wrappedValue = t
            }
        }
        // 工具栏操作后重新套样式
        bridge.refreshUI = { [weak tv, weak bridge] in
            guard let tv = tv, let bridge = bridge else { return }
            NoteBodyEditor.restyle(tv, styles: bridge.styles, pending: bridge.pendingTraits)
        }
        // 点勾选框直接打勾 / 取消（滴答式交互）。
        // 用 hitTest 在触摸入口直接拦截：点中方框的触摸根本不进 UITextView 的手势系统。
        // 之前外挂 UITapGestureRecognizer 一直修不好——系统「点按定位光标」手势
        // 优先级更高，require(toFail:) 又会拖坏长按选择文字；hitTest 一劳永逸。
        let coordinator = context.coordinator
        tv.checkboxHitTest = { [weak tv] point in
            guard let tv = tv else { return false }
            return coordinator.toggleCheckbox(at: point, in: tv)
        }
        NoteBodyEditor.restyle(tv, styles: bridge.styles, pending: bridge.pendingTraits)
        bridge.record(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        bridge.textView = tv
        // 拼音组合期间什么都不动（否则打断输入）
        guard tv.markedTextRange == nil else { return }
        // tv.text 里的附件占位符换回标记字符后再比较
        if Self.plainText(tv.attributedText) != text {
            tv.text = text
            NoteBodyEditor.restyle(tv, styles: bridge.styles, pending: bridge.pendingTraits)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: 纯文本

    /// 正文里的富文本还原成纯文本。
    /// 勾选框现在用的是「系统一定有字形的字符」做底（上面再盖绘制的方框），
    /// 文本里不存在附件占位符，所以这里不需要做任何还原。
    static func plainText(_ attr: NSAttributedString) -> String {
        attr.string
    }

    // MARK: 样式渲染

    /// 由样式特征生成字体（加粗/斜体/等宽可叠加）
    static func fontFor(bold: Bool, italic: Bool, mono: Bool) -> UIFont {
        var d = baseFont.fontDescriptor
        if mono { d = d.withDesign(.monospaced) ?? d }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let nd = d.withSymbolicTraits(traits) { d = nd }
        return UIFont(descriptor: d, size: baseFont.pointSize)
    }

    /// 给某个样式集合生成属性字典（打字属性也复用）
    static func attrsFor(_ traits: Set<String>) -> [NSAttributedString.Key: Any] {
        var tp: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle()
        ]
        if traits.contains("b") || traits.contains("i") || traits.contains("m") {
            tp[.font] = fontFor(bold: traits.contains("b"),
                                italic: traits.contains("i"),
                                mono: traits.contains("m"))
        }
        if traits.contains("u") { tp[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if traits.contains("s") { tp[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if traits.contains("h") {
            tp[.backgroundColor] = UIColor.systemYellow.withAlphaComponent(0.35)
        }
        return tp
    }

    /// 给正文上样式：
    /// 1. 行首勾选标记上盖一个画出来的方框（底下是系统字体一定有字形的 ⬜️/☑️，
    ///    万一附件没挂上，用户看到的也是一个方块字符，不会变成空白）
    /// 2. 勾选完成的待办整句删除线变灰、# 标题加粗、> 引用变灰（行级）
    /// 3. 富文本样式（加粗/斜体/下划线/删除线/高亮/等宽）按区间套上
    /// 打字期间（输入法有 markedText 组合状态）绝不重设 attributedText。
    static func restyle(_ tv: UITextView, styles: [NoteStyle], pending: Set<String>) {
        guard tv.markedTextRange == nil else { return }
        let content = tv.text ?? ""
        let attr = NSMutableAttributedString(
            string: content,
            attributes: [
                .font: Self.baseFont,
                .foregroundColor: UIColor.label,
                .paragraphStyle: Self.paragraphStyle()
            ]
        )
        let cns = content as NSString
        var loc = 0
        while loc < cns.length {
            let lr = cns.lineRange(for: NSRange(location: loc, length: 0))
            let line = cns.substring(with: lr)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // 勾选框：字符本体 + 大字号，尺寸完全由字号控制（和正文差不多大）
            let info = TextEditBridge.markInfo(in: line)
            if let info = info, info.markLen > 0 {
                let boxSize: CGFloat = info.checked ? 24 : 22
                attr.addAttributes([
                    .font: UIFont.app(boxSize),
                    .foregroundColor: info.checked
                        ? UIColor.tertiaryLabel
                        : UIColor.label.withAlphaComponent(0.78)
                ], range: NSRange(location: lr.location + info.loc, length: info.markLen))
            }

            if let info = info, info.checked {
                // 已勾选：只给勾选框后面的那段文字加删除线并置灰
                var bodyLen = lr.length - info.len
                // 行尾换行不计入
                if bodyLen > 0, cns.character(at: lr.location + info.len + bodyLen - 1) == 0x0A {
                    bodyLen -= 1
                }
                if bodyLen > 0 {
                    attr.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: UIColor.secondaryLabel,
                        .foregroundColor: UIColor.secondaryLabel
                    ], range: NSRange(location: lr.location + info.len, length: bodyLen))
                }
            } else if info == nil, trimmed.hasPrefix("# ") {
                attr.addAttribute(
                    .font,
                    value: UIFont.app(19, weight: .semibold),
                    range: NSRange(location: lr.location, length: max(lr.length - 1, 0))
                )
            } else if trimmed.hasPrefix("> ") {
                attr.addAttribute(
                    .foregroundColor,
                    value: UIColor.secondaryLabel,
                    range: NSRange(location: lr.location, length: max(lr.length - 1, 0))
                )
            }
            if lr.length == 0 { break }
            loc = lr.location + lr.length
        }

        // 富文本样式（真加粗/斜体/下划线/删除线/高亮/等宽）
        for st in styles {
            guard st.n > 0, st.l >= 0, st.l < attr.length else { continue }
            let len = min(st.n, attr.length - st.l)
            guard len > 0 else { continue }
            let rng = NSRange(location: st.l, length: len)
            if st.b || st.i || st.m {
                attr.addAttribute(.font, value: fontFor(bold: st.b, italic: st.i, mono: st.m), range: rng)
            }
            if st.u { attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: rng) }
            if st.s { attr.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rng) }
            if st.h {
                attr.addAttribute(.backgroundColor,
                                  value: UIColor.systemYellow.withAlphaComponent(0.35),
                                  range: rng)
            }
        }

        let sel = tv.selectedRange
        tv.attributedText = attr
        tv.typingAttributes = attrsFor(pending)
        tv.selectedRange = sel
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteBodyEditor
        init(_ p: NoteBodyEditor) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            // 拼音/中文候选还没上屏时不动文本存储，避免打断输入
            guard tv.markedTextRange == nil else {
                if let t = tv.text { if parent.text != t { parent.text = t } }
                return
            }
            let clean = NoteBodyEditor.plainText(tv.attributedText)
            let old = parent.text
            // 增删文字后平移/裁剪样式区间；新输入落上「下一个输入」的样式
            parent.bridge.adjustStyles(old: old, new: clean)
            parent.bridge.captureTyping(old: old, new: clean)
            if parent.text != clean {
                parent.text = clean
            }
            parent.bridge.record(tv)
            NoteBodyEditor.restyle(tv, styles: parent.bridge.styles,
                                   pending: parent.bridge.pendingTraits)
        }

        /// 光标/选区变化：更新「下一个输入」样式 + 工具栏高亮态
        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.bridge.syncSelectionUI(tv)
        }

        /// 编辑结束（键盘收起）后再补一次样式
        func textViewDidEndEditing(_ tv: UITextView) {
            NoteBodyEditor.restyle(tv, styles: parent.bridge.styles,
                                   pending: parent.bridge.pendingTraits)
        }

        // MARK: 点勾选框打勾（触摸入口拦截，见 CheckboxTextView）

        /// 标记字符在屏幕上的矩形：firstRect（字符实际渲染矩形）与 caretRect（光标矩形）取并集。
        /// 两种系统 API 的坐标理解若有偏差，并集能一并覆盖。
        private static func boxRect(tv: UITextView, markLoc: Int, markLen: Int) -> CGRect? {
            var rects: [CGRect] = []
            if let p0 = tv.position(from: tv.beginningOfDocument, offset: markLoc) {
                rects.append(tv.caretRect(for: p0))
                if markLen > 0,
                   let p1 = tv.position(from: tv.beginningOfDocument, offset: markLoc + markLen),
                   let r = tv.textRange(from: p0, to: p1) {
                    let fr = tv.firstRect(for: r)
                    if fr.width > 0 || fr.height > 0 { rects.append(fr) }
                }
            }
            guard !rects.isEmpty else { return nil }
            let u = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            guard u.width > 0, u.height > 0 else { return nil }
            return u
        }

        /// 命中判定：点落在某个勾选行「方框」附近 → 返回该行范围 + 标记位置 + 标记长度 + 当前勾选态。
        /// 位置全部由系统给（firstRect + caretRect 并集）再统一放宽成一大块热区。
        /// 收集所有命中的行、取离手指最近的那一行，避免上下相邻两行都是待办时点错行。
        private static func checkboxHit(at point: CGPoint, in tv: UITextView)
            -> (range: NSRange, markLoc: Int, markLen: Int, checked: Bool)? {
            let ns = (tv.text ?? "") as NSString
            var loc = 0
            var best: (range: NSRange, markLoc: Int, markLen: Int, checked: Bool)?
            var bestDist: CGFloat = .greatestFiniteMagnitude

            while loc < ns.length {
                let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
                if lr.length > 0, let info = TextEditBridge.markInfo(in: ns.substring(with: lr)) {
                    let markLoc = lr.location + info.loc
                    if let box = boxRect(tv: tv, markLoc: markLoc, markLen: info.markLen) {
                        // 热区：左右各放宽一截（覆盖方框 + 后面的空格），上下也留余量
                        let hot = CGRect(x: box.minX - 22,
                                         y: box.minY - 14,
                                         width: box.width + 52,
                                         height: box.height + 26)
                        if hot.contains(point) {
                            let dx = point.x - box.midX
                            let dy = point.y - box.midY
                            let d = sqrt(dx * dx + dy * dy)
                            if d < bestDist {
                                bestDist = d
                                best = (lr, markLoc, info.markLen, info.checked)
                            }
                        }
                    }
                    // 兜底：让系统告诉我们这个点最近的字符位置（同样是系统算坐标，最稳）
                    if best == nil, let near = tv.closestPosition(to: point) {
                        let idx = tv.offset(from: tv.beginningOfDocument, to: near)
                        // 方框本身 + 方框后面那个空格都算点在框上
                        if idx >= markLoc && idx <= markLoc + info.markLen {
                            best = (lr, markLoc, info.markLen, info.checked)
                        }
                    }
                }
                if lr.length == 0 { break }
                loc = lr.location + lr.length
            }
            return best
        }

        /// 点在勾选框上：切换勾选状态。返回 true 表示已接管（hitTest 会吞掉这次触摸）
        func toggleCheckbox(at point: CGPoint, in tv: UITextView) -> Bool {
            guard let hit = Self.checkboxHit(at: point, in: tv) else { return false }
            // 中文输入法还有拼音组合串时先提交，否则样式重排会被跳过
            if tv.markedTextRange != nil {
                tv.unmarkText()
            }
            let plain = NoteBodyEditor.plainText(tv.attributedText)
            let plainNS = plain as NSString
            guard hit.markLoc >= 0, hit.markLoc + hit.markLen <= plainNS.length else { return false }

            // 只替换行首那一个标记：缩进、后面的空格与正文都原样保留
            let newAll = plainNS.replacingCharacters(
                in: NSRange(location: hit.markLoc, length: hit.markLen),
                with: hit.checked ? TextEditBridge.uncheckedMarkRaw : TextEditBridge.checkedMarkRaw
            )
            parent.bridge.adjustStyles(old: plain, new: newAll)
            tv.text = newAll
            tv.selectedRange = NSRange(location: min(hit.markLoc + hit.markLen, (newAll as NSString).length),
                                       length: 0)
            NoteBodyEditor.restyle(tv, styles: parent.bridge.styles,
                                   pending: parent.bridge.pendingTraits)
            parent.bridge.syncSelectionUI(tv)
            if parent.text != newAll {
                parent.text = newAll
            }
            parent.bridge.record(tv)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
    }
}

// MARK: - 勾选框可点的正文视图

/// 勾选框交互的关键：点在方框上的触摸在 hitTest 阶段直接被吞掉，
/// 不进入 UITextView 自己的任何手势。
/// 为什么不用外挂 UITapGestureRecognizer：UITextView 内部的「点按定位光标」手势
/// 比外挂手势先添加、优先响应，外挂手势会被它抢先判负（这就是勾选框一直点不动的根因）；
/// 而 require(toFail:) 让系统手势等外挂手势失败，又会把长按选择文字拖坏。
final class CheckboxTextView: UITextView {
    /// 返回 true 表示该点命中勾选框、已完成切换
    var checkboxHitTest: ((CGPoint) -> Bool)? = nil
    private var lastToggleAt: CFTimeInterval = -10

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 只在「手指刚按下」这一个事件上判定，避免同一次触摸的移动/抬起重复触发
        if let event = event,
           event.allTouches?.contains(where: { $0.phase == .began }) == true,
           CACurrentMediaTime() - lastToggleAt > 0.35,
           let cb = checkboxHitTest,
           cb(point) {
            lastToggleAt = CACurrentMediaTime()
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

/// 工具栏 → 正文的操作桥
final class TextEditBridge {
    weak var textView: UITextView?
    var onEdited: ((String) -> Void)? = nil
    /// 工具栏操作完成后让编辑器重新套样式
    var refreshUI: (() -> Void)? = nil
    /// 样式变化回调（持久化 JSON 字符串）
    var onStylesChanged: ((String) -> Void)? = nil
    /// 选区/样式状态变化回调（工具栏按钮高亮）
    var onSelectionChanged: ((Set<String>) -> Void)? = nil

    /// 标记字符本体（不含尾随空格）；存储与比较用。
    /// 用「□ / ☑」字符本体 + 大字号渲染：字形宽度约占字号的 7 成，
    /// 字号给到 22/24pt，出来的方框就有 15pt 上下，和正文一样大。
    /// 不用 NSTextAttachment 画图——那条路踩过坑：附件算出来 0×0 时
    /// 会把字符整个顶掉，界面就成了「空格」。
    static let checkedMarkRaw = "\u{2611}"
    static let uncheckedMarkRaw = "\u{25A1}"

    // MARK: 富文本样式

    var styles: [NoteStyle] = []
    /// 光标处的「下一个输入」样式（选区为空时工具栏开关的是它）
    var pendingTraits: Set<String> = []

    private func traits(at idx: Int) -> Set<String> {
        var t = Set<String>()
        for st in styles where idx >= st.l && idx < st.l + st.n {
            if st.b { t.insert("b") }
            if st.i { t.insert("i") }
            if st.u { t.insert("u") }
            if st.s { t.insert("s") }
            if st.h { t.insert("h") }
            if st.m { t.insert("m") }
        }
        return t
    }

    /// 当前选区「全部命中」的样式（空选区返回 pending，供按钮高亮）
    func selectedTraits(_ tv: UITextView) -> Set<String> {
        let r = tv.selectedRange
        if r.length == 0 { return pendingTraits }
        var acc: Set<String>? = nil
        for idx in r.location..<(r.location + r.length) {
            let t = traits(at: idx)
            acc = acc == nil ? t : acc!.intersection(t)
            if let a = acc, a.isEmpty { break }
        }
        return acc ?? []
    }

    /// 工具栏样式开关：有选区改选区样式；没选区改「下一个输入」样式。
    /// 这是真样式——直接加粗/高亮文字，不再是插 ** 之类的符号。
    func toggle(_ trait: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let ns = tv.text as NSString
        let r = tv.selectedRange
        if r.length > 0, r.location + r.length <= ns.length {
            var hasAll = true
            for idx in r.location..<(r.location + r.length) where !traits(at: idx).contains(trait) {
                hasAll = false
                break
            }
            var map: [Int: Set<String>] = [:]
            for idx in 0..<ns.length {
                let t = traits(at: idx)
                if !t.isEmpty { map[idx] = t }
            }
            for idx in r.location..<(r.location + r.length) {
                var t = map[idx] ?? []
                if hasAll { t.remove(trait) } else { t.insert(trait) }
                map[idx] = t
            }
            styles = Self.normalize(map, length: ns.length)
            notifyStylesChanged()
            syncSelectionUI(tv)
            NoteBodyEditor.restyle(tv, styles: styles, pending: pendingTraits)
            record(tv)
            onEdited?(NoteBodyEditor.plainText(tv.attributedText))
        } else {
            if pendingTraits.contains(trait) {
                pendingTraits.remove(trait)
            } else {
                pendingTraits.insert(trait)
            }
            onSelectionChanged?(pendingTraits)
            NoteBodyEditor.restyle(tv, styles: styles, pending: pendingTraits)
        }
    }

    func notifyStylesChanged() {
        onStylesChanged?(NoteStyle.encode(styles))
    }

    /// 打字后把「下一个输入」样式落到新输入的区间
    func captureTyping(old: String, new: String) {
        guard !pendingTraits.isEmpty else { return }
        let ins = Self.diffRange(old: old, new: new)
        guard let (p, insLen, total) = ins, insLen > 0 else { return }
        var map: [Int: Set<String>] = [:]
        for idx in 0..<total {
            let t = traits(at: idx)
            if !t.isEmpty { map[idx] = t }
        }
        for idx in p..<(p + insLen) {
            var t = map[idx] ?? []
            t.formUnion(pendingTraits)
            map[idx] = t
        }
        styles = Self.normalize(map, length: total)
        notifyStylesChanged()
    }

    /// 增删文字后平移/裁剪样式区间（保证样式跟着原来的字走）
    func adjustStyles(old: String, new: String) {
        guard !styles.isEmpty, old != new else { return }
        let ons = old as NSString, nns = new as NSString
        var p = 0
        let m = min(ons.length, nns.length)
        while p < m, ons.character(at: p) == nns.character(at: p) { p += 1 }
        var sfx = 0
        while sfx < m - p, ons.character(at: ons.length - 1 - sfx) == nns.character(at: nns.length - 1 - sfx) { sfx += 1 }
        // 变化区间 = [p, oldLen - sfx)；区间前的位置不动，区间后的整体平移，落在区间内的裁到 p
        func shift(_ x: Int) -> Int {
            if x <= p { return x }
            if x >= ons.length - sfx { return x + (nns.length - ons.length) }
            return p
        }
        var out: [NoteStyle] = []
        for st in styles {
            let nl = shift(st.l)
            let nr = shift(st.l + st.n)
            if nr > nl {
                var v = st
                v.l = nl
                v.n = nr - nl
                out.append(v)
            }
        }
        styles = out
    }

    /// 公共前缀/后缀差分：返回 (插入起点, 插入长度, 新文本长度)
    static func diffRange(old: String, new: String) -> (Int, Int, Int)? {
        let ons = old as NSString, nns = new as NSString
        var p = 0
        let m = min(ons.length, nns.length)
        while p < m, ons.character(at: p) == nns.character(at: p) { p += 1 }
        var sfx = 0
        while sfx < m - p, ons.character(at: ons.length - 1 - sfx) == nns.character(at: nns.length - 1 - sfx) { sfx += 1 }
        let insLen = nns.length - p - sfx
        return (p, insLen, nns.length)
    }

    /// 把逐字符样式表折叠成连续区间
    static func normalize(_ map: [Int: Set<String>], length: Int) -> [NoteStyle] {
        var out: [NoteStyle] = []
        var cur: NoteStyle? = nil
        var curSet: Set<String> = []
        for idx in 0..<length {
            let t = map[idx] ?? []
            if t.isEmpty {
                if cur != nil { out.append(cur!); cur = nil; curSet = [] }
            } else if cur != nil, t == curSet {
                cur!.n += 1
            } else {
                if cur != nil { out.append(cur!) }
                var v = NoteStyle()
                v.l = idx
                v.n = 1
                v.b = t.contains("b")
                v.i = t.contains("i")
                v.u = t.contains("u")
                v.s = t.contains("s")
                v.h = t.contains("h")
                v.m = t.contains("m")
                cur = v
                curSet = t
            }
        }
        if cur != nil { out.append(cur!) }
        return out
    }

    /// 光标/选区变化：更新「下一个输入」样式 + 通知按钮高亮
    func syncSelectionUI(_ tv: UITextView) {
        guard tv.markedTextRange == nil else { return }
        let r = tv.selectedRange
        if r.length == 0 {
            let ns = tv.text as NSString
            let idx = r.location > 0 ? r.location - 1 : (ns.length > 0 ? 0 : -1)
            pendingTraits = (idx >= 0 && idx < ns.length) ? traits(at: idx) : []
        }
        onSelectionChanged?(selectedTraits(tv))
    }

    // MARK: 撤销 / 重做（自维护历史，含样式，工具栏操作也能撤销）

    private var history: [(text: String, styles: [NoteStyle], sel: NSRange)] = []
    private var histIdx: Int = -1
    private var suppressRecord = false

    /// 记录当前状态到历史（输入变化、工具栏操作后都调用）
    func record(_ tv: UITextView) {
        guard !suppressRecord else { return }
        let t = NoteBodyEditor.plainText(tv.attributedText)
        let sel = tv.selectedRange
        if histIdx >= 0, histIdx < history.count,
           history[histIdx].text == t, history[histIdx].styles == styles {
            history[histIdx] = (t, styles, sel)
            return
        }
        if histIdx + 1 < history.count {
            history.removeSubrange((histIdx + 1)...)
        }
        history.append((t, styles, sel))
        if history.count > 200 { history.removeFirst() }
        histIdx = history.count - 1
    }

    func undo() {
        guard let tv = textView, histIdx > 0 else { return }
        histIdx -= 1
        applyHistory(tv)
    }

    func redo() {
        guard let tv = textView, histIdx + 1 < history.count else { return }
        histIdx += 1
        applyHistory(tv)
    }

    private func applyHistory(_ tv: UITextView) {
        let e = history[histIdx]
        suppressRecord = true
        tv.text = e.text
        tv.selectedRange = e.sel
        suppressRecord = false
        styles = e.styles
        notifyStylesChanged()
        refreshUI?()
        onEdited?(e.text)
        syncSelectionUI(tv)
    }

    /// 光标处插入一段文字
    func insert(_ s: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let r = tv.selectedRange
        let newAll = ns.replacingCharacters(in: r, with: s)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(location: r.location + (s as NSString).length, length: 0)
        finish(tv)
    }

    /// 把选中文字包进前后缀；没有选中就插入一对并停在中间
    func wrap(_ prefix: String, _ suffix: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let r = tv.selectedRange
        let sel = ns.substring(with: r)
        let newAll = ns.replacingCharacters(in: r, with: prefix + sel + suffix)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(
            location: r.location + (prefix as NSString).length,
            length: (sel as NSString).length
        )
        finish(tv)
    }

    /// 行首前缀开关：选中的行都有前缀就去掉，否则加上
    func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let lr = lineRange(tv, ns: ns)
        let comps = ns.substring(with: lr).components(separatedBy: "\n")
        let pairs = linesWithoutCheckbox(comps)
        let nonEmpty = pairs.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let has = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.body.hasPrefix(prefix) }
        let out = pairs.map { p -> String in
            if p.body.isEmpty { return p.pad }
            return has ? p.pad + String(p.body.dropFirst(prefix.count)) : p.pad + prefix + p.body
        }
        let joined = out.joined(separator: "\n")
        let newAll = ns.replacingCharacters(in: lr, with: joined)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    /// 有序列表：已编号则去掉编号，否则逐行重新编号
    func renumberList() {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let lr = lineRange(tv, ns: ns)
        let comps = ns.substring(with: lr).components(separatedBy: "\n")
        let pairs = linesWithoutCheckbox(comps)
        let nonEmpty = pairs.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let allNumbered = !nonEmpty.isEmpty && nonEmpty.allSatisfy { isNumberedLine($0.body) }

        var counter = 1
        let out = pairs.map { p -> String in
            if p.body.isEmpty { return p.pad }
            let stripped = stripNumber(p.body)
            if allNumbered { return p.pad + stripped }
            let s = p.pad + "\(counter). " + stripped
            counter += 1
            return s
        }
        let joined = out.joined(separator: "\n")
        let newAll = ns.replacingCharacters(in: lr, with: joined)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    /// 待办勾选开关：无勾选框 → 加未勾选方框；未勾选 → 已勾选；已勾选 → 取消。
    /// 勾上后那一段文字自动加删除线并变灰，见 NoteBodyEditor.restyle
    func toggleChecklist() {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let lr = lineRange(tv, ns: ns)
        let comps = ns.substring(with: lr).components(separatedBy: "\n")
        let out = comps.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            // 已有勾选框：原地翻转标记（缩进、空格、正文都不动）
            if let info = Self.markInfo(in: line) {
                return (line as NSString).replacingCharacters(
                    in: NSRange(location: info.loc, length: info.markLen),
                    with: info.checked ? Self.uncheckedMarkRaw : Self.checkedMarkRaw
                )
            }
            // 去掉其它列表前缀再挂勾选框，避免叠加（缩进保留）
            var pad = ""
            var s = line
            while s.hasPrefix(" ") { pad += " "; s = String(s.dropFirst()) }
            for p in ["- ", "> ", "1. ", "2. ", "3. "] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
            return pad + Self.uncheckedMark + s
        }
        let joined = out.joined(separator: "\n")
        let newAll = ns.replacingCharacters(in: lr, with: joined)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    /// 勾选 / 未勾选的标记（含尾随空格；同时兼容旧的 - [x] / - [ ] 写法）
    static var checkedMark: String { checkedMarkRaw + " " }
    static var uncheckedMark: String { uncheckedMarkRaw + " " }

    static func markerPrefix(in line: String, checked: Bool) -> String? {
        let candidates = checked
            ? [checkedMark, "✅ ", "- [x] ", "- [X] ", "☑️ ", "☑ "]
            : [uncheckedMark, "⬜️ ", "- [ ] ", "☐ ", "☐️ "]
        for c in candidates where line.hasPrefix(c) { return c }
        return nil
    }

    /// 行首勾选标记（允许前面有缩进空格，缩进后也要能正常渲染方框）。
    /// 返回：标记字符在行内的位置 loc、标记本体长度 markLen、标记前缀总长 len（含尾随空格）、是否已勾选
    static func markInfo(in line: String) -> (loc: Int, markLen: Int, len: Int, checked: Bool)? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, ns.character(at: i) == 0x20 { i += 1 }
        let rest = i == 0 ? line : ns.substring(from: i)
        for (mark, checked) in [(checkedMarkRaw, true), (uncheckedMarkRaw, false)] {
            if rest.hasPrefix(mark) {
                let m = (mark as NSString).length
                return (loc: i, markLen: m, len: i + m + 1, checked: checked)
            }
        }
        // 兼容旧写法（⬜️/✅/- [ ]/☐ 等）：markLen 不含尾随空格，
        // 这样点一下翻转时不会把方框后面的空格吃掉
        for checked in [true, false] {
            if let p = markerPrefix(in: rest, checked: checked) {
                let n = (p as NSString).length
                return (loc: i, markLen: max(n - 1, 1), len: i + n, checked: checked)
            }
        }
        return nil
    }

    /// 行首若带勾选标记（含缩进）返回去掉标记与缩进后的正文；否则返回 nil
    static func stripMark(in line: String) -> String? {
        guard let info = markInfo(in: line) else { return nil }
        return (line as NSString).substring(from: info.len)
    }

    /// 旧写法统一迁移成新标记：
    /// 早期版本用的私有区字符（\u{E000}/\u{E001}，字体里没有字形、会显示成空白）
    /// 以及 ⬜️/✅/- [ ]/- [x]/☐/☑️ 这类手打写法。
    static func migrate(_ s: String) -> String {
        let legacy: [(String, Bool)] = [
            ("\u{E001} ", true), ("\u{E000} ", false),          // 旧版私有区标记
            ("✅ ", true), ("- [x] ", true), ("- [X] ", true), ("☑️ ", true), ("☑ ", true),
            ("⬜️ ", false), ("- [ ] ", false), ("☐ ", false), ("☐️ ", false)        ]
        return s.components(separatedBy: "\n").map { line -> String in
            guard !line.isEmpty else { return line }
            for (old, checked) in legacy where line.hasPrefix(old) {
                return (checked ? checkedMark : uncheckedMark) + String(line.dropFirst(old.count))
            }
            // 行首缩进后也要迁移
            let ns = line as NSString
            var i = 0
            while i < ns.length, ns.character(at: i) == 0x20 { i += 1 }
            if i > 0, i < ns.length {
                let rest = ns.substring(from: i)
                for (old, checked) in legacy where rest.hasPrefix(old) {
                    let pad = ns.substring(to: i)
                    return pad + (checked ? checkedMark : uncheckedMark) + String(rest.dropFirst(old.count))
                }
            }
            return line
        }.joined(separator: "\n")
    }

    /// 展示用：把标记字符换成普通符号（列表摘要等纯文本场景）
    static func displayFriendly(_ s: String) -> String {
        s.replacingOccurrences(of: checkedMark, with: "☑ ")
            .replacingOccurrences(of: uncheckedMark, with: "☐ ")
            .replacingOccurrences(of: checkedMarkRaw, with: "☑")
            .replacingOccurrences(of: uncheckedMarkRaw, with: "☐")
    }

    func copyAll() {
        guard let tv = textView else { return }
        UIPasteboard.general.string = NoteBodyEditor.plainText(tv.attributedText)
    }

    /// 缩进：shift = 1 加一层缩进，shift = -1 减一层（每层 4 个空格）
    func indent(shift: Int) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let old = tv.text ?? ""
        let ns = old as NSString
        let pad = "    "
        let lr = lineRange(tv, ns: ns)
        let comps = ns.substring(with: lr).components(separatedBy: "\n")
        let out = comps.map { line -> String in
            if line.isEmpty { return line }
            if shift > 0 {
                return pad + line
            }
            var s = line
            for p in [pad, "  ", "\t"] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
            return s
        }
        let joined = out.joined(separator: "\n")
        let newAll = ns.replacingCharacters(in: lr, with: joined)
        adjustStyles(old: old, new: newAll)
        tv.text = newAll
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    // MARK: 私有

    /// 把 UITextView 里的附件占位符还原成标记字符，让后续字符串操作按纯文本进行
    private func syncPlain(_ tv: UITextView) {
        // 中文输入法还有拼音组合串时先提交，否则样式重排会被跳过、工具开关失效
        if tv.markedTextRange != nil {
            tv.unmarkText()
        }
        let plain = NoteBodyEditor.plainText(tv.attributedText)
        if plain != tv.text {
            // 关键：重设 text 会把选区弄丢，斜体/加粗等选区开关就作用不上；
            // 附件占位符与标记字符长度 1:1，选区位置可以直接原样保留
            let sel = tv.selectedRange
            tv.text = plain
            tv.selectedRange = sel
        }
    }

    private func finish(_ tv: UITextView) {
        refreshUI?()
        record(tv)
        onEdited?(tv.text)
    }

    /// 覆盖当前选区的整行范围（含行尾换行）
    private func lineRange(_ tv: UITextView, ns: NSString) -> NSRange {        let len = ns.length
        if len == 0 { return NSRange(location: 0, length: 0) }
        var loc = tv.selectedRange.location
        if loc >= len { loc = len - 1 }
        let span = min(max(tv.selectedRange.length, 1), len - loc)
        return ns.lineRange(for: NSRange(location: loc, length: span))
    }

    private func isNumberedLine(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return false }
        let head = s[s.startIndex..<dot]
        guard head.allSatisfy({ $0.isNumber }) else { return false }
        let after = s.index(after: dot)
        return after < s.endIndex && s[after] == " "
    }

    private func stripNumber(_ s: String) -> String {
        guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return s }
        let head = s[s.startIndex..<dot]
        guard head.allSatisfy({ $0.isNumber }) else { return s }
        var rest = String(s[s.index(after: dot)...])
        if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
        return rest
    }

    /// 行级操作（列表/引用/编号）前的预处理：把每行拆成「缩进 + 正文」，并摘掉行首勾选框。
    /// 不摘的话列表符号会插在方框前面，方框不在行首就渲染不出来、露出标记字符变成乱码。
    private func linesWithoutCheckbox(_ comps: [String]) -> [(pad: String, body: String)] {
        comps.map { c -> (pad: String, body: String) in
            if let info = Self.markInfo(in: c) {
                return (pad: String(repeating: " ", count: info.loc),
                        body: (c as NSString).substring(from: info.len))
            }
            return (pad: "", body: c)
        }
    }
}

// MARK: - 存为模板

/// 把当前这条笔记（正文 + 富文本样式）存成模板。
/// 样式一起存：NoteTemplate 目前只有 name/body 两个字段，styleData 走
/// body 前缀的约定存不进来，所以这里额外给模板加了 styleData。
struct SaveAsTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TemplateStore.shared

let defaultName: String
/// 叫 templateBody 不叫 body：`body` 是 SwiftUI.View 的属性，
/// 参数名撞了会报 invalid redeclaration
    let templateBody: String
    let styleData: String

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section("模板名称") {
                    TextField("给模板起个名字", text: $name)
                        .font(.app(16))
                        .focused($focused)
                }

      Section {
  Text(templateBody.isEmpty ? "（正文是空的）"
        : String(templateBody.prefix(120)) + (templateBody.count > 120 ? "…" : ""))
                        .font(.app(12))
                        .foregroundColor(.secondary)
                } header: {
                    Text("将保存的内容")
                } footer: {
                    Text("模板会出现在「使用模板」的列表里。以后新建笔记时点一下就能套用这份内容和格式。")
                }
            }
            .navigationTitle("存为模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            name = defaultName
            focused = true
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !templateBody.isEmpty else { return }
        var t = NoteTemplate(name: n, body: templateBody)
        // 有样式才存，空的 styleData 写进去会让模板列表变重
        let s = NoteStyle.decode(styleData)
        if !s.isEmpty { t.styleData = styleData }
        store.upsert(t)
        dismiss()
    }
}

// MARK: - 模板选择页

struct TemplatePickerView: View {
    @ObservedObject var templateStore = TemplateStore.shared
    var onPick: (NoteTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(templateStore.templates) { t in
                        Button {
                            onPick(t)
                            dismiss()
                        } label: {
                            card(t)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Button {
                    managing = true
                } label: {
                    Text("管理模板")
                        .font(.app(15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("笔记模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .sheet(isPresented: $managing) {
                TemplateManageView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func card(_ t: NoteTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.name)
                .font(.app(15, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(TextEditBridge.displayFriendly(t.body))
                .font(.app(12))
                .foregroundColor(.secondary)
                .lineLimit(7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }
}

// MARK: - 管理模板

struct TemplateManageView: View {
    @ObservedObject var templateStore = TemplateStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NoteTemplate? = nil
    @State private var adding = false

    var body: some View {
        NavigationView {
            Group {
                if templateStore.templates.isEmpty {
                    Text("还没有模板，点右上角 + 新建")
                        .font(.app(13))
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(templateStore.templates) { t in
                            Button {
                                editing = t
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.name)
                                        .font(.app(15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(TextEditBridge.displayFriendly(t.body))
                                        .font(.app(12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx {
                                templateStore.delete(templateStore.templates[i].id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("管理模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                TemplateEditView(template: nil)
            }
            .sheet(item: $editing) { t in
                TemplateEditView(template: t)
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 新建 / 编辑模板

struct TemplateEditView: View {
    @ObservedObject var templateStore = TemplateStore.shared
    @Environment(\.dismiss) private var dismiss

    let template: NoteTemplate?
    @State private var name: String
    @State private var bodyText: String

    init(template: NoteTemplate?) {
        self.template = template
        _name = State(initialValue: template?.name ?? "")
        _bodyText = State(initialValue: template?.body ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("模板名称")) {
                    TextField("例如：会议纪要", text: $name)
                }
                Section(header: Text("模板内容")) {
                    TextEditor(text: $bodyText)
                        .font(.app(15))
                        .frame(minHeight: 240)
                }
            }
            .navigationTitle(template == nil ? "新建模板" : "编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
Button("保存") {
      let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !n.isEmpty else { return }
            var t = template ?? NoteTemplate(name: n, body: bodyText)
   t.name = n
            t.body = bodyText
            // 编辑只改文字，别把原来带的样式弄丢
    templateStore.upsert(t)
              dismiss()
    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
