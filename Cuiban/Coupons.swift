import Foundation
import SwiftUI
import UserNotifications

// MARK: - 优惠券备忘

/// 一张优惠券的备忘。
///
/// 关注的是「别放过期」和「赚了多少」两件事，所以字段就按卡面来：
/// 券名 / 金额 / 领的日期 / 过期时间 / 使用时间 / 卖给谁 / 出的利润。
struct Coupon: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    /// 券的名字
    var name: String = ""
    /// 面额（元）
    var amount: Double = 0
    /// 领的日期
    var acquiredDate: Date = Date()
    /// 过期时间
    var expiryDate: Date = Date().addingTimeInterval(7 * 86400)
    /// 使用时间；nil = 还没用
    var usedDate: Date? = nil
    /// 卖给谁
    var soldTo: String = ""
    /// 出的利润（元）；nil = 没记
    var profit: Double? = nil
    /// 备注
    var note: String = ""
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, amount, acquiredDate, expiryDate, usedDate, soldTo, profit, note, createdAt
    }

    init() {}

    /// 全部字段 decodeIfPresent：加字段 / 读老数据都不会失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Coupon()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? d.amount
        acquiredDate = try c.decodeIfPresent(Date.self, forKey: .acquiredDate) ?? d.acquiredDate
        expiryDate = try c.decodeIfPresent(Date.self, forKey: .expiryDate) ?? d.expiryDate
        usedDate = try c.decodeIfPresent(Date.self, forKey: .usedDate)
        soldTo = try c.decodeIfPresent(String.self, forKey: .soldTo) ?? d.soldTo
        profit = try c.decodeIfPresent(Double.self, forKey: .profit)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
    }

    // MARK: 状态

    var isUsed: Bool { usedDate != nil }

    /// 距离过期还有多少秒（负数 = 已经过期）
    var secondsLeft: TimeInterval { expiryDate.timeIntervalSinceNow }

    /// 还没用、还没过期，但只剩 3 天不到了
    var isExpiringSoon: Bool { !isUsed && secondsLeft > 0 && secondsLeft <= CouponScheduler.remindLead }

    var isExpired: Bool { !isUsed && secondsLeft <= 0 }

    /// 剩余天数（按自然日算：今天过期 = 0，已经不剩 = 0）
    var daysLeft: Int {
        guard secondsLeft > 0 else { return 0 }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: expiryDate)
        return max(0, cal.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    /// 列表右侧那个小徽标
    var statusText: String {
        if isUsed { return "已用" }
        if isExpired { return "已过期" }
        if daysLeft == 0 { return "今天过期" }
        if isExpiringSoon { return "还剩 \(daysLeft) 天" }
        return "\(fmt(expiryDate, "M/d")) 过期"
    }

    /// 提醒时刻：过期前 3 天的上午 9:00（按自然日算，不跟着运行时刻漂）
    var remindDate: Date { CouponScheduler.at9(of: daysBeforeExpiry(3)) }

    /// 兜底提醒时刻：过期当天上午 9:00
    var expireDayRemindDate: Date { CouponScheduler.at9(of: expiryDate) }

    private func daysBeforeExpiry(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: expiryDate)
            ?? expiryDate.addingTimeInterval(Double(-n) * 86400)
    }
}

/// 金额文案：整数不带小数（¥100），有零头才保留两位（¥99.50）
func moneyText(_ v: Double) -> String {
    if abs(v.rounded() - v) < 0.005 { return "¥\(Int(v.rounded()))" }
    return String(format: "¥%.2f", v)
}

// MARK: - 优惠券仓库

final class CouponStore: ObservableObject {
    static let shared = CouponStore()

    @Published var coupons: [Coupon] = []

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("cuiban_coupons.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Coupon].self, from: data) else { return }
        coupons = list
    }

    private func save() {
        let snapshot = coupons
        DispatchQueue.global(qos: .utility).async {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let d = try? enc.encode(snapshot) { try? d.write(to: self.file) }
        }
        // 通知排程跟着数据走：新增 / 改过期时间 / 标记已用 / 删除都要重排
        CouponScheduler.rescheduleAll(coupons: snapshot)
        DispatchQueue.main.async {
            // 数据变化 → 云同步（内部有节流）+ 顺手看看要不要落一份自动备份
            NotificationCenter.default.post(name: .cuibanDataChanged, object: nil)
            BackupStore.autoBackupIfNeeded(tasks: TaskStore.shared.tasks,
                                           settings: TaskStore.shared.settings)
        }
    }

    /// App 启动 / 回到前台时兜底重排一次（通知可能被系统清过）
    func reschedule() {
        CouponScheduler.rescheduleAll(coupons: coupons)
    }

    // MARK: 查询

    /// 还没用、也还没过期的（按过期时间升序，最急的在前）
    var active: [Coupon] {
        coupons.filter { !$0.isUsed && !$0.isExpired }
            .sorted { $0.expiryDate < $1.expiryDate }
    }

    /// 已用 / 已过期的（按用掉或过期的时间倒序）
    var archived: [Coupon] {
        coupons.filter { $0.isUsed || $0.isExpired }
            .sorted { ($0.usedDate ?? $0.expiryDate) > ($1.usedDate ?? $1.expiryDate) }
    }

    /// 3 天内要到期的
    var expiring: [Coupon] { coupons.filter { $0.isExpiringSoon } }

    /// 待用券的面额合计
    var activeFaceValue: Double { active.reduce(0) { $0 + $1.amount } }

    /// 已经出手的利润合计
    var profitTotal: Double { coupons.compactMap { $0.profit }.reduce(0, +) }

    func coupon(id: String?) -> Coupon? {
        guard let id = id else { return nil }
        return coupons.first { $0.id == id }
    }

    // MARK: 修改

    func upsert(_ c: Coupon) {
        if let i = coupons.firstIndex(where: { $0.id == c.id }) {
            coupons[i] = c
        } else {
            coupons.append(c)
        }
        save()
    }

    func delete(ids: [String]) {
        coupons.removeAll { ids.contains($0.id) }
        save()
    }

    /// 标记已用（通知上的「标记已用」按钮也走这里）
    func markUsed(id: String?, at date: Date = Date()) {
        guard let id = id, let i = coupons.firstIndex(where: { $0.id == id }) else { return }
        guard coupons[i].usedDate == nil else { return }
        coupons[i].usedDate = date
        save()
    }

    func unmarkUsed(id: String) {
        guard let i = coupons.firstIndex(where: { $0.id == id }) else { return }
        coupons[i].usedDate = nil
        save()
    }

    /// 备份 / 同步恢复：整体替换
    func replaceAll(_ list: [Coupon]) {
        coupons = list
        save()
    }
}

// MARK: - 过期提醒

/// 优惠券的本地通知：**过期前 3 天**上午 9:00 一条，过期当天上午 9:00 再补一条。
///
/// 和任务通知是两套前缀（任务 `cb.`、券 `cp.`），各排各的、互不清扫对方的队列。
/// 券的触发时刻是死的（不会像任务那样每分钟重排），所以只在数据变动、
/// 启动、回前台时排一次就够。
enum CouponScheduler {

    static let categoryId = "CUIBAN_COUPON"
    static let actionUsed = "CUIBAN_COUPON_USED"
    static let idPrefix = "cp."
    /// 提前提醒的时长：3 天
    static let remindLead: TimeInterval = 3 * 86400

    private static let queue = DispatchQueue(label: "cuiban.coupon", qos: .utility)

    static func rescheduleAll(coupons: [Coupon]) {
        let snapshot = coupons
        // 声音开关在主线程读一次带进去：后台队列不去碰 TaskStore
        let sound = TaskStore.shared.settings.soundEnabled
        queue.async { perform(snapshot, sound: sound) }
    }

    private static func perform(_ coupons: [Coupon], sound: Bool) {
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { pending in
            let mine = pending.map { $0.identifier }.filter { $0.hasPrefix(idPrefix) }
            if !mine.isEmpty {
                c.removePendingNotificationRequests(withIdentifiers: mine)
            }

            let now = Date()
            for cp in coupons where !cp.isUsed && cp.expiryDate > now {
                for slot in slots(for: cp, now: now) {
                    let content = UNMutableNotificationContent()
                    content.title = "🎟️ " + (cp.name.isEmpty ? "优惠券" : cp.name)
                    content.body = slot.body
                    content.categoryIdentifier = categoryId
                    content.threadIdentifier = cp.id
                    content.userInfo = ["couponId": cp.id]
                    if sound {
                        content.sound = NotificationScheduler.soundName()
                    }
                    if #available(iOS 15.0, *) {
                        content.interruptionLevel = .timeSensitive
                    }
                    let comps = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: slot.fire
                    )
                    c.add(UNNotificationRequest(
                        identifier: "\(idPrefix)\(cp.id).\(slot.suffix)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    ))
                }
            }
        }
    }

    private struct Slot {
        let suffix: String
        let fire: Date
        let body: String
    }

    private static func slots(for cp: Coupon, now: Date) -> [Slot] {
        let money = moneyText(cp.amount)
        let expiry = fmt(cp.expiryDate, "M月d日 HH:mm")
        var out: [Slot] = []

        // ① 过期前 3 天
        let d3 = cp.remindDate
        if d3 > now.addingTimeInterval(30) {
            out.append(Slot(suffix: "d3", fire: d3,
                            body: "3 天后过期（\(expiry)）· 面额 \(money)，别忘了用。"))
        } else if cp.secondsLeft > 0 {
            // 添加时就已经在 3 天内了：别漏掉，10 秒后立刻补一条
            let left = cp.daysLeft <= 0
                ? "今天就过期了"
                : "还剩 \(cp.daysLeft) 天就过期了"
            out.append(Slot(suffix: "d3", fire: now.addingTimeInterval(10),
                            body: "\(left)（\(expiry)）· 面额 \(money)，别忘了用。"))
        }

        // ② 过期当天
        let d0 = cp.expireDayRemindDate
        if d0 > now.addingTimeInterval(30) {
            out.append(Slot(suffix: "d0", fire: d0,
                            body: "今天过期（到 \(fmt(cp.expiryDate, "HH:mm"))）· 面额 \(money)，再不用就作废了。"))
        }
        return out
    }

    /// 取某个日期当天上午 9:00
    static func at9(of date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = 9
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? date
    }
}

// MARK: - 优惠券页

struct CouponsView: View {
    @EnvironmentObject var store: CouponStore
    @State private var showingAdd = false
    @State private var editing: Coupon? = nil

    var body: some View {
        let active = store.active
        let archived = store.archived

        return NavigationView {
            List {
                Section {
                    summary
                }

                Section {
                    if active.isEmpty {
                        emptyHint
                    } else {
                        ForEach(active) { c in row(c) }
                    }
                } header: {
                    Label("待使用 · \(active.count)", systemImage: "ticket")
                }

                if !archived.isEmpty {
                    Section {
                        ForEach(archived) { c in row(c) }
                    } header: {
                        Text("已用 / 已过期")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("优惠券")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                FabButton { showingAdd = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .sheet(isPresented: $showingAdd) {
                CouponEditView()
            }
            .sheet(item: $editing) { c in
                CouponEditView(editing: c)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 顶部合计

    private var summary: some View {
        HStack(spacing: 0) {
            stat("待用", "\(store.active.count) 张")
            Divider().frame(height: 26)
            stat("面额合计", moneyText(store.activeFaceValue))
            Divider().frame(height: 26)
            stat("已出利润", moneyText(store.profitTotal), tint: Color(red: 0.85, green: 0.20, blue: 0.16))
        }
        .listRowBackground(Color.clear)
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
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
            Image(systemName: "ticket")
                .font(.app(34))
                .foregroundColor(.secondary)
            Text("还没有优惠券").font(.app(15, weight: .medium))
            Text("点右下角 + 记一张，过期前 3 天会提醒你")
                .font(.app(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: 一行券

    @ViewBuilder
    private func row(_ c: Coupon) -> some View {
        Button {
            editing = c
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(c))
                    .font(.app(20))
                    .foregroundColor(tint(c))
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.name.isEmpty ? "（未命名券）" : c.name)
                            .font(.app(16, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(moneyText(c.amount))
                            .font(.app(13, weight: .semibold))
                            .foregroundColor(brandColor)
                    }
                    Text(subtitle(c))
                        .font(.app(12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(c.statusText)
                    .font(.app(11, weight: .semibold))
                    .foregroundColor(tint(c))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tint(c).opacity(0.14)))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(ids: [c.id])
            } label: {
                Label("删除", systemImage: "trash")
            }
            if c.isUsed {
                Button {
                    store.unmarkUsed(id: c.id)
                } label: {
                    Label("撤销已用", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            } else {
                Button {
                    store.markUsed(id: c.id)
                } label: {
                    Label("标记已用", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
    }

    private func icon(_ c: Coupon) -> String {
        if c.isUsed { return "checkmark.seal.fill" }
        if c.isExpired { return "xmark.seal.fill" }
        if c.isExpiringSoon { return "exclamationmark.triangle.fill" }
        return "ticket.fill"
    }

    private func tint(_ c: Coupon) -> Color {
        if c.isUsed { return Color(red: 0.05, green: 0.43, blue: 0.34) }
        if c.isExpired { return .secondary }
        if c.daysLeft == 0 { return alarmRed }
        if c.isExpiringSoon { return .orange }
        return brandColor
    }

    private func subtitle(_ c: Coupon) -> String {
        var parts = ["过期 \(fmt(c.expiryDate, "M月d日 HH:mm"))"]
        if !c.isUsed { parts.append("领于 \(fmt(c.acquiredDate, "M/d"))") }
        if let u = c.usedDate { parts.append("用了 \(fmt(u, "M/d"))") }
        if !c.soldTo.isEmpty { parts.append("卖给 \(c.soldTo)") }
        if let p = c.profit { parts.append("利润 \(moneyText(p))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 新增 / 编辑

struct CouponEditView: View {
    @EnvironmentObject var store: CouponStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Coupon
    @State private var hasUsed: Bool
    @State private var hasProfit: Bool
    private let isNew: Bool

    init(editing: Coupon? = nil) {
        var d = editing ?? Coupon()
        if editing == nil {
            // 新券默认按「7 天后过期」起，大多数券都是这个量级
            d.expiryDate = CouponScheduler.at9(of: Date().addingTimeInterval(7 * 86400))
        }
        _draft = State(initialValue: d)
        _hasUsed = State(initialValue: d.usedDate != nil)
        _hasProfit = State(initialValue: d.profit != nil)
        isNew = editing == nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("券")) {
                    TextField("券的名字（例：中石化加油券）", text: $draft.name)
                    HStack {
                        Text("金额")
                        Spacer()
                        TextField("0", value: $draft.amount, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 130)
                        Text("元").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("时间")) {
                    DatePicker("领取时间", selection: $draft.acquiredDate,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("过期时间", selection: $draft.expiryDate,
                               displayedComponents: [.date, .hourAndMinute])
                    Toggle("已使用", isOn: $hasUsed.animation())
                    if hasUsed {
                        DatePicker("使用时间", selection: usedBinding,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section(header: Text("出手"),
                        footer: Text("过期前 3 天上午 9 点会提醒一次，过期当天再提醒一次。")) {
                    TextField("卖给谁（选填）", text: $draft.soldTo)
                    Toggle("记一笔利润", isOn: $hasProfit.animation())
                    if hasProfit {
                        HStack {
                            Text("出的利润")
                            Spacer()
                            TextField("0", value: profitBinding, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 130)
                            Text("元").foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("备注")) {
                    TextField("备注（选填）", text: $draft.note, axis: .vertical)
                        .lineLimit(1...4)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            store.delete(ids: [draft.id])
                            dismiss()
                        } label: {
                            Text("删除这张券")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增优惠券" : "编辑优惠券")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: hasUsed) { on in
                if on { if draft.usedDate == nil { draft.usedDate = Date() } }
                else { draft.usedDate = nil }
            }
            .onChange(of: hasProfit) { on in
                if on { if draft.profit == nil { draft.profit = 0 } }
                else { draft.profit = nil }
            }
        }
    }

    private var usedBinding: Binding<Date> {
        Binding(get: { draft.usedDate ?? Date() },
                set: { draft.usedDate = $0 })
    }

    private var profitBinding: Binding<Double> {
        Binding(get: { draft.profit ?? 0 },
                set: { draft.profit = $0 })
    }

    private func save() {
        var c = draft
        c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.amount < 0 { c.amount = 0 }
        if !hasUsed { c.usedDate = nil }
        if !hasProfit { c.profit = nil }
        if let p = c.profit, p < 0 { c.profit = 0 }
        store.upsert(c)
        dismiss()
    }
}
