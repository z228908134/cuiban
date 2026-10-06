import SwiftUI

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
    @State private var photoSource: PhotoSource? = nil
    @State private var showTemplates = false
    @State private var bridge = TextEditBridge()

    private enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }

    init(note: NoteItem?) {
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _bodyText = State(initialValue: TextEditBridge.migrate(note?.body ?? ""))
        _photos = State(initialValue: note?.photos ?? [])
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
                // 纯展示的占位（不拦点击，点它也能唤起键盘）；
                // 打开模板走右上角「使用模板」或工具栏的模板按钮
                Text("记录你的想法，或使用模板")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)
            }
            NoteBodyEditor(text: $bodyText, bridge: bridge)
                .padding(.horizontal, 12)
        }
    }

    // MARK: 格式工具栏（对齐滴答清单 input_md_* 全套：撤销/重做/标题/加粗/斜体/下划线/删除线/高亮/待办/列表/缩进/引用/代码/链接/时间/分割线）

    private var formatBar: some View {
        HStack(spacing: 0) {
            barIcon("photo.on.rectangle") { photoSource = .library }
            barIcon("clock") { bridge.insert(fmt(Date(), "M月d日 HH:mm ")) }
            barIcon("arrow.uturn.backward") { bridge.undo() }

            barDivider

            barText("H") { bridge.toggleLinePrefix("# ") }
            barText("B") { bridge.wrap("**", "**") }
            barText("S", strike: true) { bridge.wrap("~~", "~~") }
            barIcon("highlighter") { bridge.wrap("==", "==") }

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
            Button { bridge.wrap("*", "*") } label: { Label("斜体", systemImage: "textformat.italic") }
            Button { bridge.wrap("__", "__") } label: { Label("下划线", systemImage: "underline") }
            Button { bridge.toggleLinePrefix("> ") } label: { Label("引用", systemImage: "text.quote") }
            Button { bridge.wrap("`", "`") } label: { Label("代码", systemImage: "curlybraces") }
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

    private func barIcon(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }

    private func barText(_ s: String, strike: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s)
                .font(.system(size: 15, weight: .semibold))
                .strikethrough(strike)
                .foregroundColor(.primary.opacity(0.8))
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
/// bridge 负责从工具栏对正文做插入 / 包裹 / 行前缀操作。
/// 编辑时实时套样式：勾选完成的待办整句加删除线并变灰。
struct NoteBodyEditor: UIViewRepresentable {
    @Binding var text: String
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
        // 工具栏操作后重新套样式（附件/删除线/标题）
        bridge.refreshUI = { [weak tv] in
            guard let tv = tv else { return }
            NoteBodyEditor.restyle(tv)
        }
        // 点勾选框直接打勾 / 取消（滴答式交互）
        // 注意：必须挂 delegate，只有点在勾选框上时才接管这次点击，
        // 否则会连「点正文唤起键盘」一起抢掉，导致进不去编辑状态
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = true
        tv.addGestureRecognizer(tap)
        NoteBodyEditor.restyle(tv)
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
            NoteBodyEditor.restyle(tv)
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

    /// 给正文上轻量样式：勾选行删除线变灰、# 标题加粗、> 引用变灰。
    /// 勾选框标记字符（私有区）显示时替换成 U+FFFC + 附件图片（1:1，光标不乱）。
    /// 打字期间（输入法有 markedText 组合状态）绝不重设 attributedText，
    /// 否则组合串会被清掉、字打不进去。
    static func restyle(_ tv: UITextView) {
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
        let sel = tv.selectedRange
        tv.attributedText = attr
        tv.typingAttributes = [.font: Self.baseFont, .foregroundColor: UIColor.label]
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
            if parent.text != clean {
                parent.text = clean
            }
            parent.bridge.record(tv)
            NoteBodyEditor.restyle(tv)
        }

        /// 编辑结束（键盘收起）后再补一次样式
        func textViewDidEndEditing(_ tv: UITextView) {
            NoteBodyEditor.restyle(tv)
        }

        // MARK: 点勾选框打勾

        /// 只有点击落在勾选框标记上时才接管这次点击，其余照常编辑
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let tap = g as? UITapGestureRecognizer,
                  let tv = parent.bridge.textView else { return true }
            return Self.tapHitsCheckbox(tap: tap, tv: tv)
        }

        private static func tapHitsCheckbox(tap: UITapGestureRecognizer, tv: UITextView) -> Bool {
            let attr = tv.attributedText ?? NSAttributedString()
            let ns = attr.string as NSString
            guard ns.length > 0 else { return false }
            // 等长校验：有外部附件时放弃接管，避免索引错位
            guard (NoteBodyEditor.plainText(attr) as NSString).length == ns.length else { return false }
            let p = tap.location(in: tv)
            let idx = tv.layoutManager.characterIndex(
                for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard idx >= 0, idx < ns.length else { return false }
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let line = ns.substring(with: lr)
            // 勾选框是行首第一个字符（附件占位符或标记字符）
            guard line.hasPrefix(String(NoteBodyEditor.attachChar))
                || line.hasPrefix(TextEditBridge.checkedMarkRaw)
                || line.hasPrefix(TextEditBridge.uncheckedMarkRaw) else { return false }
            let rel = idx - lr.location
            return rel == 0
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = parent.bridge.textView else { return }
            let attr = tv.attributedText ?? NSAttributedString()
            let ns = attr.string as NSString
            guard ns.length > 0 else { return }
            let plain = NoteBodyEditor.plainText(attr)
            guard (plain as NSString).length == ns.length else { return }
            let p = g.location(in: tv)
            let idx = tv.layoutManager.characterIndex(
                for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard idx >= 0, idx < ns.length else { return }
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
            tv.text = newAll
            // 光标保持在这一行内的相对位置
            let rel = idx - lr.location
            let newNS = newAll as NSString
            let lineLen = (nl as NSString).length
            tv.selectedRange = NSRange(
                location: min(lr.location + min(max(rel, 0), max(lineLen - 1, 0)), newNS.length),
                length: 0
            )
            NoteBodyEditor.restyle(tv)
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
    /// 工具栏操作完成后让编辑器重新套样式（附件/删除线/标题）
    var refreshUI: (() -> Void)? = nil

    /// 标记字符本体（不含尾随空格）；存储与比较用
    static let checkedMarkRaw = "\u{E001}"
    static let uncheckedMarkRaw = "\u{E000}"

    // MARK: 撤销 / 重做（自维护历史，工具栏操作也能撤销）

    private var history: [(text: String, sel: NSRange)] = []
    private var histIdx: Int = -1
    private var suppressRecord = false

    /// 记录当前状态到历史（输入变化、工具栏操作后都调用）
    func record(_ tv: UITextView) {
        guard !suppressRecord else { return }
        let t = NoteBodyEditor.plainText(tv.attributedText)
        let sel = tv.selectedRange
        if histIdx >= 0, histIdx < history.count, history[histIdx].text == t {
            history[histIdx] = (t, sel)
            return
        }
        if histIdx + 1 < history.count {
            history.removeSubrange((histIdx + 1)...)
        }
        history.append((t, sel))
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
        let (t, sel) = history[histIdx]
        suppressRecord = true
        tv.text = t
        tv.selectedRange = sel
        suppressRecord = false
        refreshUI?()
        onEdited?(t)
    }

    /// 光标处插入一段文字
    func insert(_ s: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let ns = tv.text as NSString
        let r = tv.selectedRange
        tv.text = ns.replacingCharacters(in: r, with: s)
        tv.selectedRange = NSRange(location: r.location + (s as NSString).length, length: 0)
        finish(tv)
    }

    /// 把选中文字包进前后缀；没有选中就插入一对并停在中间
    func wrap(_ prefix: String, _ suffix: String) {
        guard let tv = textView else { return }
        syncPlain(tv)
        let ns = tv.text as NSString
        let r = tv.selectedRange
        let sel = ns.substring(with: r)
        tv.text = ns.replacingCharacters(in: r, with: prefix + sel + suffix)
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
        let ns = tv.text as NSString
        let lr = lineRange(tv, ns: ns)
        let comps = ns.substring(with: lr).components(separatedBy: "\n")
        let nonEmpty = comps.filter { !$0.isEmpty }
        let has = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
        let out = comps.map { line -> String in
            if line.isEmpty { return line }
            return has ? String(line.dropFirst(prefix.count)) : prefix + line
        }
        let joined = out.joined(separator: "\n")
        tv.text = ns.replacingCharacters(in: lr, with: joined)
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    /// 有序列表：已编号则去掉编号，否则逐行重新编号
    func renumberList() {
        guard let tv = textView else { return }
        syncPlain(tv)
        let ns = tv.text as NSString
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
        tv.text = ns.replacingCharacters(in: lr, with: joined)
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    /// 待办勾选开关：无勾选框 → 加未勾选方框；未勾选 → 已勾选；已勾选 → 取消。
    /// 勾上后那一段文字自动加删除线并变灰，见 NoteBodyEditor.restyle
    func toggleChecklist() {
        guard let tv = textView else { return }
        syncPlain(tv)
        let ns = tv.text as NSString
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
            // 去掉其它列表前缀再挂勾选框，避免「- □ 」叠加
            var s = line
            for p in ["- ", "> ", "1. ", "2. ", "3. "] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
            return Self.uncheckedMark + s
        }
        let joined = out.joined(separator: "\n")
        tv.text = ns.replacingCharacters(in: lr, with: joined)
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
        let pad = "    "
        let ns = tv.text as NSString
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
        tv.text = ns.replacingCharacters(in: lr, with: joined)
        tv.selectedRange = NSRange(location: lr.location + (joined as NSString).length, length: 0)
        finish(tv)
    }

    // MARK: 私有

    /// 把 UITextView 里的附件占位符还原成标记字符，让后续字符串操作按纯文本进行
    private func syncPlain(_ tv: UITextView) {
        let plain = NoteBodyEditor.plainText(tv.attributedText)
        if plain != tv.text {
            tv.text = plain
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
            Text(t.body)
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
                                    Text(t.body)
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
