import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var ai = AIStore.shared
    @ObservedObject private var fontScale = FontScale.shared

    /// 外观与字体页的摘要（主题 + 字号档位）
    private var appearanceSummary: String {
        "\(store.settings.theme.label) · \(fontScale.currentPresetLabel)"
    }

    /// 版本号从 Info.plist 动态读取，升级后自动跟随
    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    @State private var aiTesting = false
    @State private var aiTestResult: String? = nil
    @State private var photoCount = 0
    @State private var photoSizeText = "0 B"
    @State private var photoNotice: String? = nil
    /// 「备份与同步」入口右侧摘要用的两个值。后台算好再填进 body，
    /// 千万别在 body 里现算（listBackups / currentConfig 都是 IO）
    @State private var backupCount = 0
    @State private var cloudSummary = CloudSync.currentConfig
    /// App 回到前台时刷新一次摘要（同步可能在后台改过状态）
    @State private var wasBackgrounded = false

private let intervals = [1, 2, 3, 5, 10, 15, 20, 30, 60]

    var body: some View {
        NavigationView {
            Form {
                // MARK: 外观与字体

                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        HStack {
                            Label("外观与字体", systemImage: "textformat.size")
                            Spacer()
                            Text(appearanceSummary)
                                .font(.app(13))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: 卡片备份

                Section(header: Text("卡片备份"),
                        footer: Text("银行卡、信用卡的卡号和图片都只存在这台手机上，不会上传到任何服务器。图片和任务里的照片放在一起，删卡片会连图片一起删。")) {
                    NavigationLink {
                        CardListView()
                    } label: {
                        HStack {
                            Label("卡片备份", systemImage: "creditcard")
                            Spacer()
                            Text("\(CardStore.shared.cards.count) 张")
                                .font(.app(13))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: 通知权限

                Section(header: Text("通知权限"), footer: Text("必须允许通知，催促才能在 App 之外响起来。")) {
                    HStack {
                        Text("状态")
                        Spacer()
                        if store.authStatus == .authorized {
                            Text(store.authText).foregroundColor(.green)
                        } else {
                            Text(store.authText).foregroundColor(.red)
                        }
                    }
                    if store.authStatus != .authorized {
                        Button("允许催办发通知") {
                            store.requestAuth()
                        }
                    }
                    Button("测试一下（5 秒后响）") {
                        NotificationScheduler.testFire(in: 5)
                    }
                }

                // MARK: 催促力度

                Section(header: Text("催促力度"), footer: Text("未点「完成」的任务会一直按这个间隔催下去。")) {
                    Picker("默认提醒间隔", selection: intervalBinding) {
                        ForEach(intervals, id: \.self) { m in
                            Text("每 \(m) 分钟").tag(m)
                        }
                    }
                    Picker("点「延后」默认延后", selection: snoozeBinding) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                            Text("\(m) 分钟").tag(m)
                        }
                    }
                    Toggle("提示音", isOn: soundBinding)
                }

                // MARK: 优惠券提醒

                Section(header: Text("优惠券提醒"), footer: Text("从过期前这么多天开始，每天上午 9 点、晚上 8 点各提醒一次，一直到过期当天。")) {
                    Stepper(value: couponDaysBinding, in: CouponScheduler.leadRange) {
                        HStack {
                            Text("过期前开始提醒")
                            Spacer()
                            Text("\(store.settings.couponRemindDays) 天")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: 后台常驻

                Section(header: Text("后台常驻"), footer: keepAliveFooter) {
                    Toggle("后台常驻（推荐）", isOn: keepAliveBinding)
                    HStack {
                        Text("待发通知数量")
                        Spacer()
                        Text("\(pendingCount) / 64")
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: AI 智能解析（可选增强）

                Section(header: Text("AI 智能解析（可选）"),
                        footer: Text("不填也能用：打一句话或选张图，本机就能识别出时间和重复规则。填上之后，识别完会让 AI 再复核一遍，遇到绕口的说法会更准。Key 只存在这台手机上。")) {
                    Toggle("开启 AI 复核", isOn: $ai.enabled)

                    if ai.enabled {
                        Picker("服务商", selection: providerBinding) {
                            ForEach(AIProvider.all) { p in
                                Text(p.name).tag(p.id)
                            }
                        }

                        if let p = AIProvider.all.first(where: { $0.id == ai.providerId }), !p.applyHint.isEmpty {
                            Text(p.applyHint)
                                .font(.app(12))
                                .foregroundColor(.secondary)
                        }

                        TextField("接口地址", text: $ai.baseURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .font(.app(14))

                        TextField("模型名", text: $ai.model)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.app(14))

                        SecureField("API Key", text: $ai.apiKey)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.app(14))

                        Button(aiTesting ? "测试中…" : "测试一下配置") {
                            runAITest()
                        }
                        .disabled(!ai.ready || aiTesting)

                        if let r = aiTestResult {
                            Text(r)
                                .font(.app(12))
                                .foregroundColor(r.hasPrefix("可用") ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // MARK: 照片存储

                Section(header: Text("照片"),
                        footer: Text("任务里的照片存在本机（Documents/attachments），不会上传。删掉任务会连照片一起删。")) {
                    HStack {
                        Text("已存照片")
                        Spacer()
                        Text("\(photoCount) 张 · \(photoSizeText)")
                            .foregroundColor(.secondary)
                    }
                    Button("清理没用的照片") {
                        let n = store.vacuumPhotos()
                        photoNotice = n == 0 ? "没有需要清理的照片" : "已清理 \(n) 张没用的照片"
                        refreshPhotoStats()
                    }
                    .foregroundColor(.orange)
                    if let n = photoNotice {
                        Text(n)
                            .font(.app(12))
                            .foregroundColor(.secondary)
                    }
                }

// 备份与同步挪到二级页了，这里只留一个入口（和「外观与字体」同一套路）

        Section {
         NavigationLink {
          BackupSyncSettingsView()
            } label: {
    HStack {
          Label("备份与同步", systemImage: "externaldrive")
      Spacer()
      // **不能在这里调 listBackups()**：SwiftUI 每次重绘都会求值 body，
      // 而 listBackups() 是一次目录列举 + N 次 stat，备份多的话更贵。
      // 用 @State 缓存，onAppear 时后台算一次。
        Text(BackupStore.settingsSummary(
      cloudConfig: cloudSummary,
   backupCount: backupCount))
   .font(.app(13))
   .foregroundColor(.secondary)
     }
      }
        }

                // MARK: 数据

                Section(header: Text("数据")) {
                    Button("清空已完成") {
                        store.clearFinished()
                    }
                    .foregroundColor(.orange)

                    Button("清空全部任务", role: .destructive) {
                        store.clearAll()
                    }
                    .foregroundColor(.red)
                }

                Section(header: Text("怎么用"), footer: Text("催办 v\(Self.appVersion) · 为 TrollStore 打造的免签名原生应用")) {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("1. 新建任务：打一句话（明天下午 3 点开会），或选一张截图、拍张照")
                        tip("2. 识别出的时间和重复规则会自动填好，结论写进备注")
                        tip("3. 照片会存进任务里，清单、日历、催促页都能看到")
                        tip("4. 首次打开时允许通知权限")
                        tip("5. 到点不完成就一直催，直到你点「完成」")
                        tip("6. 「日历」页能看整月安排，重复任务会往后推算")
                        tip("7. 打开「后台常驻」后 App 会留在后台精确计时")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("设置")
.navigationBarTitleDisplayMode(.inline)
        .onAppear {
store.refreshAuth()
                refreshPhotoStats()
        refreshBackupSummary()
        startPendingTimer()
            }
  .onChange(of: scenePhase) { p in
                // TabView 会保留所有 tab，onAppear 只触发一次。
      // 用户在别的页面改完备份设置回来时，这里重新算一次摘要
      if p == .active && wasBackgrounded {
refreshBackupSummary()
   startPendingTimer()
      } else if p != .active {
     pendingTimer?.cancel()
              pendingTimer = nil
     }
        wasBackgrounded = (p != .active)
     }
  }
        .navigationViewStyle(.stack)
    }

  /// 通知权限的待提醒数：只在设置页可见 + App 在前台时才开定时器。
    /// 原来挂在 NavigationView 外层的 Timer.publish 是 TabView 常驻的，
    /// 用户停在清单页也在每 4 秒发一次跨进程请求，顺带把整个 body 拖着重算。
    @State private var pendingTimer: AnyCancellable? = nil

    private func startPendingTimer() {
        pendingTimer?.cancel()
        pendingTimer = Timer.publish(every: 4, on: .main, in: .common)
            .autoconnect()
            .sink { _ in store.refreshPendingCount() }
    }

    /// 后台算好「本地几份备份 + 同步配置」再回主线程填 @State
    private func refreshBackupSummary() {
        DispatchQueue.global(qos: .utility).async {
let n = BackupStore.listBackups().count
  let c = CloudSync.currentConfig
      DispatchQueue.main.async {
    backupCount = n
    cloudSummary = c
        }
        }
    }

    // MARK: 小工具与绑定

    /// 「怎么用」那几行说明文字
    private func tip(_ s: String) -> some View {
        Text(s).font(.app(13)).foregroundColor(.secondary)
    }

    private func refreshPhotoStats() {
        photoCount = AttachmentStore.fileCount
        photoSizeText = AttachmentStore.sizeText
    }

    private var pendingCount: Int {
        store.pendingNotificationCount
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { ai.providerId },
            set: { id in
                if let p = AIProvider.all.first(where: { $0.id == id }) {
                    ai.applyPreset(p)
                } else {
                    ai.providerId = id
                }
                aiTestResult = nil
            }
        )
    }

    private func runAITest() {
        aiTesting = true
        aiTestResult = nil
        AIService.test { res in
            DispatchQueue.main.async {
                aiTesting = false
                switch res {
                case .success(let s):
                    aiTestResult = "可用 ✓ " + s
                case .failure(let e):
                    aiTestResult = "失败：" + e.localizedDescription
                }
            }
        }
    }

    private var keepAliveFooter: some View {
        Text(
            "开启后 App 会在后台保持运行并按秒精确计时，催促无限延续；代价是略微耗电。" +
            "关闭后改用系统预排通知（受系统 64 条上限约束），更省电，App 被杀掉也能照响。\n\n" +
            "任务多时这 60 条配额会自动按紧急程度分配：越急的任务排得越密（最多 12 条），" +
            "不急的至少留 1 条占位；任务数超过 60 个时优先保最临近截止的那些，其余等腾出配额后自动补上。"
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { store.settings.defaultIntervalMinutes },
            set: { v in
                var s = store.settings
                s.defaultIntervalMinutes = v
                store.updateSettingsPublic(s)
            }
        )
    }

    private var snoozeBinding: Binding<Int> {
        Binding(
            get: { store.settings.snoozeMinutes },
            set: { v in
                var s = store.settings
                s.snoozeMinutes = v
                store.updateSettingsPublic(s)
            }
        )
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { store.settings.soundEnabled },
            set: { v in
                var s = store.settings
                s.soundEnabled = v
                store.updateSettingsPublic(s)
            }
        )
    }

    private var keepAliveBinding: Binding<Bool> {
        Binding(
            get: { store.settings.keepAlive },
            set: { v in
                var s = store.settings
                s.keepAlive = v
                store.updateSettingsPublic(s)
                if v {
                    BackgroundKeeper.shared.start()
                } else {
                    BackgroundKeeper.shared.stop()
                }
            }
        )
    }

    /// 券的「过期前开始提醒」天数。改完立刻重排一次券通知，不用等下次打开。
    private var couponDaysBinding: Binding<Int> {
        Binding(
            get: { store.settings.couponRemindDays },
            set: { v in
                var s = store.settings
                s.couponRemindDays = v
                store.updateSettingsPublic(s)
                CouponScheduler.rescheduleAll(coupons: CouponStore.shared.coupons)
            }
        )
    }
}
