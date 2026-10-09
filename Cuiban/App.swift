import SwiftUI
import UIKit

// MARK: - 文案工具

/// 时间标签文案。走 fmt 的格式化器缓存 —— 这个函数在列表行和每秒刷新的
/// 倒计时标签里都会被调用，原来每次都 new 一个 DateFormatter，很浪费。
func timeLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return fmt(d, "今天 HH:mm") }
    if cal.isDateInTomorrow(d) { return fmt(d, "明天 HH:mm") }
    if cal.isDateInYesterday(d) { return fmt(d, "昨天 HH:mm") }
    return fmt(d, "M月d日 HH:mm")
}

func human(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) 秒" }
    let m = s / 60
    if m < 60 { return "\(m) 分钟" }
    let h = m / 60
    let mm = m % 60
    if h < 24 { return mm > 0 ? "\(h) 小时 \(mm) 分" : "\(h) 小时" }
    return "\(h / 24) 天 \(h % 24) 小时"
}

let brandColor = Color(red: 0.97, green: 0.33, blue: 0.18)
let alarmRed = Color(red: 0.76, green: 0.16, blue: 0.10)

// MARK: - 右下角悬浮新建按钮

struct FabButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.app(26, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(brandColor))
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var alarm: AlarmCenter
    /// 字号变化的整树重建节拍（重建＝换 TabView 的身份，会把各页导航栈一起重置，
    /// 所以「外观与字体」页开着时先挂着，退出后再补，见 FontRebuilder）
    @ObservedObject private var fontRebuild = FontRebuilder.shared
    /// 当前标签页（点了优惠券提醒要能直接跳过去）
    @State private var tab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                TaskListView()
                    .tabItem { Label("清单", systemImage: "checklist") }
                    .badge(store.overdueCount)
                    .tag(0)
                MonthView()
                    .tabItem { Label("日历", systemImage: "calendar") }
                    .tag(1)
                NotesView()
                    .tabItem { Label("笔记", systemImage: "note.text") }
                    .tag(2)
                CouponsView()
                    .tabItem { Label("优惠券", systemImage: "ticket") }
                    .tag(3)
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(4)
            }
            .accentColor(brandColor)
            .id(fontRebuild.rev)

            if let id = alarm.activeTaskId, let task = store.task(id: id) {
                AlarmOverlay(task: task)
                    .zIndex(10)
            }
        }
        .onAppear {
   AlarmLoop.shared.start()
        // 已抢到的任务如果已经跨过下次机会时刻（App 之前一直没开着），
        // 先收起它们、把下一条待抢任务排出来，再重排通知
        store.rollOverHitTasks()
        store.refreshAuth()
            NotificationScheduler.rescheduleAll(tasks: store.tasks, settings: store.settings, catchUp: true)
  // 优惠券的过期提醒跟着重排一次（通知可能被系统或更新清过）
            CouponStore.shared.reschedule()
  // 进 App 先同步一次 NAS 上的新数据。
            // **绝对不能放主线程**：WebDAV 走Semaphore 阻塞等待，
        // 最坏 25 秒首帧全白屏。先让界面出来，同步丢后台延后。
            if CloudSync.currentConfig.isOn {
CloudSync.syncOnLaunch()
       }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cuibanOpenCoupons)) { _ in
            tab = 3
        }
        .onReceive(NotificationCenter.default.publisher(for: FontScale.didChange)) { _ in
            FontRebuilder.shared.fontChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: FontScale.editEnded)) { _ in
            FontRebuilder.shared.editingEnded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cuibanDataChanged)) { _ in
            // 任何数据变化都触发一次同步（内部有 30 秒节流，不会频繁写网络）
            CloudSync.autoSyncIfNeeded()
        }
        .preferredColorScheme(store.settings.theme.colorScheme)
    }
}

// MARK: - App 入口

@main
struct CuibanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = TaskStore.shared
    @StateObject private var alarm = AlarmCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(alarm)
                .environmentObject(NoteStore.shared)
                .environmentObject(CouponStore.shared)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // 回到前台先把「已抢到」里跨过下次机会时刻的收起来，
                // 否则它们会带着过期的每日提醒继续留在清单里
                store.rollOverHitTasks()
                store.refreshAuth()
                NotificationScheduler.rescheduleAll(tasks: store.tasks, settings: store.settings, catchUp: true)
                CouponStore.shared.reschedule()
            case .background:
                if store.settings.keepAlive {
                    BackgroundKeeper.shared.start()
                    AlarmLoop.shared.rearmIfNeeded()
                }
            default:
                break
            }
        }
    }
}

// MARK: - 通知代理

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        NotificationScheduler.registerCategories()
        NotificationScheduler.requestAuthorization()
        AlarmLoop.shared.start()
        return true
    }

    /// App 在前台时也照样响铃 + 弹催促页。
    /// 但得先验明正身：任务已完成 / 已删除 / 还没到点的，是更新前
    /// 旧版本排进系统队列的存货（iOS 更新 App 不会清空通知队列），
    /// 弹出来就是「都完成了还在提醒」。不但不弹，还要顺手清掉。
    private static func vetted(_ taskId: String?) -> (task: TaskItem, live: Bool)? {
        guard let id = taskId, let t = TaskStore.shared.task(id: id), !t.isDone else {
            return nil
        }
        // 正常的催促只会「到点或到点之后」触发；提前 1 分钟以上的都是存货
        let live = t.effectiveDue <= Date().addingTimeInterval(60)
        return (t, live)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        let reqId = notification.request.identifier

        // 优惠券的过期提醒：券还在、还没用、还没过期才弹
        if let couponId = info["couponId"] as? String {
            DispatchQueue.main.async {
                if let c = CouponStore.shared.coupon(id: couponId), !c.isUsed, !c.isExpired {
                    completionHandler([.banner, .list, .sound])
                } else {
                    center.removeDeliveredNotifications(withIdentifiers: [reqId])
                    completionHandler([])
                }
            }
            return
        }

        let taskId = info["taskId"] as? String
        DispatchQueue.main.async {
            guard let vet = AppDelegate.vetted(taskId), vet.live else {
                // 存货或已失效：静默吞掉，顺手清出通知中心
                center.removeDeliveredNotifications(withIdentifiers: [reqId])
                completionHandler([])
                return
            }
            completionHandler([.banner, .list, .sound])
            TaskStore.shared.markNagged(id: vet.task.id)
            AlarmCenter.shared.show(taskId: vet.task.id)
        }
    }

    /// 点击通知 / 通知按钮
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let taskId = info["taskId"] as? String

        // 优惠券提醒：点按钮直接标记已用，点通知本体跳到「优惠券」页
        if let couponId = info["couponId"] as? String {
            DispatchQueue.main.async {
                switch response.actionIdentifier {
                case CouponScheduler.actionUsed:
                    CouponStore.shared.markUsed(id: couponId)
                default:
                    NotificationCenter.default.post(name: .cuibanOpenCoupons, object: nil)
                }
                completionHandler()
            }
            return
        }

        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case NotificationScheduler.actionDone:
                TaskStore.shared.complete(id: taskId)
            case NotificationScheduler.actionSnooze:
                TaskStore.shared.snooze(id: taskId)
            default:
                // 点开的是存货（任务没了 / 已完成 / 还没到点）就别弹催促页了
                if let vet = AppDelegate.vetted(taskId), vet.live {
                    AlarmCenter.shared.show(taskId: vet.task.id)
                }
            }
            completionHandler()
        }
    }
}
