import SwiftUI

// MARK: - 飞牛直连（WebDAV）
//
// 「备份与同步」二级页里的第三层：填地址 / 用户名 / 密码，
// 测试连接通了再保存并同步一次。
// 单独一个文件，因为它只被 BackupSyncSettingsView 引用一次，
// 塞在 SettingsView.swift 里只会让那个文件越来越难读。
//
// 密码存在 Keychain，页面只显示「已保存」不回显——
// 免签名 App 拿不到 Keychain 访问组，但同 App 内自己读没问题。

struct WebDAVSettingsView: View {
    @EnvironmentObject var store: TaskStore

    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var notice: String? = nil
    @State private var testing = false
    @State private var saving = false
    /// 从 NAS 恢复是破坏性操作，要二次确认
    @State private var confirmRestore = false

    /// 已保存过密码时，SecureField 显示占位说明而不是空白（留空 = 不改）
    private var passPlaceholder: String {
        CloudSync.webdavPassword.isEmpty ? "密码" : "已保存，留空则不改"
    }

    private var busy: Bool { testing || saving }

    var body: some View {
        Form {
            Section {
                TextField("WebDAV 地址", text: $url)
                    .font(.app(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $user)
                    .font(.app(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(passPlaceholder, text: $pass)
                    .font(.app(14))
            } header: {
                Text("飞牛 WebDAV")
            } footer: {
                Text("飞牛里「设置 → 文件服务 → WebDAV」打开后会给出地址和端口（http 默认 5005、https 默认 5006）。地址格式：http://你的NAS地址:端口/目录，例如 http://192.168.1.10:5005/cuiban-sync。填到目录就行，不用带文件名，App 会在下面放 cuiban-data.json。自签名证书已经放行，frp 映射的公网地址直接填。")
            }

            Section {
                Button(testing ? "测试中…" : "测试连接") { runTest() }
                    .disabled(busy || url.isEmpty)

                Button(saving ? "连接中…" : "保存并同步") { save() }
                    .disabled(busy || url.isEmpty)

                if let n = notice {
                    Text(n)
                        .font(.app(12))
                        .foregroundColor(color(for: n))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("保存后会立刻同步一次：NAS 上有数据就拉下来，没有就把本机数据推上去。")
            }

            Section {
                Button("从 NAS 恢复（覆盖本机全部数据）", role: .destructive) {
                    confirmRestore = true
                }
            } footer: {
                Text("只拉不推：把 NAS 上的任务、笔记、卡片、照片整个换成本机的内容，手机上最近改的东西会没掉。恢复前会自动在本地存一份备份。")
            }
        }
        .navigationTitle("飞牛直连")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let c = CloudSync.currentConfig
            if url.isEmpty {
                url = c.mode == "webdav" ? c.webdavURL : ""
                user = c.mode == "webdav" ? c.webdavUser : ""
            }
        }
        .alert("用 NAS 上的数据覆盖本机？", isPresented: $confirmRestore) {
            Button("覆盖", role: .destructive) { restoreFromNAS() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机现有的 \(store.tasks.count) 个任务会被 NAS 上的数据替换。已经先在本地存了一份备份，出问题可以从「本地备份恢复」里退回来。")
        }
    }

    private func color(for msg: String) -> Color {
        if msg.hasPrefix("连接成功") || msg.contains("已上传")
            || msg.contains("已经一致") || msg.hasPrefix("已恢复") {
            return .green
        }
        if msg.hasPrefix("已连接") { return .green }
        return .orange
    }

    /// 用当前输入拼一个临时客户端探一下，不落配置
    private func runTest() {
        testing = true
        notice = nil
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pass.isEmpty ? CloudSync.webdavPassword : pass
        let usr = user
        DispatchQueue.global(qos: .userInitiated).async {
            let msg = WebDAVClient(baseURL: u, user: usr, password: p).test()
            DispatchQueue.main.async {
                testing = false
                notice = msg
            }
        }
    }

    private func save() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { notice = "先填 NAS 地址"; return }
        let p = pass.isEmpty ? CloudSync.webdavPassword : pass
        let usr = user
        saving = true
        notice = nil
        let includePhotos = store.settings.backupIncludePhotos
        DispatchQueue.global(qos: .userInitiated).async {
            CloudSync.configureWebDAV(url: u, user: usr, password: p,
                                      includePhotos: includePhotos, autoSync: true)
            // 先探一次，地址填错就别把「已连接」显示出来
            let probe = WebDAVClient(baseURL: u, user: usr, password: p).test()
            let synced = probe.hasPrefix("连接成功") ? CloudSync.syncAndReport() : probe
            DispatchQueue.main.async {
                saving = false
                notice = synced
                pass = ""
                if synced.hasPrefix("连接成功") {
                    // 通了就退回上一层，让用户在备份页看到「飞牛已连接」
                    NotificationCenter.default.post(name: .cloudConfigChanged, object: nil)
                }
            }
        }
    }

    private func restoreFromNAS() {
        saving = true
        notice = nil
        DispatchQueue.global(qos: .userInitiated).async {
            // 覆盖前先在本地存一份，出问题能退回来
            BackupStore.autoBackupIfNeeded(tasks: TaskStore.shared.tasks,
                                           settings: TaskStore.shared.settings)
            let msg = CloudSync.pullOnly().text
            DispatchQueue.main.async {
                saving = false
                notice = msg
            }
        }
    }
}