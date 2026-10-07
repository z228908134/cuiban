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
    /// 附件占位字符（TextKit 只认这个字符渲染 NSTextAttachment）
    static let attachChar: Character = "\u{FFFC}"

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
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
        // 点勾选框直接打勾 / 取消（滴答式交互）
        // 必须挂 delegate，只有点在勾选框上时才接管这次点击，
        // 否则会连「点正文唤起键盘」一起抢掉
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = true
        tv.addGestureRecognizer(tap)
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

    // MARK: 纯文本 <-> 附件

    /// 把 UITextView 的富文本还原成「干净纯文本」：
    /// 勾选框附件占位符换回对应的标记字符（长度 1:1），外部附件丢弃。
    static func plainText(_ attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        guard ns.range(of: "\u{FFFC}").location != NSNotFound else { return attr.string }
        var out = ""
        var cursor = 0
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "\u{FFFC}", options: [], range: search)
            if r.location == NSNotFound { break }
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            if let att = attr.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment {
                if att.image === CheckboxArt.checked {
                    out += TextEditBridge.checkedMarkRaw
                } else if att.image === CheckboxArt.unchecked {
                    out += TextEditBridge.uncheckedMarkRaw
                }
            }
            cursor = r.location + r.length
            search = NSRange(location: cursor, length: ns.length - cursor)
        }
        out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return out
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
    /// 1. 勾选框标记字符（私有区）替换成 U+FFFC + 附件图片（1:1，光标不乱）
    /// 2. 勾选完成的待办整句删除线变灰、# 标题加粗、> 引用变灰（行级）
    /// 3. 富文本样式（加粗/斜体/下划线/删除线/高亮/等宽）按区间套上
    /// 打字期间（输入法有 markedText 组合状态）绝不重设 attributedText。
    static func restyle(_ tv: UITextView, styles: [NoteStyle], pending: Set<String>) {
        guard tv.markedTextRange == nil else { return }
        let content = tv.text ?? ""
        // 标记字符 -> 附件占位符（等长替换）
        let display = content
            .replacingOccurrences(of: TextEditBridge.checkedMarkRaw, with: String(Self.attachChar))
            .replacingOccurrences(of: TextEditBridge.uncheckedMarkRaw, with: String(Self.attachChar))
        let attr = NSMutableAttributedString(
            string: display,
            attributes: [.font: Self.baseFont, .foregroundColor: UIColor.label]
        )
        // display 上加属性；文本判断用原始 content（标记字符还在）
        let cns = content as NSString
        var loc = 0
        while loc < cns.length {
            let lr = cns.lineRange(for: NSRange(location: loc, length: 0))
            let line = cns.substring(with: lr)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // 行首的标记字符挂上对应方框图片（display 里它已是 U+FFFC）
            if line.hasPrefix(TextEditBridge.checkedMarkRaw)
                || line.hasPrefix(TextEditBridge.uncheckedMarkRaw) {
                let att = NSTextAttachment()
                att.image = line.hasPrefix(TextEditBridge.checkedMarkRaw)
                    ? CheckboxArt.checked : CheckboxArt.unchecked
                att.bounds = CGRect(x: 0, y: -3, width: 17, height: 17)
                attr.addAttribute(.attachment, value: att,
                                  range: NSRange(location: lr.location, length: 1))
            }

            if TextEditBridge.markerPrefix(in: trimmed, checked: true) != nil {
                // 已勾选：只给勾选框后面的那段文字加删除线并置灰
                if let p = TextEditBridge.markerPrefix(in: line, checked: true) {
                    var bodyLen = lr.length - (p as NSString).length
                    // 行尾换行不计入
                    if bodyLen > 0, cns.character(at: lr.location + (p as NSString).length + bodyLen - 1) == 0x0A {
                        bodyLen -= 1
                    }
                    if bodyLen > 0 {
                        attr.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: UIColor.secondaryLabel,
                            .foregroundColor: UIColor.secondaryLabel
                        ], range: NSRange(location: lr.location + (p as NSString).length, length: bodyLen))
                    }
                }
            } else if trimmed.hasPrefix("# ") {
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

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
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

        // MARK: 点勾选框打勾

        /// 只有点击落在勾选框附近时才接管这次点击，其余照常编辑
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let tap = g as? UITapGestureRecognizer,
                  let tv = parent.bridge.textView else { return true }
            return Self.tapHitsCheckbox(tap: tap, tv: tv)
        }

        /// 容器原点在 view 坐标系里的位置（= textContainerInset 的偏移）
        private static func containerOrigin(in tv: UITextView) -> CGPoint {
            let inset = tv.textContainerInset
            return CGPoint(x: inset.left, y: inset.top)
        }

        /// tap 点位换算到 text container 坐标（characterIndex 要的是容器坐标）
        private static func containerPoint(_ p: CGPoint, in tv: UITextView) -> CGPoint {
            let org = containerOrigin(in: tv)
            return CGPoint(x: p.x - org.x, y: p.y - org.y)
        }

        /// 行首字符（方框附件）在 view 坐标系里的矩形（放宽边距，好点）
        private static func checkboxRect(tv: UITextView, charIndex: Int) -> CGRect? {
            let lm = tv.layoutManager
            let glyphRange = lm.glyphRange(
                forCharacterRange: NSRange(location: charIndex, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }
            var r = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            let org = containerOrigin(in: tv)
            r.origin.x += org.x
            r.origin.y += org.y
            return r.insetBy(dx: -10, dy: -7)
        }

        private static func tapHitsCheckbox(tap: UITapGestureRecognizer, tv: UITextView) -> Bool {
            let attr = tv.attributedText ?? NSAttributedString()
            let ns = attr.string as NSString
            guard ns.length > 0 else { return false }
            // 等长校验：有外部附件时放弃接管，避免索引错位
            guard (NoteBodyEditor.plainText(attr) as NSString).length == ns.length else { return false }
            let raw = tap.location(in: tv)
            let p = containerPoint(raw, in: tv)
            let idx = tv.layoutManager.characterIndex(
                for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard idx != NSNotFound, idx >= 0, idx < ns.length else { return false }
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let line = ns.substring(with: lr)
            // 这一行必须是勾选行（行首是附件占位符或标记字符）
            guard line.hasPrefix(String(NoteBodyEditor.attachChar))
                || line.hasPrefix(TextEditBridge.checkedMarkRaw)
                || line.hasPrefix(TextEditBridge.uncheckedMarkRaw) else { return false }
            // 命中判定：点在方框图形（放宽边距）内，或索引就落在行首前两个字符
            if let rect = checkboxRect(tv: tv, charIndex: lr.location), rect.contains(raw) {
                return true
            }
            let rel = idx - lr.location
            return rel == 0 || rel == 1
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = parent.bridge.textView else { return }
            // 中文输入法还有拼音组合串时先提交，否则样式重排会被跳过，
            // 方框标记字符裸显示成「看不清的字 + 空格」
            if tv.markedTextRange != nil {
                tv.unmarkText()
            }
            let attr = tv.attributedText ?? NSAttributedString()
            let ns = attr.string as NSString
            guard ns.length > 0 else { return }
            let plain = NoteBodyEditor.plainText(attr)
            guard (plain as NSString).length == ns.length else { return }
            let raw = g.location(in: tv)
            let p = Self.containerPoint(raw, in: tv)
            let idx = tv.layoutManager.characterIndex(
                for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard idx != NSNotFound, idx >= 0, idx < ns.length else { return }
            let plainNS = plain as NSString
            let lr = plainNS.lineRange(
                for: NSRange(location: min(idx, plainNS.length - 1), length: 0)
            )
            let line = plainNS.substring(with: lr)
            var newLine: String? = nil
            if let u = TextEditBridge.markerPrefix(in: line, checked: false) {
                newLine = TextEditBridge.checkedMark + String(line.dropFirst(u.count))
            } else if let c = TextEditBridge.markerPrefix(in: line, checked: true) {
                newLine = TextEditBridge.uncheckedMark + String(line.dropFirst(c.count))
            }
            guard let nl = newLine else { return }
            let newAll = plainNS.replacingCharacters(in: lr, with: nl)
            parent.bridge.adjustStyles(old: plain, new: newAll)
            tv.text = newAll
            // 光标保持在这一行内的相对位置
            let rel = idx - lr.location
            let newNS = newAll as NSString
            let lineLen = (nl as NSString).length
            tv.selectedRange = NSRange(
                location: min(lr.location + min(max(rel, 0), max(lineLen - 1, 0)), newNS.length),
                length: 0
            )
            NoteBodyEditor.restyle(tv, styles: parent.bridge.styles,
                                   pending: parent.bridge.pendingTraits)
            if parent.text != newAll {
                parent.text = newAll
            }
            parent.bridge.record(tv)
        }
    }
}

// MARK: - 勾选框图形

/// 画出来的勾选框（滴答清单式圆角方框），替代 ⬜️ / ✅ 这类 emoji。
/// 未勾选是细描边灰方框，勾选是蓝底白勾。
enum CheckboxArt {
    static let unchecked = image(checked: false)
    static let checked = image(checked: true)

    static func image(checked: Bool) -> UIImage {
        let size = CGSize(width: 17, height: 17)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 1.6, y: 1.6, width: 13.8, height: 13.8)
            let box = UIBezierPath(roundedRect: rect, cornerRadius: 3.6)
            if checked {
                UIColor.systemBlue.setFill()
                box.fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: 4.9, y: 8.9))
                check.addLine(to: CGPoint(x: 7.3, y: 11.2))
                check.addLine(to: CGPoint(x: 12.2, y: 5.9))
                check.lineWidth = 1.9
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                UIColor.white.setStroke()
                check.stroke()
            } else {
                UIColor.systemGray.setStroke()
                box.lineWidth = 1.4
                box.stroke()
            }
        }
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

    /// 标记字符本体（不含尾随空格）；存储与比较用
    static let checkedMarkRaw = "\u{E001}"
    static let uncheckedMarkRaw = "\u{E000}"

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
        let nonEmpty = comps.filter { !$0.isEmpty }
        let has = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
        let out = comps.map { line -> String in
            if line.isEmpty { return line }
            return has ? String(line.dropFirst(prefix.count)) : prefix + line
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
        let nonEmpty = comps.filter { !$0.isEmpty }
        let allNumbered = !nonEmpty.isEmpty && nonEmpty.allSatisfy(isNumberedLine)

        var counter = 1
        let out = comps.map { line -> String in
            if line.isEmpty { return line }
            let stripped = stripNumber(line)
            if allNumbered { return stripped }
            let s = "\(counter). " + stripped
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
            if line.isEmpty { return line }
            if let p = Self.markerPrefix(in: line, checked: true) {
                return Self.uncheckedMark + String(line.dropFirst(p.count))
            }
            if let p = Self.markerPrefix(in: line, checked: false) {
                return Self.checkedMark + String(line.dropFirst(p.count))
            }
            // 去掉其它列表前缀再挂勾选框，避免叠加
            var s = line
            for p in ["- ", "> ", "1. ", "2. ", "3. "] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
            return Self.uncheckedMark + s
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

    /// 行首若带勾选标记，返回去掉标记后的正文；否则返回 nil
    static func stripMark(in line: String) -> String? {
        for checked in [true, false] {
            if let p = markerPrefix(in: line, checked: checked) {
                return String(line.dropFirst(p.count))
            }
        }
        return nil
    }

    /// 旧写法（⬜️ / ✅ / - [ ] / - [x] / ☐ / ☑️）统一迁移为新标记
    static func migrate(_ s: String) -> String {
        let legacy: [(String, Bool)] = [
            ("✅ ", true), ("- [x] ", true), ("- [X] ", true), ("☑️ ", true),
            ("⬜️ ", false), ("- [ ] ", false), ("☐ ", false)
        ]
        return s.components(separatedBy: "\n").map { line -> String in
            guard !line.isEmpty else { return line }
            for (old, checked) in legacy where line.hasPrefix(old) {
                return (checked ? checkedMark : uncheckedMark) + String(line.dropFirst(old.count))
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
    private func lineRange(_ tv: UITextView, ns: NSString) -> NSRange {
        let len = ns.length
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
