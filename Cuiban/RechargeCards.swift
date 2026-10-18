import Foundation
import SwiftUI

// MARK: - 充值卡（按平台分组）
//
// 记的是「在哪个平台买了什么卡、花了多少、卖出去赚了多少」。
// 结构分两层：
//   · RechargePlatform —— 平台（一个平台一条，比如某个回收 / 充值渠道）；
//   · RechargeRecord   —— 这个平台下的一张卡（一次购买记录）。
// 金额 = 卡面值，实付 = 实际花的钱，利润 = 出手价 - 实付（自己填）。

struct RechargePlatform: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var note: String = ""
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey { case id, name, note, createdAt }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RechargePlatform()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
    }
}

struct RechargeRecord: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    /// 所属平台
    var platformId: String = ""
    /// 购买账户
    var account: String = ""
    /// 金额（卡面值）
    var faceValue: Double = 0
    /// 实付（实际花的钱）
    var paid: Double = 0
    /// 购买时间
    var purchaseDate: Date = Date()
    /// 使用时间；nil = 还没用
    var usedAt: Date? = nil
    /// 卖给谁
    var soldTo: String = ""
    /// 出的利润（元）；nil = 没记
    var profit: Double? = nil
    var note: String = ""
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, platformId, account, faceValue, paid, purchaseDate, usedAt, soldTo, profit, note, createdAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RechargeRecord()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        platformId = try c.decodeIfPresent(String.self, forKey: .platformId) ?? d.platformId
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? d.account
        faceValue = try c.decodeIfPresent(Double.self, forKey: .faceValue) ?? d.faceValue
        paid = try c.decodeIfPresent(Double.self, forKey: .paid) ?? d.paid
        purchaseDate = try c.decodeIfPresent(Date.self, forKey: .purchaseDate) ?? d.purchaseDate
        usedAt = try c.decodeIfPresent(Date.self, forKey: .usedAt)
        soldTo = try c.decodeIfPresent(String.self, forKey: .soldTo) ?? d.soldTo
        profit = try c.decodeIfPresent(Double.self, forKey: .profit)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
    }

    // MARK: 状态

    var isUsed: Bool { usedAt != nil }

    var statusText: String { isUsed ? "已使用" : "未使用" }
}

// MARK: - 仓库

final class RechargeStore: ObservableObject {
    static let shared = RechargeStore()

    @Published var platforms: [RechargePlatform] = []
    @Published var records: [RechargeRecord] = []

    private let file: URL

    /// 一个文件装两层数据（平台 + 记录），恢复 / 同步时不会对不上号
    struct Payload: Codable {
        var platforms: [RechargePlatform] = []
        var records: [RechargeRecord] = []
    }

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("cuiban_recharge.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder()
        if let p = try? dec.decode(Payload.self, from: data) {
            platforms = p.platforms
            records = p.records
        }
    }

    private func save() {
        let p = Payload(platforms: platforms, records: records)
        DispatchQueue.global(qos: .utility).async {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let d = try? enc.encode(p) { try? d.write(to: self.file) }
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cuibanDataChanged, object: nil)
            BackupStore.autoBackupIfNeeded(tasks: TaskStore.shared.tasks,
                                           settings: TaskStore.shared.settings)
        }
    }

    // MARK: 查询

    func platform(_ id: String?) -> RechargePlatform? {
        guard let id = id else { return nil }
        return platforms.first { $0.id == id }
    }

    func record(_ id: String?) -> RechargeRecord? {
        guard let id = id else { return nil }
        return records.first { $0.id == id }
    }

    /// 某个平台下的记录：没用过的在前，再按购买时间倒序
    func records(of platformId: String) -> [RechargeRecord] {
        records.filter { $0.platformId == platformId }
            .sorted { a, b in
                if a.isUsed != b.isUsed { return !a.isUsed }
                if a.purchaseDate != b.purchaseDate { return a.purchaseDate > b.purchaseDate }
                return a.createdAt > b.createdAt
            }
    }

    func count(of platformId: String) -> Int {
        records.reduce(0) { $0 + ($1.platformId == platformId ? 1 : 0) }
    }

    func unusedCount(of platformId: String) -> Int {
        records.reduce(0) { $0 + (($1.platformId == platformId && !$1.isUsed) ? 1 : 0) }
    }

    func paidTotal(of platformId: String) -> Double {
        records.reduce(0) { $0 + ($1.platformId == platformId ? $1.paid : 0) }
    }

    func profitTotal(of platformId: String) -> Double {
        records.reduce(0) { $0 + ($1.platformId == platformId ? ($1.profit ?? 0) : 0) }
    }

    var unusedTotal: Int { records.reduce(0) { $0 + ($1.isUsed ? 0 : 1) } }
    var paidGrandTotal: Double { records.reduce(0) { $0 + $1.paid } }
    var profitGrandTotal: Double { records.reduce(0) { $0 + ($1.profit ?? 0) } }

    // MARK: 修改

    func upsert(platform p: RechargePlatform) {
        if let i = platforms.firstIndex(where: { $0.id == p.id }) {
            platforms[i] = p
        } else {
            platforms.append(p)
        }
        save()
    }

    /// 删平台连带删它下面的记录（不然会留下一堆没有归属的孤儿记录）
    func deletePlatform(id: String) {
        platforms.removeAll { $0.id == id }
        records.removeAll { $0.platformId == id }
        save()
    }

    func upsert(record r: RechargeRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            records[i] = r
        } else {
            records.append(r)
        }
        save()
    }

    func deleteRecords(ids: [String]) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func markUsed(id: String?, at date: Date = Date()) {
        guard let id = id, let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[i].usedAt == nil else { return }
        records[i].usedAt = date
        save()
    }

    func unmarkUsed(id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].usedAt = nil
        save()
    }

    /// 备份 / 云同步恢复：整体替换
    func replaceAll(platforms ps: [RechargePlatform], records rs: [RechargeRecord]) {
        platforms = ps
        records = rs
        save()
    }
}

// MARK: - 充值卡列表（嵌在「卡券」页里的第二段）

struct RechargeListView: View {
    @EnvironmentObject var store: RechargeStore

    @State private var showingNewPlatform = false
    @State private var editingPlatform: RechargePlatform? = nil
    @State private var pendingDelete: RechargePlatform? = nil
    @State private var showingDeleteAlert = false

    var body: some View {
        List {
            Section { summary }

            Section {
                if store.platforms.isEmpty {
                    emptyHint
                } else {
                    ForEach(store.platforms) { p in
                        NavigationLink(destination: RechargePlatformView(platformId: p.id)) {
                            platformRow(p)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = p
                                showingDeleteAlert = true
                            } label: {
                                Label("删除平台", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Label("平台 · \(store.platforms.count)", systemImage: "square.stack.3d.up")
            } footer: {
                Text("先建平台（比如某个回收渠道 / 店铺），再往里一张张加购买记录。")
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .bottomTrailing) {
            FabButton { showingNewPlatform = true }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: $showingNewPlatform) {
            PlatformEditView()
        }
        .sheet(item: $editingPlatform) { p in
            PlatformEditView(editing: p)
        }
        .alert(isPresented: $showingDeleteAlert) {
            Alert(
                title: Text("删除平台？"),
                message: Text("「\(pendingDelete?.name ?? "")」下面的 \(store.count(of: pendingDelete?.id ?? "")) 条购买记录会一起删掉，不能恢复。"),
                primaryButton: .destructive(Text("删除")) {
                    if let p = pendingDelete { store.deletePlatform(id: p.id) }
                    pendingDelete = nil
                },
                secondaryButton: .cancel(Text("取消")) { pendingDelete = nil }
            )
        }
    }

    // MARK: 合计

    private var summary: some View {
        HStack(spacing: 0) {
            stat("未使用", "\(store.unusedTotal) 张")
            Divider().frame(height: 26)
            stat("实付合计", moneyText(store.paidGrandTotal))
            Divider().frame(height: 26)
            stat("已出利润", moneyText(store.profitGrandTotal), tint: rechargeProfitTint)
        }
        .listRowBackground(Color.clear)
    }

    private func stat(_ label: String, _ value: String,
                      tint: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.app(18, weight: .semibold))
                .foregroundColor(tint)
            Text(label)
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "creditcard")
                .font(.app(34))
                .foregroundColor(.secondary)
            Text("还没有平台").font(.app(15, weight: .medium))
            Text("点右下角 + 建第一个平台，再往里加购买记录")
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: 一行平台

    private func platformRow(_ p: RechargePlatform) -> some View {
        let total = store.count(of: p.id)
        let unused = store.unusedCount(of: p.id)
        let profit = store.profitTotal(of: p.id)
        return HStack(spacing: 12) {
            // 首字徽标：不引第三方图标，平台名第一个字够认了
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(brandColor.opacity(0.14))
                Text(String(p.name.isEmpty ? "?" : String(p.name.prefix(1))))
                    .font(.app(17, weight: .semibold))
                    .foregroundColor(brandColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(p.name.isEmpty ? "（未命名平台）" : p.name)
                    .font(.app(16, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(total) 张 · 未用 \(unused) · 实付 \(moneyText(store.paidTotal(of: p.id)))")
                    .font(.app(12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if profit != 0 {
                Text(moneyText(profit))
                    .font(.app(14, weight: .semibold))
                    .foregroundColor(rechargeProfitTint)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 利润的红：和优惠券的「已出利润」同一个色
let rechargeProfitTint = Color(red: 0.85, green: 0.20, blue: 0.16)
/// 已使用 / 已完成的那种青绿
let rechargeDoneTint = Color(red: 0.05, green: 0.43, blue: 0.34)

// MARK: - 平台详情（这个平台下的购买记录）

struct RechargePlatformView: View {
    @EnvironmentObject var store: RechargeStore

    let platformId: String

    @State private var showingAdd = false
    @State private var editing: RechargeRecord? = nil
    @State private var renaming = false

    private var platform: RechargePlatform? { store.platform(platformId) }
    private var list: [RechargeRecord] { store.records(of: platformId) }

    var body: some View {
        List {
            Section { summary }

            Section {
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "creditcard")
                            .font(.app(32))
                            .foregroundColor(.secondary)
                        Text("这个平台还没有购买记录").font(.app(15, weight: .medium))
                        Text("点右下角 + 记一张")
                            .font(.app(12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(list) { r in row(r) }
                }
            } header: {
                Text("购买记录 · \(list.count)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(platform?.name ?? "平台")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            FabButton { showingAdd = true }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: $showingAdd) {
            RechargeRecordEditView(platformId: platformId)
        }
        .sheet(item: $editing) { r in
            RechargeRecordEditView(platformId: platformId, editing: r)
        }
        .sheet(isPresented: $renaming) {
            if let p = platform { PlatformEditView(editing: p) }
        }
        .toolbar {
            Button("改平台") { renaming = true }
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            stat("未使用", "\(store.unusedCount(of: platformId)) 张")
            Divider().frame(height: 26)
            stat("实付", moneyText(store.paidTotal(of: platformId)))
            Divider().frame(height: 26)
            stat("利润", moneyText(store.profitTotal(of: platformId)), tint: rechargeProfitTint)
        }
        .listRowBackground(Color.clear)
    }

    private func stat(_ label: String, _ value: String,
                      tint: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.app(17, weight: .semibold))
                .foregroundColor(tint)
            Text(label)
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 一行记录

    @ViewBuilder
    private func row(_ r: RechargeRecord) -> some View {
        Button {
            editing = r
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(r))
                    .font(.app(19))
                    .foregroundColor(tint(r))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.account.isEmpty ? "（未填账户）" : r.account)
                            .font(.app(15, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if r.faceValue > 0 {
                            Text(moneyText(r.faceValue))
                                .font(.app(13, weight: .semibold))
                                .foregroundColor(brandColor)
                        }
                    }
                    Text(subtitle(r))
                        .font(.app(12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(r.statusText)
                        .font(.app(11, weight: .semibold))
                        .foregroundColor(tint(r))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint(r).opacity(0.14)))
                    if let p = r.profit, p != 0 {
                        Text("利润 " + moneyText(p))
                            .font(.app(11, weight: .semibold))
                            .foregroundColor(rechargeProfitTint)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteRecords(ids: [r.id])
            } label: {
                Label("删除", systemImage: "trash")
            }
            if r.isUsed {
                Button {
                    store.unmarkUsed(id: r.id)
                } label: {
                    Label("撤销已用", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            } else {
                Button {
                    store.markUsed(id: r.id)
                } label: {
                    Label("标记已用", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
    }

    private func icon(_ r: RechargeRecord) -> String {
        r.isUsed ? "checkmark.seal.fill" : "creditcard.fill"
    }

    private func tint(_ r: RechargeRecord) -> Color {
        r.isUsed ? rechargeDoneTint : brandColor
    }

    private func subtitle(_ r: RechargeRecord) -> String {
        var parts: [String] = ["买于 \(fmt(r.purchaseDate, "M/d HH:mm"))"]
        if r.paid > 0 { parts.append("实付 \(moneyText(r.paid))") }
        if let u = r.usedAt { parts.append("用了 \(fmt(u, "M/d"))") }
        if !r.soldTo.isEmpty { parts.append("卖给 \(r.soldTo)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 新增 / 编辑平台

struct PlatformEditView: View {
    @EnvironmentObject var store: RechargeStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RechargePlatform

    init(editing: RechargePlatform? = nil) {
        _draft = State(initialValue: editing ?? RechargePlatform())
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("平台名称"),
                        footer: Text("比如某个回收渠道、店铺或卡商。一个平台下面可以记很多张卡。")) {
                    TextField("平台名称", text: $draft.name)
                }
                Section(header: Text("备注")) {
                    TextField("可留空", text: $draft.note)
                }
            }
            .navigationTitle(store.platform(draft.id) == nil ? "新建平台" : "编辑平台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        var p = draft
                        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if p.name.isEmpty { p.name = "未命名平台" }
                        store.upsert(platform: p)
                        dismiss()
                    }
                    .font(.app(17, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 新增 / 编辑购买记录

struct RechargeRecordEditView: View {
    @EnvironmentObject var store: RechargeStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RechargeRecord
    /// 金额 / 实付 / 利润都用字符串驱动：Double 绑定会把默认 0 印在框里，
    /// 每次输入都得先删掉那个 0（这个坑在优惠券上踩过一次）
    @State private var faceText: String = ""
    @State private var paidText: String = ""
    @State private var profitText: String = ""
    @State private var purchaseDate = Date()
    @State private var used = false
    @State private var usedDate = Date()

    init(platformId: String, editing: RechargeRecord? = nil) {
        if let e = editing {
            var d = e
            if d.platformId.isEmpty { d.platformId = platformId }
            _draft = State(initialValue: d)
            _faceText = State(initialValue: e.faceValue > 0 ? plainMoney(e.faceValue) : "")
            _paidText = State(initialValue: e.paid > 0 ? plainMoney(e.paid) : "")
            _profitText = State(initialValue: e.profit.map { plainMoney($0) } ?? "")
            _purchaseDate = State(initialValue: e.purchaseDate)
            _used = State(initialValue: e.usedAt != nil)
            _usedDate = State(initialValue: e.usedAt ?? Date())
        } else {
            var d = RechargeRecord()
            d.platformId = platformId
            _draft = State(initialValue: d)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                if store.platforms.count > 1 {
                    Section(header: Text("平台")) {
                        Picker("平台", selection: $draft.platformId) {
                            ForEach(store.platforms) { p in
                                Text(p.name.isEmpty ? "（未命名平台）" : p.name).tag(p.id)
                            }
                        }
                    }
                }

                Section(header: Text("卡信息")) {
                    TextField("购买账户", text: $draft.account)
                    HStack {
                        Text("金额")
                        Spacer()
                        TextField("选填", text: $faceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130)
                        Text("元").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("实付")
                        Spacer()
                        TextField("选填", text: $paidText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130)
                        Text("元").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("购买时间")) {
                    DatePicker("购买时间",
                               selection: $purchaseDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }

                Section(header: Text("使用")) {
                    Toggle("已使用", isOn: $used)
                    if used {
                        DatePicker("使用时间",
                                   selection: $usedDate,
                                   displayedComponents: [.date, .hourAndMinute])
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                    }
                }

                Section(header: Text("出手")) {
                    TextField("卖给谁", text: $draft.soldTo)
                    HStack {
                        Text("出的利润")
                        Spacer()
                        TextField("选填", text: $profitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130)
                        Text("元").foregroundColor(.secondary)
                    }
                    .foregroundColor(rechargeProfitTint)
                }

                Section(header: Text("备注")) {
                    TextField("可留空", text: $draft.note)
                }
            }
            .navigationTitle(store.record(draft.id) == nil ? "新增购买记录" : "编辑购买记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .font(.app(17, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        var r = draft
        r.account = r.account.trimmingCharacters(in: .whitespacesAndNewlines)
        r.soldTo = r.soldTo.trimmingCharacters(in: .whitespacesAndNewlines)
        r.note = r.note.trimmingCharacters(in: .whitespacesAndNewlines)
        r.faceValue = max(0, parseMoney(faceText) ?? 0)
        r.paid = max(0, parseMoney(paidText) ?? 0)
        let pt = profitText.trimmingCharacters(in: .whitespacesAndNewlines)
        r.profit = pt.isEmpty ? nil : parseMoney(pt)
        r.purchaseDate = purchaseDate
        if used {
            r.usedAt = usedDate
        } else {
            r.usedAt = nil
        }
        // 新建时没填平台（一个平台都没有的极端情况）就落一个默认平台，别造孤儿记录
        if r.platformId.isEmpty {
            if let first = store.platforms.first {
                r.platformId = first.id
            } else {
                var p = RechargePlatform()
                p.name = "默认平台"
                store.upsert(platform: p)
                r.platformId = p.id
            }
        }
        store.upsert(record: r)
        dismiss()
    }
}
