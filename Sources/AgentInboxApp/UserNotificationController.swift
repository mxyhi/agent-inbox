import AppKit
import OSLog
import UserNotifications

private let userNotificationLogger = Logger(subsystem: "agent-inbox", category: "UserNotification")

/// 现代系统通知入口:按真实通知事件申请权限，并保证前台 accessory app 仍展示 banner。
@MainActor
final class UserNotificationController: NSObject {
    private let center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        if let center {
            self.center = center
        } else if Bundle.main.bundleIdentifier != nil {
            self.center = .current()
        } else {
            // SwiftPM 裸可执行文件没有 LaunchServices bundle proxy，调用 current() 会触发 NSException。
            self.center = nil
        }
        super.init()
        if let center = self.center {
            center.delegate = self
            userNotificationLogger.debug("系统通知代理已安装")
        } else {
            userNotificationLogger.warning("系统通知不可用:当前进程不是 app bundle")
        }
    }

    /// 异步检查授权并立即投递通知；调用方无需阻塞用户操作。
    func show(
        title: String,
        message: String,
        threadIdentifier: String = "agent-inbox-errors"
    ) {
        guard let center else {
            showFallbackAlert(title: title, message: message)
            return
        }

        Task {
            do {
                guard try await canDeliverNotification(using: center) else {
                    userNotificationLogger.warning("系统通知未投递:用户未授权")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = message
                content.sound = .default
                content.threadIdentifier = threadIdentifier
                content.interruptionLevel = .active

                let identifier = UUID().uuidString
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
                userNotificationLogger.info("系统通知已投递:id=\(identifier, privacy: .public)")
            } catch {
                userNotificationLogger.error(
                    "系统通知投递失败:\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// 只在首次实际需要通知时触发系统授权弹窗，避免应用启动时无上下文打扰用户。
    private func canDeliverNotification(using center: UNUserNotificationCenter) async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            userNotificationLogger.info("系统通知授权完成:granted=\(granted, privacy: .public)")
            return granted
        case .denied:
            return false
        @unknown default:
            userNotificationLogger.warning("系统通知授权状态未知")
            return false
        }
    }

    /// 裸 SwiftPM 开发进程无法注册系统通知时，使用原生对话框保留可见错误反馈。
    private func showFallbackAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        userNotificationLogger.info("已使用原生对话框展示通知后备提示")
    }
}

extension UserNotificationController: UNUserNotificationCenterDelegate {
    /// accessory app 处于前台时，显式保留通知中心、banner 和声音展示。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        userNotificationLogger.debug("前台系统通知准备展示")
        completionHandler([.banner, .list, .sound])
    }
}
