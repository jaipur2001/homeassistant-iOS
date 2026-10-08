import Foundation
import HAKit
import Shared
import UIKit

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    private enum ConnectionWatchdog {
        static let interval: TimeInterval = 10
        static let pingTimeout: TimeInterval = 4
        static let reconnectDelayAfterDisconnect: TimeInterval = 3
        static let stalledConnectionCyclesBeforeReset = 2
    }

    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    private var connectionStateObserver: NSObjectProtocol?
    private var watchdogWorkItem: DispatchWorkItem?
    private var pingTimeoutWorkItems = [String: DispatchWorkItem]()
    private var pingTokens = [String: HACancellable]()
    private var pingGenerations = [String: UUID]()
    private var nonReadyCycles = [String: Int]()
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
        //
        // The kiosk also keeps a lightweight WebSocket watchdog alive while it
        // is foregrounded. Home Assistant Core restarts can otherwise leave a
        // long-lived Single App Mode session waiting for a reconnect until an
        // iOS lifecycle/network event occurs.
        DispatchQueue.main.async { [weak self] in
            self?.retryAllSubscriptions()
            self?.scheduleConnectionWatchdog(after: 1)
        }
    }

    deinit {
        if let connectionStateObserver {
            NotificationCenter.default.removeObserver(connectionStateObserver)
        }
        watchdogWorkItem?.cancel()
        pingTimeoutWorkItems.values.forEach { $0.cancel() }
        pingTokens.values.forEach { $0.cancel() }
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
        scheduleConnectionWatchdog(after: 0.5)
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
                  (connection as AnyObject) === (changedConnection as AnyObject) else {
                continue
            }

            let key = server.identifier.rawValue

            switch connection.state {
            case .ready:
                nonReadyCycles[key] = 0
                cancelPing(for: key)
                Current.Log.info(
                    "Kiosk connection watchdog: WebSocket ready; refreshing local-push subscription for \(server.info.name)"
                )
                localPushManagers[server].retrySubscription()

            case .disconnected(reason: .rejected):
                nonReadyCycles[key] = 0
                cancelPing(for: key)
                Current.Log.warning(
                    "Kiosk connection watchdog: WebSocket authentication rejected for \(server.info.name); automatic recovery suppressed"
                )

            case .disconnected(reason: _):
                cancelPing(for: key)
                scheduleConnectionWatchdog(
                    after: ConnectionWatchdog.reconnectDelayAfterDisconnect
                )

            case .connecting, .authenticating:
                cancelPing(for: key)
            }

            return
        }
    }

    private func scheduleConnectionWatchdog(after delay: TimeInterval = ConnectionWatchdog.interval) {
        watchdogWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.runConnectionWatchdog()
        }
        watchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runConnectionWatchdog() {
        defer {
            scheduleConnectionWatchdog()
        }

        guard UIApplication.shared.applicationState == .active else {
            return
        }

        for server in Current.servers.all {
            guard let connection = Current.api(for: server)?.connection else {
                continue
            }

            let key = server.identifier.rawValue

            switch connection.state {
            case .ready:
                nonReadyCycles[key] = 0
                verifyWebSocketIsAlive(server: server, connection: connection)

            case .disconnected(reason: .rejected):
                nonReadyCycles[key] = 0
                cancelPing(for: key)

            case .disconnected(reason: _):
                nonReadyCycles[key] = 0
                cancelPing(for: key)
                Current.Log.warning(
                    "Kiosk connection watchdog: forcing reconnect for disconnected server \(server.info.name)"
                )
                connection.connect()

            case .connecting, .authenticating:
                cancelPing(for: key)
                let cycles = (nonReadyCycles[key] ?? 0) + 1
                nonReadyCycles[key] = cycles

                if cycles >= ConnectionWatchdog.stalledConnectionCyclesBeforeReset {
                    hardReconnect(
                        server: server,
                        connection: connection,
                        reason: "connection remained \(connection.state) for \(cycles) watchdog cycles"
                    )
                }
            }
        }
    }

    private func verifyWebSocketIsAlive(server: Server, connection: HAConnection) {
        let key = server.identifier.rawValue

        guard pingGenerations[key] == nil else {
            return
        }

        let generation = UUID()
        pingGenerations[key] = generation

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  pingGenerations[key] == generation else {
                return
            }

            pingGenerations.removeValue(forKey: key)
            pingTimeoutWorkItems.removeValue(forKey: key)
            pingTokens.removeValue(forKey: key)?.cancel()

            hardReconnect(
                server: server,
                connection: connection,
                reason: "WebSocket ping timed out after \(ConnectionWatchdog.pingTimeout)s"
            )
        }

        pingTimeoutWorkItems[key] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ConnectionWatchdog.pingTimeout,
            execute: timeoutWorkItem
        )

        let request = HARequest(type: .ping, data: [:])
        let token = connection.send(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      pingGenerations[key] == generation else {
                    return
                }

                pingGenerations.removeValue(forKey: key)
                pingTimeoutWorkItems.removeValue(forKey: key)?.cancel()
                pingTokens.removeValue(forKey: key)

                switch result {
                case .success:
                    Current.Log.verbose(
                        "Kiosk connection watchdog: WebSocket ping OK for \(server.info.name)"
                    )
                case let .failure(error):
                    hardReconnect(
                        server: server,
                        connection: connection,
                        reason: "WebSocket ping failed: \(error)"
                    )
                }
            }
        }

        pingTokens[key] = token
    }

    private func hardReconnect(
        server: Server,
        connection: HAConnection,
        reason: String
    ) {
        guard UIApplication.shared.applicationState == .active else {
            return
        }

        let key = server.identifier.rawValue
        cancelPing(for: key)
        nonReadyCycles[key] = 0

        Current.Log.warning(
            "Kiosk connection watchdog: hard reconnect for \(server.info.name); reason=\(reason)"
        )

        connection.disconnect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard UIApplication.shared.applicationState == .active else {
                return
            }
            connection.connect()
        }
    }

    private func cancelPing(for key: String) {
        pingGenerations.removeValue(forKey: key)
        pingTimeoutWorkItems.removeValue(forKey: key)?.cancel()
        pingTokens.removeValue(forKey: key)?.cancel()
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
