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
        NavigationView {
            Group {
                if noteStore.notes.isEmpty {
                    emptyHint
                } else {
                    List {
                        ForEach(noteStore.sorted) { n in
                            row(n)
                        }
                        .onDelete { idx in
                            let ids = idx.map { noteStore.sorted[$0].id }
                            noteStore.delete(ids: ids)
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
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("还没有笔记")
                .font(.system(size: 15, weight: .medium))
            Text("点右下角 + 记一条，想法、备忘都能写")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ n: NoteItem) -> some View {
        Button {
            editing = n
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(n.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(n.snippet)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(fmt(n.updatedAt, "M月d日 HH:mm"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                    if !n.photos.isEmpty {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 笔记编辑器

struct NoteEditorView: View {
    @EnvironmentObject var noteStore: NoteStore
    @Environment(\.dismiss) private var dismiss

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
    @State private var bridge: TextEditBridge

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
        let br = TextEditBridge()
        br.styles = NoteStyle.decode(note?.styleData)
        _bridge = State(initialValue: br)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextField("笔记标题", text: $title)
                    .font(.system(size: 20, weight: .semibold))
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { saveAndClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showTemplates = true
                    } label: {
                        Text("使用模板")
                            .font(.system(size: 14))
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
            .onDisappear { saveIfWorth() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 正文

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            if bodyText.isEmpty {
                // 纯展示的占位（不拦点击，点它也能唤起键盘）
                Text("记录你的想法，或使用模板")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
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
            if ImagePicker.cameraAvailable {
                Button { photoSource = .camera } label: { Label("拍照", systemImage: "camera") }
            }
            Button { hideKeyboard() } label: { Label("收起键盘", systemImage: "keyboard.chevron.compact.down") }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 17, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .accentColor : .primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }

    private func barText(_ s: String, strike: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s)
                .font(.system(size: 15, weight: active ? .bold : .semibold))
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
                                    .font(.system(size: 16))
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

    private func applyTemplate(_ t: NoteTemplate) {
        let tb = TextEditBridge.migrate(t.body)
        let cur = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.isEmpty {
            bodyText = tb
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = t.name
            }
        } else {
            bodyText = bodyText + "\n\n" + tb
        }
    }

    private func saveAndClose() {
        saveIfWorth()
        dismiss()
    }

    /// 空笔记不保存；有内容就写库
    private func saveIfWorth() {
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !photos.isEmpty
        guard hasContent else { return }

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

    static let baseFont = UIFont.systemFont(ofSize: 16)

    func makeUIView(context: Context) -> UITextView {
        let tv = CheckboxTextView()
        tv.font = Self.baseFont
        tv.textColor = .label
        tv.backgroundColor = .clear
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
        var tp: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: UIColor.label]
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
            attributes: [.font: Self.baseFont, .foregroundColor: UIColor.label]
        )
        let cns = content as NSString
        var loc = 0
        while loc < cns.length {
            let lr = cns.lineRange(for: NSRange(location: loc, length: 0))
            let line = cns.substring(with: lr)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // 勾选框：直接用「☐ / ☑」字符本体（滴答清单同款细描边空心方框），
            // 不再叠加绘制的附件图片——两层叠在一起会又脏又难看。
            // 方框比正文大一号（更好看也好点），颜色略浅；勾上后随整行一起变浅。
            let info = TextEditBridge.markInfo(in: line)
            if let info = info, info.markLen > 0 {
                attr.addAttributes([
                    .font: UIFont.systemFont(ofSize: 19),
                    .foregroundColor: info.checked
                        ? UIColor.tertiaryLabel
                        : UIColor.label.withAlphaComponent(0.82)
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
                    value: UIFont.systemFont(ofSize: 19, weight: .semibold),
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

        /// 命中判定：点落在某个勾选行「方框」的热区里 → 返回该行范围 + 标记位置 + 标记长度 + 当前勾选态。
        /// 用 caretRect 拿方框位置：它由系统按 inset / 滚动偏移算好，永远和光标所见一致，
        /// 不再自己换算 textContainer 坐标（之前那套换算就是一直不准的根源）。
        /// 热区故意放得很大（手指点不准 19pt 的方框），所以收集所有命中的行、
        /// 取离手指最近的那个，避免上下相邻两行都是待办时点错行。
        private static func checkboxHit(at point: CGPoint, in tv: UITextView)
            -> (range: NSRange, markLoc: Int, markLen: Int, checked: Bool)? {
            let ns = (tv.text ?? "") as NSString
            var loc = 0
            var best: (range: NSRange, markLoc: Int, markLen: Int, checked: Bool)?
            var bestDist: CGFloat = .greatestFiniteMagnitude

            func consider(_ range: NSRange, _ markLoc: Int, _ markLen: Int,
                          _ checked: Bool, _ box: CGRect) {
                // 点到方框中心的距离最近的胜出
                let cx = box.midX, cy = box.midY
                let dx = point.x - cx, dy = point.y - cy
                let d = sqrt(dx * dx + dy * dy)
                if d < bestDist {
                    bestDist = d
                    best = (range, markLoc, markLen, checked)
                }
            }

            while loc < ns.length {
                let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
                if lr.length > 0, let info = TextEditBridge.markInfo(in: ns.substring(with: lr)) {
                    let markLoc = lr.location + info.loc
                    if let pos = tv.position(from: tv.beginningOfDocument, offset: markLoc) {
                        let cr = tv.caretRect(for: pos)
                        // 方框 19pt 但手指很难点准：热区左右大幅放宽、纵向也加高
                        let hot = CGRect(x: cr.minX - 14,
                                         y: cr.minY - 6,
                                         width: 22 + CGFloat(info.markLen) * 16,
                                         height: cr.height + 14)
                        if hot.contains(point) {
                            consider(lr, markLoc, info.markLen, info.checked, hot)
                        }
                    }
                    // 兜底：让系统告诉我们这个点最近的字符位置（同样是系统算坐标，最稳）
                    if best == nil, let near = tv.closestPosition(to: point) {
                        let idx = tv.offset(from: tv.beginningOfDocument, to: near)
                        // 方框本身 + 方框后面那个空格都算点在框上
                        if idx >= markLoc && idx <= markLoc + info.markLen {
                            consider(lr, markLoc, info.markLen, info.checked,
                                     CGRect(x: point.x, y: point.y, width: 1, height: 1))
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
    /// 用「☐ / ☑」细描边方框字符（滴答清单同款），不加变体选择符：
    /// 加了会变成彩色 emoji 方块，和滴答的细线方框不一样。
    static let checkedMarkRaw = "\u{2611}"
    static let uncheckedMarkRaw = "\u{2610}"

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
            ? [checkedMark, "✅ ", "- [x] ", "- [X] ", "☑️ "]
            : [uncheckedMark, "⬜️ ", "- [ ] ", "☐ "]
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
            ("⬜️ ", false), ("- [ ] ", false), ("☐ ", false), ("☐️ ", false)
        ]
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
                        .font(.system(size: 15, weight: .medium))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(TextEditBridge.displayFriendly(t.body))
                .font(.system(size: 12))
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
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(templateStore.templates) { t in
                            Button {
                                editing = t
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(TextEditBridge.displayFriendly(t.body))
                                        .font(.system(size: 12))
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
                        .font(.system(size: 15))
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
