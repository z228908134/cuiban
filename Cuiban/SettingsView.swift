import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject private var ai = AIStore.shared

    @State private var aiTesting = false
    @State private var aiTestResult: String? = nil
    @State private var photoCount = 0
    @State private var photoSizeText = "0 B"
    @State private var photoNotice: String? = nil

    // MARK: 备份状态

    @State private var backupList: [BackupEntry] = []
    @State private var backupNotice: String? = nil
    @State private var exportItem: ExportItem? = nil
    @State private var importOpen = false
    @State private var restorePayload: BackupPayload? = nil
    @State private var restoreSource = ""

    struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private let intervals = [1, 2, 3, 5, 10, 15, 20, 30, 60]

    var body: some View {
        NavigationView {
            Form {
                // MARK: 外观

                Section(header: Text("外观"),
                        footer: Text("深色模式下所有页面都会跟着变暗；催促页固定红底白字，不受影响。")) {
                    Picker("主题", selection: themeBinding) {
                        ForEach(ThemeMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
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
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        TextField("接口地址", text: $ai.baseURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .font(.system(size: 14))

                        TextField("模型名", text: $ai.model)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: 14))

                        SecureField("API Key", text: $ai.apiKey)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: 14))

                        Button(aiTesting ? "测试中…" : "测试一下配置") {
                            runAITest()
                        }
                        .disabled(!ai.ready || aiTesting)

                        if let r = aiTestResult {
                            Text(r)
                                .font(.system(size: 12))
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
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: 备份与恢复

                Section(header: Text("备份与恢复"),
                        footer: Text("自动备份保存在 App 本机，最多留 10 份。「备份到 iCloud」走系统文件面板：在弹出的面板里选「iCloud 云盘」下的目录，备份文件就会真的存进 iCloud，换手机也能从「文件」App 拿回来。")) {
                    Toggle("自动备份（数据一变就存）", isOn: autoBackupBinding)
                    Toggle("备份里包含照片", isOn: backupPhotosBinding)

                    HStack {
                        Text("本地备份")
                        Spacer()
                        Text(backupSummaryText)
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }

                    Button("立即备份一份") { doBackupNow() }

                    Button("备份到 iCloud 云盘 / 文件…") { prepareExport() }

                    Button("从文件恢复…") { importOpen = true }

                    if !backupList.isEmpty {
                        Menu {
                            ForEach(backupList.prefix(10)) { b in
                                Button(b.title) { restoreFromLocal(b) }
                            }
                        } label: {
                            HStack {
                                Text("从本地备份恢复…")
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if let n = backupNotice {
                        Text(n)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

                Section(header: Text("怎么用"), footer: Text("催办 v1.3.0 · 为 TrollStore 打造的免签名原生应用")) {
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
            .sheet(item: $exportItem) { item in
                ExportFilesSheet(urls: [item.url]) {
                    BackupStore.lastExportAt = Date()
                    backupNotice = "已保存到你选的位置（放进 iCloud 云盘的会自动同步）"
                }
            }
            .alert(isPresented: Binding(
                get: { restorePayload != nil },
                set: { if !$0 { restorePayload = nil } }
            )) {
                Alert(
                    title: Text("确认恢复？"),
                    message: Text(restoreConfirmText),
                    primaryButton: .destructive(Text("覆盖恢复")) { performRestore() },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $importOpen) {
            ImportFileSheet { url in handleImport(url) }
        }
        .onAppear {
            store.refreshAuth()
            refreshPhotoStats()
            refreshBackupStats()
        }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            store.refreshPendingCount()
        }
    }

    // MARK: 备份相关

    private var backupSummaryText: String {
        if backupList.isEmpty { return "暂无" }
        return "\(backupList.count) 份 · 最近 " + fmt(backupList[0].date, "MM-dd HH:mm")
    }

    private var restoreConfirmText: String {
        guard let p = restorePayload else { return "" }
        var s = "将用「\(restoreSource)」覆盖当前的所有任务和设置（含 \(p.tasks.count) 个任务）。"
        if p.photos.isEmpty && p.tasks.contains(where: { !$0.photos.isEmpty }) {
            s += "\n注意：这份备份里没有照片数据，恢复后任务的图片会缺失。"
        }
        return s
    }

    private func refreshBackupStats() {
        backupList = BackupStore.listBackups()
    }

    private func doBackupNow() {
        let tasks = store.tasks
        let settings = store.settings
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = BackupStore.writeBackup(tasks: tasks, settings: settings, tag: "手动") != nil
            DispatchQueue.main.async {
                backupNotice = ok ? "已备份一份（本机）" : "备份失败，重试一次看看"
                refreshBackupStats()
            }
        }
    }

    private func prepareExport() {
        let tasks = store.tasks
        let settings = store.settings
        DispatchQueue.global(qos: .userInitiated).async {
            let url = BackupStore.makeExportFile(tasks: tasks, settings: settings)
            DispatchQueue.main.async {
                if let u = url {
                    exportItem = ExportItem(url: u)
                } else {
                    backupNotice = "备份文件生成失败"
                }
            }
        }
    }

    private func restoreFromLocal(_ entry: BackupEntry) {
        guard let p = BackupStore.readPayload(at: entry.url) else {
            backupNotice = "这份备份读不出来，可能文件损坏了"
            return
        }
        restoreSource = entry.title
        restorePayload = p
    }

    private func handleImport(_ url: URL) {
        guard let p = BackupStore.readPayload(at: url) else {
            backupNotice = "这个文件读不出来，确认是「催办」导出的备份（.json）"
            return
        }
        restoreSource = url.lastPathComponent
        restorePayload = p
    }

    private func performRestore() {
        guard let p = restorePayload else { return }
        restorePayload = nil
        backupNotice = BackupStore.restore(payload: p)
        refreshBackupStats()
        refreshPhotoStats()
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
            "关闭后改用系统预排通知（受系统 64 条上限约束），更省电，App 被杀掉也能照响。"
        )
    }

    private func tip(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundColor(.secondary)
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(
            get: { store.settings.theme },
            set: { v in
                var s = store.settings
                s.theme = v
                store.updateSettingsPublic(s)
            }
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

    private func settingsBoolBinding(_ kp: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: kp] },
            set: { v in
                var s = store.settings
                s[keyPath: kp] = v
                store.updateSettingsPublic(s)
            }
        )
    }

    private var autoBackupBinding: Binding<Bool> {
        settingsBoolBinding(\.autoBackup)
    }

    private var backupPhotosBinding: Binding<Bool> {
        settingsBoolBinding(\.backupIncludePhotos)
    }

    private var keepAliveBinding: Binding<Bool> {        Binding(
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
}
