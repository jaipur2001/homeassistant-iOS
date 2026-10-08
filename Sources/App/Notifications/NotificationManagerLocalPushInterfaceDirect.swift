import Foundation
import HAKit
import Shared

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    private enum Recovery {
        static let localPushDelays: [TimeInterval] = [1, 3, 7, 15, 30, 60]
        static let frontendDelays: [TimeInterval] = [5, 15, 30, 60]
    }

    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    private var connectionStateObserver: NSObjectProtocol?

    private var serversSeenReady = Set<String>()
    private var serversNeedingRecovery = Set<String>()
    private var recoveryAttempts = [String: Int]()
    private var recoveryWorkItems = [String: DispatchWorkItem]()
    private var recoveryAttemptInFlight = Set<String>()
    private var frontendRecoveryWorkItems = [String: [DispatchWorkItem]]()

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

        recoveryWorkItems.values.forEach { $0.cancel() }
        frontendRecoveryWorkItems.values
            .flatMap { $0 }
            .forEach { $0.cancel() }
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
            guard let connection = Current.api(for: server)?.connection,
                  (connection as AnyObject) === (changedConnection as AnyObject) else {
                continue
            }

            let key = server.identifier.rawValue

            switch connection.state {
            case .ready:
                let hadPreviouslyBeenReady = serversSeenReady.contains(key)
                serversSeenReady.insert(key)

                guard hadPreviouslyBeenReady,
                      serversNeedingRecovery.remove(key) != nil else {
                    return
                }

                Current.Log.warning(
                    "Kiosk local push recovery: WebSocket reconnected for \(server.info.name); " +
                        "starting forced local-push resubscribe backoff"
                )
                startRecovery(for: server)
                startFrontendRecovery(for: server)

            case .disconnected:
                if serversSeenReady.contains(key) {
                    serversNeedingRecovery.insert(key)
                    Current.Log.info(
                        "Kiosk local push recovery: disconnect detected for \(server.info.name)"
                    )
                }

            case .connecting, .authenticating:
                break
            }

            return
        }
    }

    private func startRecovery(for server: Server) {
        let key = server.identifier.rawValue

        stopRecovery(forKey: key)
        recoveryAttempts[key] = 0
        scheduleNextRecoveryAttempt(for: server)
    }

    private func scheduleNextRecoveryAttempt(for server: Server) {
        let key = server.identifier.rawValue
        let attempt = recoveryAttempts[key] ?? 0
        let delay = Recovery.localPushDelays[min(attempt, Recovery.localPushDelays.count - 1)]

        recoveryWorkItems[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            self.recoveryWorkItems[key] = nil

            guard let connection = Current.api(for: server)?.connection else {
                Current.Log.warning(
                    "Kiosk local push recovery: API unavailable for \(server.info.name); retrying later"
                )
                self.recoveryAttempts[key] = attempt + 1
                self.scheduleNextRecoveryAttempt(for: server)
                return
            }

            guard case .ready = connection.state else {
                Current.Log.info(
                    "Kiosk local push recovery: WebSocket not ready for \(server.info.name); retrying later"
                )
                self.recoveryAttempts[key] = attempt + 1
                self.scheduleNextRecoveryAttempt(for: server)
                return
            }

            let attemptNumber = attempt + 1
            Current.Log.warning(
                "Kiosk local push recovery: forced LP RETRY #\(attemptNumber) for " +
                    "\(server.info.name) after \(Int(delay))s backoff"
            )

            self.recoveryAttemptInFlight.insert(key)
            self.localPushManagers[server].retrySubscription()

            // Always arm another attempt. A successful subscription changes the
            // LocalPushManager state to .available and cancels this work item in
            // pushManagerStateDidChange(). A failed or stuck attempt therefore
            // cannot leave a 24/7 kiosk permanently without local push.
            self.recoveryAttempts[key] = attempt + 1
            self.scheduleNextRecoveryAttempt(for: server)
        }

        recoveryWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopRecovery(forKey key: String) {
        recoveryWorkItems.removeValue(forKey: key)?.cancel()
        recoveryAttempts.removeValue(forKey: key)
        recoveryAttemptInFlight.remove(key)
    }

    private func startFrontendRecovery(for server: Server) {
        let key = server.identifier.rawValue

        cancelFrontendRecovery(forKey: key)

        guard Current.kioskSettings.enabled else {
            Current.Log.info(
                "Kiosk frontend recovery: kiosk mode disabled; no automatic cache recovery"
            )
            return
        }

        Current.Log.warning(
            "Kiosk frontend recovery: scheduling automatic clear-cache checks for \(server.info.name)"
        )

        var workItems = [DispatchWorkItem]()

        for (index, delay) in Recovery.frontendDelays.enumerated() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }

                guard Current.kioskSettings.enabled else {
                    self.cancelFrontendRecovery(forKey: key)
                    return
                }

                Current.sceneManager.webViewControllerPromise
                    .done { webViewController in
                        Task { @MainActor [weak self] in
                            guard let self else { return }

                            guard webViewController.server.identifier == server.identifier else {
                                Current.Log.info(
                                    "Kiosk frontend recovery: active frontend belongs to another server"
                                )
                                return
                            }

                            guard webViewController.overlayState?.emptyState != nil else {
                                Current.Log.info(
                                    "Kiosk frontend recovery: dashboard recovered; cancelling remaining retries"
                                )
                                self.cancelFrontendRecovery(forKey: key)
                                return
                            }

                            Current.Log.warning(
                                "Kiosk frontend recovery: empty state still visible; automatically running " +
                                    "'clear cache and restart' attempt #\(index + 1) after \(Int(delay))s"
                            )
                            webViewController.retryClearingFrontendCache()
                        }
                    }
                    .catch { error in
                        Current.Log.error(
                            "Kiosk frontend recovery: unable to access current WebViewController: \(error)"
                        )
                    }
            }

            workItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        frontendRecoveryWorkItems[key] = workItems
    }

    private func cancelFrontendRecovery(forKey key: String) {
        frontendRecoveryWorkItems.removeValue(forKey: key)?
            .forEach { $0.cancel() }
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
        let state = localPushManagers[server].state
        let key = server.identifier.rawValue

        switch state {
        case .available:
            if recoveryAttemptInFlight.contains(key) {
                Current.Log.warning(
                    "Kiosk local push recovery: local push restored for \(server.info.name)"
                )
                stopRecovery(forKey: key)
            }

        case .unavailable:
            recoveryAttemptInFlight.remove(key)

            if recoveryWorkItems[key] == nil,
               let connection = Current.api(for: server)?.connection,
               case .ready = connection.state {
                Current.Log.warning(
                    "Kiosk local push recovery: subscription unavailable while WebSocket is ready for " +
                        "\(server.info.name); starting recovery backoff"
                )
                recoveryAttempts[key] = recoveryAttempts[key] ?? 0
                scheduleNextRecoveryAttempt(for: server)
            }

        case .establishing:
            break
        }

        for observer in observers where observer.server == server {
            observer.handler(status(for: server))
        }
    }
}
