import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject private var ai = AIStore.shared

    @State private var aiTesting = false
    @State private var aiTestResult: String? = nil

    private let intervals = [1, 2, 3, 5, 10, 15, 20, 30, 60]

    var body: some View {
        NavigationView {
            Form {
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

                // MARK: AI 智能解析

                Section(header: Text("AI 智能解析（可选）"),
                        footer: Text("打开后，新建任务时可以直接打一句话（如「下周一上午 10 点开周会」），或者选图识别后让 AI 再复核一遍。调用的是你自己填的服务，Key 只存在这台手机上。")) {
                    Toggle("开启 AI 解析", isOn: $ai.enabled)

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

                Section(header: Text("怎么用"), footer: Text("催办 v1.1 · 为 TrollStore 打造的免签名原生应用")) {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("1. 新建任务，选好时间和催促间隔")
                        tip("2. 也可以直接选一张截图，或打一句话交给 AI 解析")
                        tip("3. 首次打开时允许通知权限")
                        tip("4. 到点不完成就一直催，直到你点「完成」")
                        tip("5. 「日历」页能看整月安排，重复任务会往后推算")
                        tip("6. 打开「后台常驻」后 App 会留在后台精确计时")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear { store.refreshAuth() }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            store.refreshPendingCount()
        }
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
}
