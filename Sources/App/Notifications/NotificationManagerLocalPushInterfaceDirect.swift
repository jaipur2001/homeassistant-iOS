import Foundation
import HAKit
import Shared

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    weak var localPushDelegate: LocalPushManagerDelegate?

    init(delegate: LocalPushManagerDelegate) {
        self.localPushDelegate = delegate
        self.localPushManagers = .init { [weak self] server in
            let manager = LocalPushManager(server: server)
            manager.delegate = self?.localPushDelegate
            let token = NotificationCenter.default.addObserver(
                forName: LocalPushManager.stateDidChange,
                object: manager,
                queue: .main,
                using: { [weak self] _ in
                    self?.pushManagerStateDidChange(server: server)
                }
            )

            return .init(manager) { _, _ in
                NotificationCenter.default.removeObserver(token)
            }
        }

        // PerServerContainer is eager by default, so all currently configured
        // servers already have a LocalPushManager here. Retry once after startup
        // to cover the common kiosk case where the manager was constructed before
        // the Home Assistant API/WebSocket connection became available.
        DispatchQueue.main.async { [weak self] in
            self?.retryAllSubscriptions()
        }
    }

    func addObserver(
        for server: Server,
        handler: @escaping (NotificationManagerLocalPushStatus) -> Void
    ) -> HACancellable {
        let observer = Observer(identifier: UUID(), server: server, handler: handler)
        observers.append(observer)
        return HABlockCancellable { [weak self] in
            self?.observers.removeAll(where: { $0.identifier == observer.identifier })
        }
    }

    func retryLocalPush(for server: Server?, reason: LocalPushRetryReason) {
        if let server {
            localPushManagers[server].retrySubscription()
        } else {
            retryAllSubscriptions()
        }
    }

    func scheduleAppOpenLocalPushRetries() {
        // NotificationManager calls this whenever the app becomes active.
        // Force a fresh WebSocket subscription so Home Assistant sees the kiosk
        // as connected to mobile_app local push after foregrounding/reconnecting.
        retryAllSubscriptions()
    }

    private func retryAllSubscriptions() {
        for server in Current.servers.all {
            localPushManagers[server].retrySubscription()
        }
    }

    private struct Observer: Equatable {
        let identifier: UUID
        let server: Server
        let handler: (NotificationManagerLocalPushStatus) -> Void

        static func == (lhs: Observer, rhs: Observer) -> Bool {
            lhs.identifier == rhs.identifier
        }
    }

    private var observers = [Observer]()

    private func pushManagerStateDidChange(server: Server) {
        for observer in observers where observer.server == server {
            observer.handler(status(for: server))
        }
    }
}
