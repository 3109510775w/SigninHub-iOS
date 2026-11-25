import Foundation
import BackgroundTasks
import UserNotifications

/// iOS 后台：只有「建议性」调度 + 通知，无法静默自动执行网络签到（系统限制）
enum Scheduler {
    static let refreshID = "com.signinhub.app.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handle(_ task: BGAppRefreshTask) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        // 非越狱 iOS 无法保证后台静默签到；这里仅续约调度，实际签到靠打开 App / 点通知触发
        task.setTaskCompleted(success: true)
        schedule()
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 每日提醒通知：点通知打开 App 后可一键签到
    static func scheduleDailyNotification(time: String, title: String = "该去签到了", body: String = "打开签到中心一键完成今日签到") {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        var comps = DateComponents()
        comps.hour = parts[0]
        comps.minute = parts[1]

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: "signinhub.daily.\(time)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}
