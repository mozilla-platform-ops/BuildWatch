import SwiftUI
import UserNotifications

@main
struct BuildWatchApp: App {

    init() {
        configureNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
}

// MARK: - Notification Delegate

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification taps
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        // Deep link into push if pushId is available
        if let pushId = userInfo["pushId"] as? Int {
            NotificationCenter.default.post(
                name: .openPush,
                object: nil,
                userInfo: ["pushId": pushId]
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let openPush = Notification.Name("BuildWatch.openPush")
}
