import SwiftUI
import UIKit

// MARK: - 卡片备份列表页

struct CardListView: View {
    @ObservedObject private var store = CardStore.shared
    @State private var filter: CardType? = nil
    @State private var keyword: String = ""
    @State private var editing: CardItem? = nil
    @State private var detail: CardItem? = nil
    @State private var showingAdd = false
    /// 列表页统一提示弹窗
    @State private var alertInfo: AlertInfo? = nil

    private func pickFromClipboard() {
        let text = UIPasteboard.general.string ?? ""
        // 卡号一般是 12~24 位连续数字
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 12 else {
            alertInfo = AlertInfo(title: "没识别到卡号",
                                  message: "剪贴板里没有 12 位以上的连续数字。",
                                  okTitle: "好")
            return
        }
        var c = CardItem()
        c.number = String(digits.prefix(24))
        alertInfo = AlertInfo(title: "识别到卡号",
                              message: c.numberGrouped + "\n\n要去填写完整信息吗？",
                              okTitle: "去填写") { editing = c }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            chips
            Divider()
            listBody
        }
        .navigationTitle("卡片备份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20, weight: .regular))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        filter = nil
                    } label: { Label("显示全部", systemImage: "square.grid.2x2") }
                    Divider()
                    ForEach(CardType.allCases) { t in
                        Button {
                            filter = t
                        } label: { Label(t.label, systemImage: "creditcard") }
                    }
                    Divider()
                    Button {
                        pickFromClipboard()
                    } label: { Label("从剪贴板识别卡号", systemImage: "doc.on.clipboard") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .regular))
                }
            }
        }
        .sheet(item: $editing) { c in
            CardEditView(card: c)
        }
        .sheet(isPresented: $showingAdd) {
            CardEditView(card: nil)
        }
        .sheet(item: $detail) { c in
            CardDetailView(cardID: c.id)
        }
        .alert(item: $alertInfo) { info in
            Alert(title: Text(info.title),
                  message: Text(info.message),
                  primaryButton: .destructive(Text(info.okTitle)) { info.onOK?() },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    /// 列表页的提示弹窗（避免同视图挂多个 alert）
    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var okTitle: String = "好"
        var onOK: (() -> Void)? = nil
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            TextField("搜银行 / 卡号 / 户主 / 备注", text: $keyword)
                .font(.system(size: 15))
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: 分类筛选

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", count: store.count(nil), active: filter == nil) { filter = nil }
                ForEach(CardType.allCases) { t in
                    chip(title: t.label, count: store.count(t), active: filter == t) {
                        filter = filter == t ? nil : t
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? .white.opacity(0.85) : .secondary)
            }
            .foregroundColor(active ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(active ? brandColor : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 列表

    @ViewBuilder
    private var listBody: some View {
        let list = store.filtered(filter, keyword: keyword)
        if list.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "creditcard")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text(store.cards.isEmpty ? "还没有卡片" : "这个分类下还没有卡片")
                    .font(.system(size: 15, weight: .medium))
                Text(store.cards.isEmpty ? "点右上角 + 存一张，卡号和图片都只存在本机" : "换个分类看看")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(list) { c in
                        Button {
                            detail = c
                        } label: {
                            CardRow(card: c)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editing = c
                            } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) {
                                alertInfo = AlertInfo(
                                    title: "删除这张卡片？",
                                    message: c.displayName,
                                    okTitle: "删除") { store.delete(id: c.id) }
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

/// 列表里的一行：银行名 / 类型+备注 / 大号卡号
struct CardRow: View {
    let card: CardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(card.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if !card.photos.isEmpty {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            Text(card.subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if !card.number.isEmpty {
                Text(card.numberGrouped)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - 卡片详情页（点进去看图片）

struct CardDetailView: View {
    let cardID: String
    @ObservedObject private var store = CardStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editing = false
    @State private var viewerStart = 0
    @State private var viewerOpen = false
    @State private var confirmDelete = false

    private var card: CardItem? {
        store.cards.first { $0.id == cardID }
    }

    var body: some View {
        Group {
            if let c = card {
                content(c)
            } else {
                Text("这张卡片已被删除")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("卡片备份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("编辑") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            if let c = card {
                CardEditView(card: c)
            }
        }
        .fullScreenCover(isPresented: $viewerOpen) {
            if let c = card {
                PhotoViewer(images: AttachmentStore.loadAll(c.photos),
                            titles: c.photos.indices.map { "第 \($0 + 1) 张，共 \(c.photos.count) 张" },
                            start: viewerStart)
            }
        }
        .alert("删除这张卡片？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let c = card { store.delete(id: c.id) }
                self.dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func content(_ c: CardItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 卡面
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(c.type.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Image(systemName: "creditcard")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Text(c.numberGrouped.isEmpty ? "未填卡号" : c.numberGrouped)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(c.bank.isEmpty ? "未填开户行" : c.bank)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [brandColor, brandColor.opacity(0.72)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )

                // 明细
                VStack(spacing: 0) {
                    infoRow("类型", c.type.label)
                    divider
                    infoRow("银行", c.bank.isEmpty ? "—" : c.bank)
                    divider
                    infoRow("卡号", c.number.isEmpty ? "—" : c.numberGrouped)
                    divider
                    infoRow("户主", c.holder.isEmpty ? "—" : c.holder)
                    divider
                    infoRow("备注", c.note.isEmpty ? "—" : c.note)
                }
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                )

                // 图片
                VStack(alignment: .leading, spacing: 8) {
                    Text("图片")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    if c.photos.isEmpty {
                        Text("没有图片")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(c.photos.indices, id: \.self) { i in
                                    if let img = AttachmentStore.load(c.photos[i]) {
                                        Button {
                                            viewerStart = i
                                            viewerOpen = true
                                        } label: {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 108, height: 108)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("删除这张卡片")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 30)
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
                .font(.system(size: 15))
                .frame(width: 72, alignment: .leading)
            Text(v)
                .font(.system(size: 15))
                .foregroundColor(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
    }
}

// MARK: - 新建 / 编辑卡片

struct CardEditView: View {
    /// nil = 新建
    let card: CardItem?

    private enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }

    @ObservedObject private var store = CardStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var type: CardType = .debit
    @State private var bank: String = ""
    @State private var number: String = ""
    @State private var holder: String = ""
    @State private var note: String = ""
    @State private var photos: [String] = []
    @State private var createdAt: Date = Date()

    @State private var showTypePicker = false
    @State private var photoSource: PhotoSource? = nil
    @State private var viewerStart = 0
    @State private var viewerOpen = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                form
                Spacer()
                saveButton
            }
            .navigationTitle("卡片备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { self.dismiss() }
                }
            }
            .sheet(item: $photoSource) { src in
                ImagePicker(sourceType: src == .camera ? .camera : .photoLibrary) { img in
                    photoSource = nil
                    if let n = AttachmentStore.save(img) { photos.append(n) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showTypePicker) {
                CardTypePicker(current: type) { t in
                    type = t
                    showTypePicker = false
                }
                .presentationDetents([.height(430)])
            }
            .fullScreenCover(isPresented: $viewerOpen) {
                PhotoViewer(images: AttachmentStore.loadAll(photos),
                            titles: photos.indices.map { "第 \($0 + 1) 张，共 \(photos.count) 张" },
                            start: viewerStart)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if let c = card {
                type = c.type
                bank = c.bank
                number = c.number
                holder = c.holder
                note = c.note
                photos = c.photos
                createdAt = c.createdAt
            }
        }
    }

    // MARK: 表单

    private var form: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                row {
                    Text("类型").font(.system(size: 15))
                    Spacer()
                    Button {
                        showTypePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.label)
                                .font(.system(size: 15))
                                .foregroundColor(.primary.opacity(0.9))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                sep
                row {
                    field("银行", text: $bank, prompt: "如 浦发 / 工行")
                }
                sep
                row {
                    field("卡号", text: $number, prompt: "支持 4 位分组", keyboard: .numberPad)
                }
                sep
                row {
                    field("户主（非必填）", text: $holder, prompt: "")
                }
                sep
                row {
                    field("备注（非必填）", text: $note, prompt: "")
                }
                sep
                row {
                    Text("图片").font(.system(size: 15))
                    Spacer()
                    Button {
                        photoSource = .library
                    } label: {
                        HStack(spacing: 4) {
                            Text(photos.isEmpty ? "上传" : "\(photos.count) 张")
                                .font(.system(size: 15))
                                .foregroundColor(.primary.opacity(0.9))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if !photos.isEmpty {
                photoThumbs
            }
        }
    }

    private var photoThumbs: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(photos.indices, id: \.self) { i in
                        if let img = AttachmentStore.load(photos[i]) {
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    viewerStart = i
                                    viewerOpen = true
                                } label: {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 92, height: 92)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                Button {
                                    AttachmentStore.delete([photos[i]])
                                    photos.remove(at: i)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    if ImagePicker.cameraAvailable {
                        Button {
                            photoSource = .camera
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "camera")
                                    .font(.system(size: 20))
                                    .foregroundColor(brandColor)
                                Text("拍照")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 92, height: 92)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var saveButton: some View {
        VStack {
            Divider()
            Button(action: save) {
                Text("保存")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(brandColor))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: 行

    private var sep: some View {
        Divider().padding(.leading, 14)
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(.vertical, 14)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String,
                       keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .frame(width: 116, alignment: .leading)
            TextField(prompt, text: text)
                .font(.system(size: 15))
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: 保存

    private func save() {
        var c = card ?? CardItem()
        c.type = type
        c.bank = bank.trimmingCharacters(in: .whitespaces)
        c.number = number.filter { $0.isNumber }
        c.holder = holder.trimmingCharacters(in: .whitespaces)
        c.note = note.trimmingCharacters(in: .whitespaces)
        c.photos = photos
        c.createdAt = createdAt
        c.updatedAt = Date()
        store.upsert(c)
        // 被移除的图片从磁盘清掉
        if let old = card {
            let gone = Set(old.photos).subtracting(Set(photos))
            if !gone.isEmpty { AttachmentStore.delete(Array(gone)) }
        }
        self.dismiss()
    }
}

// MARK: - 卡片类型选择（底部弹层）

struct CardTypePicker: View {
    let current: CardType
    let onPick: (CardType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("卡片类型")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(CardType.allCases) { t in
                Button {
                    onPick(t)
                } label: {
                    HStack {
                        Text(t.label)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                        Spacer()
                        if t == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(red: 0.0, green: 0.48, blue: 1.0))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 18)
            }
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}
