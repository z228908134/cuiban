import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
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

    // MARK: 备份状态

    @State private var backupList: [BackupEntry] = []
    @State private var backupNotice: String? = nil
    @State private var exportItem: ExportItem? = nil
    @State private var importOpen = false
    @State private var restorePayload: BackupPayload? = nil
    @State private var restoreSource = ""

    // MARK: WebDAV 直连 NAS

    @State private var davSheet = false
    @State private var davURL = ""
    @State private var davUser = ""
    @State private var davPass = ""
    @State private var davNotice: String? = nil
    @State private var davTesting = false

    struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

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

// 备份与同步：本地备份 + NAS 同步合并成一个区块（卡片备份就是这么整合的）

        Section(header: Text("备份与同步"),
                footer: Text("本地备份自动存在手机里，最多留 10 份。同步到 NAS 可以直接连飞牛的 WebDAV（填地址就行，不用先在系统文件里连一遍），也可以选 iCloud 云盘这类系统文件夹。Windows 版把数据目录指到同一个位置，两边就实时同步了。数据只在你自己的设备之间传。")) {
        // —— 本地备份 ——

          Toggle("自动备份（数据一变就存）", isOn: autoBackupBinding)
          Toggle("备份里包含照片", isOn: backupPhotosBinding)

       HStack {
   Text("本地备份")
   Spacer()
            Text(backupSummaryText)
           .foregroundColor(.secondary)
         .font(.app(13))
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
     .font(.app(11))
   .foregroundColor(.secondary)
      }
  }
        }

      if let n = backupNotice {
         Text(n)
            .font(.app(12))
    .foregroundColor(.secondary)
             .fixedSize(horizontal: false, vertical: true)
   }

             // —— NAS 同步 ——

    if cloudConfig.isOn {
         HStack {
        Label(cloudConfig.mode == "webdav" ? "飞牛已连接" : "同步已开启",
        systemImage: "checkmark.icloud.fill")
        .foregroundColor(.green)
        Spacer()
      }

        VStack(alignment: .leading, spacing: 3) {
        Text("同步位置")
           .font(.app(13))
                .foregroundColor(.secondary)
        Text(cloudConfig.displayTarget)
  .font(.app(11))
       .foregroundColor(.secondary)
             .lineLimit(2)
   .truncationMode(.head)
    }

            if let at = cloudMeta.lastSyncAt {
        HStack {
     Text("上次同步")
       Spacer()
    Text(fmt(at, "M月d日 HH:mm"))
       .font(.app(13))
              .foregroundColor(.secondary)
                }
            }

            Toggle("数据一变就自动同步", isOn: cloudAutoBinding)

            Toggle("同步时包含照片", isOn: cloudPhotosBinding)

     Button("立即同步") { doCloudSync() }

            Button("用 NAS 上的数据覆盖本机") { confirmPullFromCloud() }

            if let n = cloudNotice {
    Text(n)
        .font(.app(12))
 .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
            }

            Button("停止同步", role: .destructive) {
   cloudConfirmDisable = true
  }
        } else {
        // 没开启时给两个并排入口：飞牛直连 / 系统文件夹
      HStack(spacing: 12) {
 Button {
        davSheet = true
  } label: {
          VStack(spacing: 4) {
        Image(systemName: "server.rack")
        .font(.app(18))
   Text("飞牛 WebDAV").font(.app(12))
       }
            .frame(maxWidth: .infinity)
  }
       .buttonStyle(.bordered)

        Button {
      syncFolderPicker = true
         } label: {
      VStack(spacing: 4) {
      Image(systemName: "folder")
       .font(.app(18))
      Text("系统文件夹").font(.app(12))
            }
      .frame(maxWidth: .infinity)
   }
            .buttonStyle(.bordered)
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
.sheet(isPresented: $syncFolderPicker) {
  FolderPickerSheet { url in
    syncFolderPicker = false
                handleFolderPicked(url)
            }
        }
        .sheet(isPresented: $davSheet) {
            NavigationView {
                Form {
                    Section {
                        TextField("http://192.168.1.10:5005/cuiban-sync", text: $davURL)
                            .font(.app(14))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("用户名", text: $davUser)
                            .font(.app(14))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(CloudSync.webdavPassword.isEmpty ? "密码" : "密码（已保存，留空不改）",
                                    text: $davPass)
                            .font(.app(14))
                    } header: {
                        Text("飞牛 WebDAV")
                    } footer: {
                        Text("飞牛里「设置 → 文件服务 → WebDAV」打开后会给出地址和端口，默认 5005。地址填目录不用带文件名，App 会在下面放 cuiban-data.json。已做过 frp 映射的话把公网地址填进来即可。")
                    }

                    Section {
                        Button(davTesting ? "测试中…" : "测试连接") { testWebDAV() }
                            .disabled(davTesting || davURL.isEmpty)

                        if let n = davNotice {
                            Text(n)
                                .font(.app(12))
                                .foregroundColor(davNotice.hasPrefix("连接成功") ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .navigationTitle("飞牛直连")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") {
                            davSheet = false
                            davNotice = nil
                            davPass = ""
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("保存并同步") { saveWebDAV() }
                            .disabled(davURL.isEmpty)
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .alert("用 NAS 上的数据覆盖本机？", isPresented: $cloudConfirmPull) {
            Button("覆盖", role: .destructive) { doPullFromCloud() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机现有的 \(store.tasks.count) 个任务会被 NAS 上的数据替换。已经先在本地存了一份备份，出问题可以从「本地备份恢复」里退回来。")
        }
        .alert("停止同步？", isPresented: $cloudConfirmDisable) {
            Button("停止", role: .destructive) {
                CloudSync.disable()
                cloudConfig = CloudSync.currentConfig
                cloudNotice = "已停止同步，本机数据不受影响"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是不再往 NAS 写数据，本机数据不受影响。")
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

    // MARK: 同步状态

    @State private var cloudConfig = CloudSync.currentConfig
    @State private var cloudMeta = CloudSync.currentMeta
    @State private var cloudNotice: String? = nil
    @State private var syncFolderPicker = false
    @State private var cloudConfirmDisable = false
    @State private var cloudConfirmPull = false

private var cloudAutoBinding: Binding<Bool> {
        Binding(
            get: { cloudConfig.autoSync },
        set: { v in
           cloudConfig.autoSync = v
        if cloudConfig.mode == "webdav" {
    CloudSync.configureWebDAV(url: cloudConfig.webdavURL,
          user: cloudConfig.webdavUser,
        password: CloudSync.webdavPassword,
           includePhotos: cloudConfig.includePhotos,
     autoSync: v)
    } else {
        CloudSync.configure(folder: cloudConfig.folder,
            includePhotos: cloudConfig.includePhotos,
      autoSync: v)
       }
  })
    }

    private var cloudPhotosBinding: Binding<Bool> {
Binding(
  get: { cloudConfig.includePhotos },
            set: { v in
      cloudConfig.includePhotos = v
 if cloudConfig.mode == "webdav" {
             CloudSync.configureWebDAV(url: cloudConfig.webdavURL,
              user: cloudConfig.webdavUser,
  password: CloudSync.webdavPassword,
          includePhotos: v,
         autoSync: cloudConfig.autoSync)
          } else {
CloudSync.configure(folder: cloudConfig.folder,
           includePhotos: v,
    autoSync: cloudConfig.autoSync)
       }
          _ = CloudSync.syncNow()
      cloudMeta = CloudSync.currentMeta
       })
    }

    private func doCloudSync() {
        let msg = CloudSync.syncAndReport()
        cloudMeta = CloudSync.currentMeta
  cloudNotice = msg
    }

    /// 用 NAS 上的数据覆盖本机（先自动备份一份，避免误操作丢数据）
    private func confirmPullFromCloud() {
        guard cloudConfig.isOn else { return }
        guard CloudSync.remoteFileExists() else {
       cloudNotice = "NAS 上还没有数据，先在另一端上传一次"
            return
        }
        cloudConfirmPull = true
    }

    private func doPullFromCloud() {
        // 覆盖前先在本地存一份，出问题能退回来
        BackupStore.autoBackupIfNeeded(tasks: store.tasks, settings: store.settings)
        let r = CloudSync.pullOnly()
        cloudNotice = r.text
        cloudMeta = CloudSync.currentMeta
    }

    /// 选好文件夹后：先确认能不能写，再开启同步
    private func handleFolderPicked(_ url: URL) {
        let path = url.path
        guard CloudSync.isFolderWritable(path) else {
            cloudNotice = "这个文件夹读不到（可能没连上 NAS，或没有写入权限）"
     return
        }
        CloudSync.configure(folder: path,
          includePhotos: cloudConfig.includePhotos,
                            autoSync: cloudConfig.autoSync)
        cloudConfig = CloudSync.currentConfig
        // 立刻同步一次：远端有数据就拉下来，没有就把本机推上去
        cloudNotice = CloudSync.syncAndReport()
 cloudMeta = CloudSync.currentMeta
    }

    // MARK: WebDAV（飞牛直连）

    /// 测试连接：拿当前输入拼个临时客户端探一下
    private func testWebDAV() {
        davTesting = true
 davNotice = nil
        let url = davURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = davPass.isEmpty ? CloudSync.webdavPassword : davPass
        DispatchQueue.global(qos: .userInitiated).async {
       let cli = WebDAVClient(baseURL: url, user: davUser, password: pass)
  let msg = cli.test()
       DispatchQueue.main.async {
    davTesting = false
       davNotice = msg
        }
        }
    }

    /// 保存并立刻同步一次
    private func saveWebDAV() {
        let url = davURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            davNotice = "先填 NAS 地址"
       return
        }
        let pass = davPass.isEmpty ? CloudSync.webdavPassword : davPass
 CloudSync.configureWebDAV(url: url,
   user: davUser,
     password: pass,
    includePhotos: cloudConfig.includePhotos,
    autoSync: true)
        cloudConfig = CloudSync.currentConfig
        davSheet = false
        davNotice = nil
    davPass = ""
    cloudNotice = CloudSync.syncAndReport()
        cloudMeta = CloudSync.currentMeta
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
        Text(s).font(.app(13)).foregroundColor(.secondary)
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
