import AppKit
import ServiceManagement
import UserNotifications

/// macOS notification banners, used only for events the notification policy
/// lets through and only after the owner turns banners on, which is when the
/// system permission prompt appears. The notch stays the primary surface.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization: Equatable {
        case notDetermined, denied, allowed
    }

    /// Called when the owner clicks a banner, so the notch can open.
    var onActivate: (() -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    func authorization() async -> Authorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Asks macOS for permission. Only called from an explicit owner action.
    func requestAuthorization() async -> Authorization {
        _ = try? await center.requestAuthorization(options: [.alert, .badge])
        return await authorization()
    }

    /// Posts a banner. `groupKey` threads related banners, and `identifier`
    /// replaces an earlier banner for the same thing instead of stacking.
    func post(title: String, body: String, identifier: String, groupKey: String?) async {
        guard await authorization() == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let groupKey { content.threadIdentifier = groupKey }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { onActivate?() }
    }
}

/// Launch at login through `SMAppService`, the supported modern API. The
/// system shows the app under Login Items, where the owner can also change it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state, which may differ from the request when
    /// macOS refuses (for example, the owner disabled it in System Settings).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Claude Overhead login item change failed: %@", error.localizedDescription)
        }
        return isEnabled
    }
}
