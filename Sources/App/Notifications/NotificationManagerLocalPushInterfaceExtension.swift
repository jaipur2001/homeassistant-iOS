import HAKit
import Shared

/// Kiosk build implementation:
///
/// The stock iOS app uses NEAppPushManager/PushProvider on physical iOS devices.
/// The kiosk build deliberately routes physical-device local push through the
/// existing direct Home Assistant WebSocket channel instead.
///
/// Keeping this type name preserves the upstream call site while changing only
/// the transport used by this kiosk branch.
final class NotificationManagerLocalPushInterfaceExtension: NotificationManagerLocalPushInterface {
    private let directInterface: NotificationManagerLocalPushInterfaceDirect

    init() {
        guard let notificationManager = AppDelegate.shared?.notificationManager else {
            fatalError("Kiosk WebSocket push initialized before AppDelegate became available")
        }

        directInterface = NotificationManagerLocalPushInterfaceDirect(delegate: notificationManager)
    }

    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        directInterface.status(for: server)
    }

    func addObserver(
        for server: Server,
        handler: @escaping (NotificationManagerLocalPushStatus) -> Void
    ) -> HACancellable {
        directInterface.addObserver(for: server, handler: handler)
    }

    func retryLocalPush(for server: Server?, reason: LocalPushRetryReason) {
        directInterface.retryLocalPush(for: server, reason: reason)
    }

    func scheduleAppOpenLocalPushRetries() {
        directInterface.scheduleAppOpenLocalPushRetries()
    }
}
