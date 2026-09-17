import HAKit
import Shared

/// Kiosk branch implementation:
///
/// The stock iOS app uses NEAppPushManager/PushProvider on physical iOS devices.
/// Our sideloaded kiosk build cannot rely on those Apple push entitlements, so we
/// deliberately route physical-device local push through the already existing
/// direct Home Assistant WebSocket channel instead.
///
/// Keeping this type name avoids touching NotificationManager.swift and preserves
/// the upstream call site while changing only the transport used by this branch.
final class NotificationManagerLocalPushInterfaceExtension: NotificationManagerLocalPushInterface {
    private let directInterface: NotificationManagerLocalPushInterfaceDirect

    init() {
        guard let notificationManager = AppDelegate.shared?.notificationManager else {
            fatalError("Kiosk WebSocket push initialized before AppDelegate became available")
        }

        self.directInterface = NotificationManagerLocalPushInterfaceDirect(delegate: notificationManager)
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

/// Shared diagnostics helper used by ConnectionSettingsViewModel.
///
/// The stock physical-device implementation defines this helper in the same file.
/// The kiosk transport no longer needs NEAppPushManager, but the connection settings
/// still use the network eligibility checks, so the helper must remain available.
enum LocalPushRetryDiagnostics {
    static func matchesExpectedNetworkConditions(server: Server, currentSSID: String?) -> Bool {
        guard server.info.connection.isLocalPushEnabled,
              let currentSSID,
              server.info.connection.internalSSIDs?.contains(currentSSID) == true else {
            return false
        }

        return true
    }

    static func canRetry(server: Server, currentSSID: String?) -> Bool {
        matchesExpectedNetworkConditions(server: server, currentSSID: currentSSID) &&
            server.info.connection.address(for: .internal) != nil
    }

    static func payload(
        server: Server,
        reason: LocalPushRetryReason,
        currentSSID: String?,
        managerCount: Int,
        activeManagerCount: Int,
        error: Error?
    ) -> [String: Any] {
        [
            "server_id": server.identifier.rawValue,
            "server_name": server.info.name,
            "reason": reason.eventValue,
            "current_ssid": currentSSID ?? "",
            "configured_ssids": server.info.connection.internalSSIDs ?? [],
            "local_push_enabled": server.info.connection.isLocalPushEnabled,
            "has_internal_url": server.info.connection.address(for: .internal) != nil,
            "manager_count": managerCount,
            "active_manager_count": activeManagerCount,
            "error": error.map { String(describing: $0) } ?? "",
        ]
    }
}
