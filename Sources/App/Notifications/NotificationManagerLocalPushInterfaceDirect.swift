import Foundation
import HAKit
import PromiseKit
import Shared
import UIKit

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    private var connectionStateObserver: NSObjectProtocol?
    private var serversSeenReady = Set<String>()
    private var serversNeedingWarmRecovery = Set<String>()
    private var warmRecoveryInFlight = Set<String>()
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

        connectionStateObserver = NotificationCenter.default.addObserver(
            forName: HAConnectionState.didTransitionToStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.connectionStateDidChange(notification)
        }

        // PerServerContainer is eager by default, so all configured servers
        // already have a LocalPushManager here. Retry after startup in case
        // the manager was created before the API/WebSocket became available.
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
        guard let changedConnection = notification.object as? HAConnection else {
            return
        }

        for server in Current.servers.all {
            guard let api = Current.api(for: server),
                  (api.connection as AnyObject) === (changedConnection as AnyObject) else {
                continue
            }

            let key = server.identifier.rawValue

            switch api.connection.state {
            case .ready:
                let hadPreviouslyBeenReady = serversSeenReady.contains(key)
                serversSeenReady.insert(key)

                guard hadPreviouslyBeenReady,
                      serversNeedingWarmRecovery.remove(key) != nil,
                      UIApplication.shared.applicationState == .active,
                      !warmRecoveryInFlight.contains(key) else {
                    return
                }

                warmRecoveryInFlight.insert(key)

                Current.Log.warning(
                    "Kiosk HA recovery: WebSocket reconnected for \(server.info.name); " +
                        "running the same warm API reconciliation as app foreground"
                )

                api.Connect(reason: .warm)
                    .done(on: .main) { [weak self] in
                        guard let self else { return }

                        Current.Log.info(
                            "Kiosk HA recovery: warm API reconciliation completed for \(server.info.name); " +
                                "forcing local-push resubscribe"
                        )
                        self.localPushManagers[server].retrySubscription()
                    }
                    .catch(on: .main) { [weak self] error in
                        guard let self else { return }

                        Current.Log.error(
                            "Kiosk HA recovery: warm API reconciliation failed for \(server.info.name): \(error); " +
                                "forcing local-push resubscribe anyway"
                        )
                        self.localPushManagers[server].retrySubscription()
                    }
                    .finally { [weak self] in
                        DispatchQueue.main.async {
                            self?.warmRecoveryInFlight.remove(key)
                        }
                    }

            case .disconnected:
                if serversSeenReady.contains(key) {
                    serversNeedingWarmRecovery.insert(key)
                    Current.Log.info(
                        "Kiosk HA recovery: detected disconnect after established session for \(server.info.name)"
                    )
                }

            case .connecting, .authenticating:
                break
            }

            return
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
