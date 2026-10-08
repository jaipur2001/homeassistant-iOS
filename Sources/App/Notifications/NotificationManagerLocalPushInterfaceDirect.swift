import Foundation
import HAKit
import Shared

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    private var connectionStateObserver: NSObjectProtocol?
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

        // PerServerContainer is eager by default, so all configured servers
        // already have a LocalPushManager here. Retry after startup in case
        // the manager was created before the API/WebSocket became available.
        connectionStateObserver = NotificationCenter.default.addObserver(
            forName: HAConnectionState.didTransitionToStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.connectionStateDidChange(notification)
        }

        DispatchQueue.main.async { [weak self] in
            self?.retryAllSubscriptions()
        }
    }

    deinit {
        if let connectionStateObserver {
            NotificationCenter.default.removeObserver(connectionStateObserver)
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
        retryAllSubscriptions()
    }

    private func retryAllSubscriptions() {
        for server in Current.servers.all {
            localPushManagers[server].retrySubscription()
        }
    }

    private func connectionStateDidChange(_ notification: Notification) {
        guard let changedConnection = notification.object as? HAConnection else { return }

        for server in Current.servers.all {
            guard let connection = Current.api(for: server)?.connection,
                  (connection as AnyObject) === (changedConnection as AnyObject),
                  case .ready = connection.state else {
                continue
            }

            Current.Log.info(
                "Kiosk local push: Home Assistant WebSocket ready; forcing local-push resubscribe for \(server.info.name)"
            )
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
