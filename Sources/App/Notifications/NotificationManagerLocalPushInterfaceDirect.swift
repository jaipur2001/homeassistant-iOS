import Foundation
import HAKit
import PromiseKit
import Shared

class NotificationManagerLocalPushInterfaceDirect: NotificationManagerLocalPushInterface {
    func status(for server: Server) -> NotificationManagerLocalPushStatus {
        .allowed(localPushManagers[server].state)
    }

    private var localPushManagers: PerServerContainer<LocalPushManager>!
    private var startupRecoverySubscriptions = [String: [HACancellable]]()
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
        //
        // The kiosk also subscribes to Home Assistant's startup lifecycle.
        // Those subscriptions have no retry timeout, so they survive long-lived
        // kiosk sessions and reconnect after a Home Assistant Core restart.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retryAllSubscriptions()
            self.installStartupRecoverySubscriptions()
        }
    }

    deinit {
        startupRecoverySubscriptions.values
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
        installStartupRecoverySubscriptions()
    }

    private func retryAllSubscriptions() {
        for server in Current.servers.all {
            localPushManagers[server].retrySubscription()
        }
    }

    private func installStartupRecoverySubscriptions() {
        for server in Current.servers.all {
            installStartupRecoverySubscriptions(for: server)
        }
    }

    private func installStartupRecoverySubscriptions(for server: Server) {
        let key = server.identifier.rawValue

        guard startupRecoverySubscriptions[key] == nil else {
            return
        }

        guard let connection = Current.api(for: server)?.connection else {
            Current.Log.error(
                "Kiosk startup recovery: no API connection available for \(server.info.name)"
            )
            return
        }

        let componentLoadedToken = connection.subscribe(
            to: startupEventSubscription(.componentLoaded),
            initiated: { result in
                switch result {
                case .success:
                    Current.Log.info(
                        "Kiosk startup recovery: subscribed to component_loaded for \(server.info.name)"
                    )
                case let .failure(error):
                    Current.Log.error(
                        "Kiosk startup recovery: component_loaded subscription failed for " +
                            "\(server.info.name): \(error)"
                    )
                }
            },
            handler: { [weak self] _, event in
                guard let self else { return }
                guard event.data["component"] as? String == "mobile_app" else {
                    return
                }

                DispatchQueue.main.async {
                    self.handleMobileAppComponentLoaded(server: server)
                }
            }
        )

        let homeAssistantStartedToken = connection.subscribe(
            to: startupEventSubscription(.homeassistantStarted),
            initiated: { result in
                switch result {
                case .success:
                    Current.Log.info(
                        "Kiosk startup recovery: subscribed to homeassistant_started for \(server.info.name)"
                    )
                case let .failure(error):
                    Current.Log.error(
                        "Kiosk startup recovery: homeassistant_started subscription failed for " +
                            "\(server.info.name): \(error)"
                    )
                }
            },
            handler: { [weak self] _, _ in
                guard let self else { return }

                DispatchQueue.main.async {
                    self.handleHomeAssistantStarted(server: server)
                }
            }
        )

        startupRecoverySubscriptions[key] = [
            componentLoadedToken,
            homeAssistantStartedToken,
        ]
    }

    private func startupEventSubscription(
        _ eventType: HAEventType
    ) -> HATypedSubscription<HAResponseEvent> {
        guard let rawEventType = eventType.rawValue else {
            preconditionFailure("Kiosk startup recovery requires a concrete Home Assistant event type")
        }

        return HATypedSubscription<HAResponseEvent>(
            request: HARequest(
                type: .subscribeEvents,
                data: ["event_type": rawEventType],
                shouldRetry: true,
                retryDuration: nil
            )
        )
    }

    private func handleMobileAppComponentLoaded(server: Server) {
        Current.Log.warning(
            "Kiosk startup recovery: mobile_app component loaded for \(server.info.name); " +
                "forcing local-push resubscribe"
        )
        localPushManagers[server].retrySubscription()
    }

    private func handleHomeAssistantStarted(server: Server) {
        Current.Log.warning(
            "Kiosk startup recovery: Home Assistant startup completed for \(server.info.name); " +
                "forcing local-push resubscribe"
        )
        localPushManagers[server].retrySubscription()
        recoverFrontendIfNeeded(for: server)
    }

    private func recoverFrontendIfNeeded(for server: Server) {
        Current.sceneManager.webViewControllerPromise
            .done { webViewController in
                Task { @MainActor in
                    guard webViewController.server.identifier == server.identifier else {
                        Current.Log.info(
                            "Kiosk startup recovery: active frontend belongs to another server; " +
                                "skipping cache recovery"
                        )
                        return
                    }

                    guard webViewController.overlayState?.emptyState != nil else {
                        Current.Log.info(
                            "Kiosk startup recovery: frontend is not in empty state; " +
                                "no cache reset required"
                        )
                        return
                    }

                    Current.Log.warning(
                        "Kiosk startup recovery: frontend is still in empty state after HA startup; " +
                            "automatically running 'clear cache and restart'"
                    )
                    webViewController.retryClearingFrontendCache()
                }
            }
            .catch { error in
                Current.Log.error(
                    "Kiosk startup recovery: unable to access active frontend after HA startup: \(error)"
                )
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
