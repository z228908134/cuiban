import SwiftUI

// MARK: - 备份与同步（二级页）
//
// 从设置首页点进来。放二级页有两个原因：
// 1. 首页面已经很长（外观/通知/催促/后台/AI/照片/数据/怎么用），再塞十几个控件很难看；
// 2. 备份和同步是低频操作，绝大多数用户一辈子只配一次，不该占据首屏。
//
// 和「外观与字体」一个套路：首页只留一行入口 + 右边一句摘要
//（本地几份备份 · 同步到哪），点进去才是全部设置。

struct BackupSyncSettingsView: View {
    @EnvironmentObject var store: TaskStore

    // MARK: 本地备份

    @State private var backupList: [BackupEntry] = []
    @State private var backupNotice: String? = nil
    @State private var exportItem: BackupExportItem? = nil
    @State private var importOpen = false
    @State private var restorePayload: BackupPayload? = nil
    @State private var restoreSource = ""

    struct BackupExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    // MARK: NAS 同步

    @State private var cloudConfig = CloudSync.currentConfig
    @State private var cloudMeta = CloudSync.currentMeta
    @State private var cloudNotice: String? = nil
    @State private var syncFolderPicker = false
    /// NAS 上已存的历史备份份数（WebDAV 要 PROPFIND 列目录，异步取）
    @State private var historyCount = 0
    /// 当前要弹的确认框。同一个视图只能挂一个 .alert，用它把三种确认合并
    @State private var pendingAlert: AlertKind? = nil

    enum AlertKind: String, Identifiable {
        case pullFromCloud, disableSync, restoreBackup
        var id: String { rawValue }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { pendingAlert != nil },
            set: { if !$0 { pendingAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch pendingAlert {
        case .pullFromCloud: return "用 NAS 上的数据覆盖本机？"
        case .disableSync: return "停止同步？"
        case .restoreBackup: return "确认恢复？"
        case nil: return ""
        }
    }

    private var alertConfirmTitle: String {
        switch pendingAlert {
        case .pullFromCloud: return "覆盖"
        case .disableSync: return "停止"
        case .restoreBackup: return "覆盖恢复"
        case nil: return "确定"
        }
    }

    private var alertMessage: String {
        switch pendingAlert {
        case .pullFromCloud:
            return "本机现有的 \(store.tasks.count) 个任务会被 NAS 上的数据替换。已经先在本地存了一份备份，出问题可以从「本地备份恢复」里退回来。"
        case .disableSync:
            return "只是不再往 NAS 写数据，本机数据不受影响。"
        case .restoreBackup:
            return restoreConfirmText
        case nil:
            return ""
        }
    }

    var body: some View {
        Form {
            localBackupSection
            cloudSection
        }
        .navigationTitle("备份与同步")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportItem) { item in
            ExportFilesSheet(urls: [item.url]) {
                BackupStore.lastExportAt = Date()
                backupNotice = "已保存到你选的位置（放进 iCloud 云盘的会自动同步）"
            }
        }
        .sheet(isPresented: $importOpen) {
            ImportFileSheet { url in handleImport(url) }
        }
        .sheet(isPresented: $syncFolderPicker) {
            FolderPickerSheet { url in
                syncFolderPicker = false
                handleFolderPicked(url)
            }
        }
// 三种确认弹窗合并成一个：同一视图挂多个 .alert 只有最后一个生效，
        // 前两个会被静默忽略（旧代码就是这样，停止同步的确认框根本不弹）。
        .alert(alertTitle, isPresented: alertBinding) {
            Button(alertConfirmTitle, role: .destructive) { runAlertAction() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
.onAppear {
            refreshBackupStats()
      if cloudConfig.isOn { refreshHistoryCount() }
        }
        // 二级页里改完同步配置（比如刚从「飞牛直连」返回），状态要立刻刷新
        .onReceive(NotificationCenter.default.publisher(for: .cloudConfigChanged)) { _ in
            cloudConfig = CloudSync.currentConfig
            cloudMeta = CloudSync.currentMeta
        if cloudConfig.isOn { refreshHistoryCount() } else { historyCount = 0 }
        }
    }

    // MARK: 本地备份区

    private var localBackupSection: some View {
        Section {
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

            Picker("最多保留", selection: maxBackupsBinding) {
                ForEach([5, 10, 20, 30, 50], id: \.self) { n in
                    Text("\(n) 份").tag(n)
                }
            }
        } header: {
            Text("本地备份")
        } footer: {
            Text("数据存在 App 本机，超出份数自动删最旧的。注意：卸载 App 会一起没掉，保命请靠下面的 NAS 同步或手动导出。")
        }
    }

    // MARK: NAS 同步区

    @ViewBuilder
    private var cloudSection: some View {
        Section {
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

    HStack {
       Text("NAS 上已备份")
   Spacer()
     Text(historyCountText)
        .foregroundColor(.secondary)
      .font(.app(13))
         }

        Toggle("数据一变就自动同步", isOn: cloudAutoBinding)

            Toggle("同步时包含照片", isOn: cloudPhotosBinding)

          Picker("NAS 最多保留", selection: historyKeepBinding) {
   ForEach([5, 10, 20, 30, 50], id: \.self) { n in
       Text("\(n) 份").tag(n)
       }
          }

  Button("立即同步") { doCloudSync() }

                Button("用 NAS 上的数据覆盖本机") { confirmPullFromCloud() }

                if let n = cloudNotice {
                    Text(n)
                        .font(.app(12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("停止同步", role: .destructive) {
                    pendingAlert = .disableSync
                }
            } else {
                NavigationLink {
                    WebDAVSettingsView()
                } label: {
                    Label("连接飞牛（WebDAV）", systemImage: "server.rack")
                }

                Button {
                    syncFolderPicker = true
                } label: {
                    Label("选系统文件夹（iCloud 云盘等）", systemImage: "folder")
                }
            }
        } header: {
            Text("同步到 NAS")
        } footer: {
            Text("飞牛用「连接飞牛」直接填地址即可，不用先在系统文件里连一遍（飞牛 App 没注册文件提供器，系统文件面板里根本选不到）。每次同步除了覆盖 cuiban-data.json，还会另存一份带时间戳的历史备份，超出份数自动删最旧的。Windows 版把数据目录指到同一个位置，两边就实时同步了。数据只在你自己的设备之间传。")
        }
    }

// MARK: NAS 历史备份份数

    /// 远端历史份数。WebDAV 要发 PROPFIND 列目录，是网络请求不能在 body 里同步算，
    /// 由 refreshHistoryCount() 异步更新
    private var historyCountText: String {
        historyCount > 0 ? "\(historyCount) 份" : "暂无"
    }

    private var historyKeepBinding: Binding<Int> {
        Binding(
            get: { CloudSync.historyKeepBindingValue },
            set: { v in
   CloudSync.setHistoryKeep(v)
    refreshHistoryCount()
            })
    }

    /// 列远端目录拿份数。WebDAV 是一次网络请求，放后台并限流：
/// 切换 Picker、点立即同步都会触发，不限流会连着发好几次
    private func refreshHistoryCount() {
        DispatchQueue.global(qos: .utility).async {
            let n = CloudSync.remoteHistoryCount()
            DispatchQueue.main.async { historyCount = n }
        }
    }

    // MARK: 绑定

    private var autoBackupBinding: Binding<Bool> {
        settingsBoolBinding(\.autoBackup)
    }

    private var backupPhotosBinding: Binding<Bool> {
        settingsBoolBinding(\.backupIncludePhotos)
    }

    /// 改保留份数后立刻按新值修剪，不用等下一次自动备份
    private var maxBackupsBinding: Binding<Int> {
        Binding(
            get: { store.settings.maxBackups > 0 ? store.settings.maxBackups : BackupStore.keepDefault },
            set: { v in
                var s = store.settings
                s.maxBackups = v
                store.updateSettingsPublic(s)
                BackupStore.prune(keep: v)
                refreshBackupStats()
            })
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
                // 拨一下 Toggle 就发一次同步 = 主线程 4~6 个网络往返，必须后台
          DispatchQueue.global(qos: .userInitiated).async {
            _ = CloudSync.syncNow()
      DispatchQueue.main.async { cloudMeta = CloudSync.currentMeta }
     }
   })
    }

    // MARK: 操作

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

/// 列目录 + 每份一次 stat，放后台。备份多了（可选 50 份）在主线程扫很贵
    private func refreshBackupStats() {
    DispatchQueue.global(qos: .utility).async {
            let l = BackupStore.listBackups()
            DispatchQueue.main.async { self.backupList = l }
        }
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
                    exportItem = BackupExportItem(url: u)
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
        restorePayload = p
        restoreSource = entry.title
        pendingAlert = .restoreBackup
    }

    private func performRestore() {
        guard let p = restorePayload else { return }
        restorePayload = nil
        backupNotice = BackupStore.restore(payload: p)
        refreshBackupStats()
    }

    private func handleImport(_ url: URL) {
        importOpen = false
        guard let p = BackupStore.readPayload(at: url) else {
            backupNotice = "这个文件读不出来，可能不是催办的备份"
            return
        }
        restorePayload = p
        restoreSource = url.lastPathComponent
        pendingAlert = .restoreBackup
    }

    /// WebDAV 是网络请求，放后台否则界面会卡住。
    /// 自动同步那边（App.swift 的 onReceive）本来就在主线程，
    /// 那边已有 30 秒节流，不够保险——但那是另一条路径，先不动。
    private func doCloudSync() {
        cloudNotice = "同步中…"
     DispatchQueue.global(qos: .userInitiated).async {
let msg = CloudSync.syncAndReport()
            let n = CloudSync.remoteHistoryCount()
            DispatchQueue.main.async {
  cloudNotice = msg
        cloudMeta = CloudSync.currentMeta
       historyCount = n
   }
        }
    }

/// 查远端存不存在也是网络请求，后台做，顺便在那边弹框
    private func confirmPullFromCloud() {
        guard cloudConfig.isOn else { return }
        cloudNotice = "检查中…"
        DispatchQueue.global(qos: .userInitiated).async {
let exists = CloudSync.remoteFileExists()
            DispatchQueue.main.async {
                if exists {
                    self.pendingAlert = .pullFromCloud
                } else {
      self.cloudNotice = "NAS 上还没有数据，先在另一端上传一次"
                }
            }
        }
    }

    private func doPullFromCloud() {
        // 覆盖前先在本地存一份，出问题能退回来
        BackupStore.autoBackupIfNeeded(tasks: store.tasks, settings: store.settings)
  cloudNotice = "正在从 NAS 下载…"
        DispatchQueue.global(qos: .userInitiated).async {
            // restore 会把每张照片 base64 解码 + 写盘、再 replaceAll 三个 Store，
            // 全是重活，绝对不能放主线程
            let msg = CloudSync.pullOnly().text
            DispatchQueue.main.async {
  self.cloudNotice = msg
       self.cloudMeta = CloudSync.currentMeta
            }
        }
    }

    /// 确认框点了「覆盖恢复 / 停止 / 覆盖」之后走这里
    private func runAlertAction() {
        switch pendingAlert {
        case .restoreBackup:
            performRestore()
        case .disableSync:
            CloudSync.disable()
            cloudConfig = CloudSync.currentConfig
            cloudNotice = "已停止同步，本机数据不受影响"
        case .pullFromCloud:
            doPullFromCloud()
        case nil:
            break
        }
        pendingAlert = nil
    }

private func handleFolderPicked(_ url: URL) {
        cloudNotice = "检查文件夹…"
        // isFolderWritable 要往目录写探针文件再删（2 次网络往返），后台做
        DispatchQueue.global(qos: .userInitiated).async {
            guard CloudSync.isFolderWritable(url.path) else {
  DispatchQueue.main.async {
     self.cloudNotice = "这个文件夹读不到（可能没连上 NAS，或没有写入权限）"
       }
       return
         }
            let photos = self.cloudConfig.includePhotos
            let auto = self.cloudConfig.autoSync
            CloudSync.configure(folder: url.path, includePhotos: photos, autoSync: auto)
   let msg = CloudSync.syncAndReport()
            DispatchQueue.main.async {
        self.cloudConfig = CloudSync.currentConfig
         self.cloudNotice = msg
   self.cloudMeta = CloudSync.currentMeta
 }
        }
    }

    private func fmt(_ d: Date, _ f: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = f
        return df.string(from: d)
    }
}

// MARK: - 设置首页那一行摘要
//
// 「外观与字体」右侧显示「跟随系统 · 标准」，备份与同步也照这个套路，
// 让首页只占一行高度，详细配置全在二级页。

extension BackupStore {
    /// 首页入口右侧的摘要：本地几份备份 · 同步状态
    static func settingsSummary(cloudConfig: CloudSync.Config,
                                backupCount: Int) -> String {
        var parts: [String] = []
        if backupCount > 0 {
            parts.append("本地 \(backupCount) 份")
        } else {
            parts.append("无备份")
        }
        if cloudConfig.isOn {
            parts.append(cloudConfig.mode == "webdav" ? "已连飞牛" : "已同步")
        } else {
            parts.append("未同步")
        }
        return parts.joined(separator: " · ")
    }
}