import SwiftUI
import UIKit

// MARK: - 文案工具

func timeLabel(_ d: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if cal.isDateInToday(d) {
        f.dateFormat = "今天 HH:mm"
    } else if cal.isDateInTomorrow(d) {
        f.dateFormat = "明天 HH:mm"
    } else if cal.isDateInYesterday(d) {
        f.dateFormat = "昨天 HH:mm"
    } else {
        f.dateFormat = "M月d日 HH:mm"
    }
    return f.string(from: d)
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

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var alarm: AlarmCenter

    var body: some View {
        ZStack {
            TabView {
                TaskListView()
                    .tabItem { Label("清单", systemImage: "checklist") }
                    .badge(store.overdue.count)
                MonthView()
                    .tabItem { Label("日历", systemImage: "calendar") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
            }
            .accentColor(brandColor)

            if let id = alarm.activeTaskId, let task = store.task(id: id) {
                AlarmOverlay(task: task)
                    .zIndex(10)
            }
        }
        .onAppear {
            AlarmLoop.shared.start()
            store.refreshAuth()
            NotificationScheduler.rescheduleAll(tasks: store.tasks, settings: store.settings, catchUp: true)
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
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                store.refreshAuth()
                NotificationScheduler.rescheduleAll(tasks: store.tasks, settings: store.settings, catchUp: true)
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

    /// App 在前台时也照样响铃 + 弹催促页
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
        let taskId = notification.request.content.userInfo["taskId"] as? String
        DispatchQueue.main.async {
            if let id = taskId {
                TaskStore.shared.markNagged(id: id)
                AlarmCenter.shared.show(taskId: id)
            }
        }
    }

    /// 点击通知 / 通知按钮
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskId = response.notification.request.content.userInfo["taskId"] as? String
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case NotificationScheduler.actionDone:
                TaskStore.shared.complete(id: taskId)
            case NotificationScheduler.actionSnooze:
                TaskStore.shared.snooze(id: taskId)
            default:
                AlarmCenter.shared.show(taskId: taskId)
            }
            completionHandler()
        }
    }
}
