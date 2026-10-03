import AVFoundation
import CallbackURLKit
import FirebaseMessaging
import Foundation
import MediaPlayer
import PromiseKit
import Shared
import SwiftUI
import UserNotifications
import XCGLogger

#if DEBUG
private let forceDisableLocalPushForLiveActivityTesting = false
#endif

class NotificationManager: NSObject, LocalPushManagerDelegate {
    lazy var localPushManager: NotificationManagerLocalPushInterface = {
        #if DEBUG
        if forceDisableLocalPushForLiveActivityTesting {
            return NotificationManagerLocalPushInterfaceDisallowed()
        }
        #endif

        #if targetEnvironment(simulator)
        return NotificationManagerLocalPushInterfaceDirect(delegate: self)
        #else
        if Current.isCatalyst {
            return NotificationManagerLocalPushInterfaceDirect(delegate: self)
        } else {
            return NotificationManagerLocalPushInterfaceExtension()
        }
        #endif
    }()

    var commandManager = NotificationCommandManager()

    /// Hidden, off-screen volume view; `MPVolumeView` only drives the hardware volume while in a window.
    private lazy var volumeControlView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Persistent native player for kiosk alarm audio.
    private var kioskAudioPlayer: AVAudioPlayer?
    private var kioskAudioFileURL: URL?
    #endif

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        _ = localPushManager
        if Manager.shared.callbackURLScheme == nil {
            Manager.shared.callbackURLScheme = Manager.urlSchemes?.first
        }
    }

    @objc private func didBecomeActive() {
        if Current.settingsStore.clearBadgeAutomatically {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        localPushManager.scheduleAppOpenLocalPushRetries()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.2, *) {
            // Catch ends and starts enqueued by the extension while the app was suspended.
            LiveActivityPendingEndObserver.drain()
            LiveActivityPendingStartObserver.drain()
        }
        #endif
    }

    private func openCamera(from userInfo: [AnyHashable: Any]?) {
        guard let entityId = cameraEntityId(from: userInfo) else {
            Current.Log.error("Received kiosk_show_camera command without a valid camera entity_id")
            return
        }

        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in
                guard let self else { return }
                let server = cameraServer(from: userInfo, fallback: webViewController.server)
                CameraOverlayPresenter.shared.show(entityId: entityId, server: server, on: webViewController)
            }.catch { error in
                Current.Log.error("Failed to show camera from push command: \(error)")
            }
    }

    private func cameraEntityId(from userInfo: [AnyHashable: Any]?) -> String? {
        guard let userInfo else { return nil }

        if let entityId = userInfo["entity_id"] as? String, entityId.hasPrefix("camera.") {
            return entityId
        }

        if let homeassistant = userInfo["homeassistant"] as? [String: Any],
           let entityId = homeassistant["entity_id"] as? String,
           entityId.hasPrefix("camera.") {
            return entityId
        }

        if let homeassistant = userInfo["homeassistant"] as? [AnyHashable: Any],
           let entityId = homeassistant["entity_id"] as? String,
           entityId.hasPrefix("camera.") {
            return entityId
        }

        return nil
    }

    private func webhookId(from userInfo: [AnyHashable: Any]?) -> String? {
        guard let userInfo else { return nil }

        if let webhookId = userInfo["webhook_id"] as? String {
            return webhookId
        }

        if let homeassistant = userInfo["homeassistant"] as? [String: Any] {
            return homeassistant["webhook_id"] as? String
        }

        if let homeassistant = userInfo["homeassistant"] as? [AnyHashable: Any] {
            return homeassistant["webhook_id"] as? String
        }

        return nil
    }

    private func cameraServer(from userInfo: [AnyHashable: Any]?, fallback: Server) -> Server {
        guard let webhookId = webhookId(from: userInfo),
              let server = Current.servers.server(forWebhookID: webhookId) else {
            return fallback
        }

        return server
    }

    private func hideCamera() {
        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { webViewController in
                CameraOverlayPresenter.shared.hide(on: webViewController)
            }.catch { error in
                Current.Log.error("Failed to hide camera from push command: \(error)")
            }
    }

    private func showDoorbell(from userInfo: [AnyHashable: Any]) {
        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in
                guard let self else { return }
                let server = cameraServer(from: userInfo, fallback: webViewController.server)

                do {
                    let station = try KioskDoorbellStationResolver.resolve(
                        server: server,
                        userInfo: userInfo
                    )
                    KioskDoorbellOverlayPresenter.shared.show(
                        station: station,
                        server: server,
                        on: webViewController
                    )
                } catch {
                    Current.Log.warning(
                        "Doorbell station not available in local registry, forcing refresh before retry: \(error)"
                    )
                    self.refreshDoorbellRegistryAndRetry(
                        userInfo: userInfo,
                        server: server,
                        webViewController: webViewController,
                        initialError: error
                    )
                }
            }.catch { error in
                Current.Log.error("Failed to show dynamic doorbell overlay: \(error)")
            }
    }

    private func refreshDoorbellRegistryAndRetry(
        userInfo: [AnyHashable: Any],
        server: Server,
        webViewController: WebViewControllerProtocol,
        initialError: Error
    ) {
        var observer: NSObjectProtocol?
        var didFinish = false

        func finishRetry() {
            guard !didFinish else { return }
            didFinish = true

            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            DispatchQueue.main.async { [weak self, weak webViewController] in
                guard let self, let webViewController else { return }

                do {
                    let station = try KioskDoorbellStationResolver.resolve(
                        server: server,
                        userInfo: userInfo
                    )
                    Current.Log.info(
                        "Doorbell station resolved after forced registry refresh: \(station.id)"
                    )
                    KioskDoorbellOverlayPresenter.shared.show(
                        station: station,
                        server: server,
                        on: webViewController
                    )
                } catch {
                    Current.Log.error(
                        "Doorbell station resolution failed after forced registry refresh. "
                            + "Initial error: \(initialError). Retry error: \(error)"
                    )
                    KioskDoorbellOverlayPresenter.shared.showConfigurationError(
                        message: error.localizedDescription,
                        on: webViewController
                    )
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .appDatabaseUpdaterDidFinishRoutine,
            object: nil,
            queue: .main
        ) { notification in
            guard let updatedServer = notification.object as? Server,
                  updatedServer.identifier == server.identifier else {
                return
            }
            finishRetry()
        }

        Current.appDatabaseUpdater.update(
            server: server,
            forceUpdate: true,
            showProgress: false
        )

        // A failed/cancelled refresh may never emit the completion notification.
        // Retry once from the current cache anyway, but never leave the doorbell command silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            finishRetry()
        }
    }

    private func hideDoorbell() {
        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { webViewController in
                KioskDoorbellOverlayPresenter.shared.hide(on: webViewController)
            }.catch { error in
                Current.Log.error("Failed to hide dynamic doorbell overlay: \(error)")
            }
    }

    private func setScreenBrightness(_ level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        DispatchQueue.main.async {
            UIScreen.main.brightness = clamped
            Current.Log.info("Kiosk set screen brightness to \(clamped)")
        }
    }

    private func setSystemVolume(_ level: Float, completion: (() -> Void)? = nil) {
        let clamped = min(max(level, 0), 1)

        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in
                guard let self else {
                    completion?()
                    return
                }

                if volumeControlView.superview == nil {
                    webViewController.view.addSubview(volumeControlView)
                    volumeControlView.layoutIfNeeded()
                }

                func applyVolume(attempt: Int) {
                    guard let slider = self.volumeControlView.subviews.compactMap({ $0 as? UISlider }).first else {
                        Current.Log.error("Unable to locate system volume slider for kiosk command")
                        completion?()
                        return
                    }

                    slider.setValue(clamped, animated: false)
                    slider.sendActions(for: .valueChanged)
                    slider.sendActions(for: .touchUpInside)

                    // MPVolumeView updates the hardware volume asynchronously. Verify
                    // the value iOS reports before starting alarm/media playback.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let actualVolume = AVAudioSession.sharedInstance().outputVolume
                        let delta = abs(actualVolume - clamped)

                        if delta > 0.05, attempt < 2 {
                            Current.Log.warning(
                                "Kiosk system volume not settled yet: requested=\(clamped), "
                                    + "actual=\(actualVolume), retry=\(attempt + 1)"
                            )
                            applyVolume(attempt: attempt + 1)
                            return
                        }

                        Current.Log.info(
                            "Kiosk system volume settled: requested=\(clamped), actual=\(actualVolume)"
                        )
                        completion?()
                    }
                }

                // Let MPVolumeView finish attaching to the window before locating its slider.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    applyVolume(attempt: 0)
                }
            }
            .catch { error in
                Current.Log.error("Failed to set volume from push command: \(error)")
                completion?()
            }
    }

    private func playKioskMedia(
        _ command: KioskPushCommand,
        userInfo: [AnyHashable: Any]
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let mediaContentId = command.mediaContentId(from: userInfo) else {
            Current.Log.error("Ignoring \(command.rawValue): missing media_content_id in payload")
            return
        }

        let requestedVolume = command.level(from: userInfo)

        Current.Log.info("Native kiosk audio requested: \(mediaContentId)")

        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in
                guard let self else { return }

                let server = self.cameraServer(
                    from: userInfo,
                    fallback: webViewController.server
                )

                guard let api = Current.api(for: server) else {
                    Current.Log.error(
                        "Unable to play native kiosk media: no API available for server \(server.info.name)"
                    )
                    return
                }

                api.downloadMediaSource(mediaContentId, expires: 300)
                    .done(on: .main) { [weak self] localFileURL in
                        guard let self else { return }
                        Current.Log.info("Native kiosk media downloaded to \(localFileURL.path)")

                        if let requestedVolume {
                            self.setSystemVolume(requestedVolume) { [weak self] in
                                self?.startKioskAudio(fileURL: localFileURL)
                            }
                        } else {
                            self.startKioskAudio(fileURL: localFileURL)
                        }
                    }
                    .catch { error in
                        Current.Log.error(
                            "Unable to resolve/download native kiosk media \(mediaContentId): \(error)"
                        )
                    }
            }
            .catch { error in
                Current.Log.error(
                    "Unable to access current Home Assistant web view for native kiosk audio: \(error)"
                )
            }
        #else
        Current.Log.warning("kiosk_play_media is only supported by the native iOS application")
        #endif
    }

    private func startKioskAudio(fileURL: URL) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        kioskAudioPlayer?.stop()
        kioskAudioPlayer = nil

        if let previousFileURL = kioskAudioFileURL,
           previousFileURL != fileURL {
            try? FileManager.default.removeItem(at: previousFileURL)
        }

        kioskAudioFileURL = fileURL

        do {
            let audioSession = AVAudioSession.sharedInstance()

            // The camera stream can stay active for the whole kiosk session. Reset
            // the shared audio session explicitly before native MP3 playback so no
            // stale category/mode from another AVFoundation user leaves playback
            // silent even though AVAudioPlayer itself starts successfully.
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Current.Log.warning(
                    "Native kiosk audio: unable to deactivate previous audio session: \(error)"
                )
            }

            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)

            Current.Log.info(
                "Native kiosk audio session active: category=\(audioSession.category.rawValue), "
                    + "mode=\(audioSession.mode.rawValue), volume=\(audioSession.outputVolume)"
            )

            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.volume = 1.0
            player.numberOfLoops = 0

            guard player.prepareToPlay() else {
                throw NSError(
                    domain: "HomeAssistant.KioskAudio",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer prepareToPlay failed"]
                )
            }

            kioskAudioPlayer = player

            guard player.play() else {
                kioskAudioPlayer = nil
                throw NSError(
                    domain: "HomeAssistant.KioskAudio",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer refused to start playback"]
                )
            }

            Current.Log.info(
                "Native kiosk audio playback started: \(fileURL.lastPathComponent), duration=\(player.duration)s"
            )
        } catch {
            Current.Log.error("Unable to start native kiosk audio: \(error)")
            kioskAudioPlayer = nil

            if let currentFileURL = kioskAudioFileURL {
                try? FileManager.default.removeItem(at: currentFileURL)
            }

            kioskAudioFileURL = nil
        }
        #endif
    }

    private func stopKioskMedia() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Current.Log.info("Stopping native kiosk audio")

        kioskAudioPlayer?.stop()
        kioskAudioPlayer = nil

        if let currentFileURL = kioskAudioFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }

        kioskAudioFileURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            Current.Log.warning("Unable to deactivate native kiosk audio session: \(error)")
        }
        #else
        Current.Log.warning("kiosk_stop_media is only supported by the native iOS application")
        #endif
    }

    func resetPushID() -> Promise<String> {
        firstly {
            Promise<Void> { seal in
                Messaging.messaging().deleteToken(completion: seal.resolve)
            }
        }.then {
            Promise<String> { seal in
                Messaging.messaging().token(completion: seal.resolve)
            }
        }
    }

    func setupFirebase() {
        Current.Log.verbose("Calling UIApplication.shared.registerForRemoteNotifications()")
        UIApplication.shared.registerForRemoteNotifications()

        Messaging.messaging().delegate = self
        Messaging.messaging().isAutoInitEnabled = Current.settingsStore.privacy.messaging
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        Current.Log.error("failed to register for remote notifications: \(error)")
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let apnsToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Current.Log.verbose("Successfully registered for push notifications! APNS token: \(apnsToken)")
        Current.crashReporter.setUserProperty(value: apnsToken, name: "APNS Token")

        var tokenType: MessagingAPNSTokenType = .prod

        if Current.appConfiguration == .debug {
            tokenType = .sandbox
        }

        Messaging.messaging().setAPNSToken(deviceToken, type: tokenType)
    }

    func didReceiveRemoteNotification(
        userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(userInfo)

        firstly {
            handleRemoteNotification(userInfo: userInfo)
        }.done(
            completionHandler
        )
    }

    func localPushManager(
        _ manager: LocalPushManager,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) {
        handleRemoteNotification(userInfo: userInfo).cauterize()
    }

    private func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> Guarantee<UIBackgroundFetchResult> {
        Current.Log.verbose("remote notification: \(userInfo)")

        return commandManager.handle(userInfo).map {
            UIBackgroundFetchResult.newData
        }.recover { _ in
            Guarantee<UIBackgroundFetchResult>.value(.failed)
        }
    }

    fileprivate func handleShortcutNotification(
        _ shortcutName: String,
        _ shortcutDict: [String: String]
    ) {
        var inputParams: CallbackURLKit.Parameters = shortcutDict
        inputParams["name"] = shortcutName

        Current.Log.verbose("Sending params in shortcut \(inputParams)")

        let eventName = "ios.shortcut_run"
        let deviceDict: [String: String] = [
            "sourceDevicePermanentID": AppConstants.PermanentID, "sourceDeviceName": UIDevice.current.name,
            "sourceDeviceID": Current.settingsStore.deviceID,
        ]
        var eventData: [String: Any] = ["name": shortcutName, "input": shortcutDict, "device": deviceDict]

        var successHandler: CallbackURLKit.SuccessCallback?

        if shortcutDict["ignore_result"] == nil {
            successHandler = { params in
                Current.Log.verbose("Received params from shortcut run \(String(describing: params))")
                eventData["status"] = "success"
                eventData["result"] = params?["result"]

                Current.Log.verbose("Success, sending data \(eventData)")

                when(fulfilled: Current.apis.map { api in
                    api.CreateEvent(eventType: eventName, eventData: eventData)
                }).catch { error in
                    Current.Log.error("Received error from createEvent during shortcut run \(error)")
                }
            }
        }

        let failureHandler: CallbackURLKit.FailureCallback = { error in
            eventData["status"] = "failure"
            eventData["error"] = error.XCUErrorParameters

            when(fulfilled: Current.apis.map { api in
                api.CreateEvent(eventType: eventName, eventData: eventData)
            }).catch { error in
                Current.Log.error("Received error from createEvent during shortcut run \(error)")
            }
        }

        let cancelHandler: CallbackURLKit.CancelCallback = {
            eventData["status"] = "cancelled"

            when(fulfilled: Current.apis.map { api in
                api.CreateEvent(eventType: eventName, eventData: eventData)
            }).catch { error in
                Current.Log.error("Received error from createEvent during shortcut run \(error)")
            }
        }

        do {
            try Manager.shared.perform(
                action: "run-shortcut",
                urlScheme: "shortcuts",
                parameters: inputParams,
                onSuccess: successHandler,
                onFailure: failureHandler,
                onCancel: cancelHandler
            )
        } catch let error as NSError {
            Current.Log.error("Running shortcut failed \(error)")

            eventData["status"] = "error"
            eventData["error"] = error.localizedDescription

            when(fulfilled: Current.apis.map { api in
                api.CreateEvent(eventType: eventName, eventData: eventData)
            }).catch { error in
                Current.Log.error("Received error from CallbackURLKit perform \(error)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    private func urlString(from response: UNNotificationResponse) -> String? {
        let content = response.notification.request.content
        let urlValue = ["url", "uri", "clickAction"].compactMap { content.userInfo[$0] }.first

        if let action = content.userInfoActionConfigs.first(
            where: { $0.identifier.lowercased() == response.actionIdentifier.lowercased() }
        ), let url = action.url {
            // we only allow the action-specific one to override global if it's set
            return url
        } else if let openURLRaw = urlValue as? String {
            // global url [string], always do it if we aren't picking a specific action
            return openURLRaw
        } else if let openURLDictionary = urlValue as? [String: String] {
            // old-style, per-action url -- for before we could define actions in the notification dynamically
            return openURLDictionary.compactMap { key, value -> String? in
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                   key.lowercased() == NotificationCategory.FallbackActionIdentifier {
                    return value
                } else if key.lowercased() == response.actionIdentifier.lowercased() {
                    return value
                } else {
                    return nil
                }
            }.first
        } else {
            return nil
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(response.notification.request.content.userInfo)

        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            Current.Log.info("ignoring dismiss action for notification")
            completionHandler()
            return
        }

        #if DEBUG
        if response.actionIdentifier == NotificationSnoozeAction.debugTenSecondsActionIdentifier {
            Current.notificationDispatcher.reschedule(response.notification.request.content, after: 10)
            completionHandler()
            return
        }
        #endif

        // Snooze is an on-device-only convenience: reschedule a local re-delivery of the same
        // notification (so it keeps its snooze actions) and skip forwarding to Home Assistant.
        if let minutes = NotificationSnoozeAction.minutes(fromActionIdentifier: response.actionIdentifier) {
            Current.notificationDispatcher.reschedule(
                response.notification.request.content,
                after: TimeInterval(minutes) * 60
            )
            completionHandler()
            return
        }

        let userInfo = response.notification.request.content.userInfo

        Current.Log.verbose("User info in incoming notification \(userInfo) with response \(response)")

        // A tap must still run any HA command the notification carries. willPresent covers the
        // foreground path; this covers taps from the background/lock screen. Notably, a
        // `live_update` Live Activity start delivered over local push is handled by the
        // PushProvider extension (which can't touch ActivityKit), so without this a tap would
        // never start the activity. Fire-and-forget: it's independent of the tap routing below.
        if let hadict = userInfo["homeassistant"] as? [String: Any],
           (hadict["command"] as? String) != nil || (hadict["live_update"] as? Bool) == true {
            commandManager.handle(userInfo).cauterize()
        }

        if Current.kiosk.settings.acceptRemoteCommands,
           KioskPushCommand(message: response.notification.request.content.body) == .showCamera,
           cameraEntityId(from: userInfo) != nil {
            openCamera(from: userInfo)
            completionHandler()
            return
        }

        guard let server = Current.servers.server(for: response.notification.request.content) else {
            Current.Log.info("ignoring push when unable to find server")
            completionHandler()
            return
        }

        if let shortcutDict = userInfo["shortcut"] as? [String: String],
           let shortcutName = shortcutDict["name"] {
            handleShortcutNotification(shortcutName, shortcutDict)
        }

        if let url = urlString(from: response) {
            Current.Log.info("launching URL \(url)")
            Current.sceneManager.appCoordinator.done {
                $0.open(from: .notification, server: server, urlString: url, isComingFromAppIntent: false)
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let entityId = userInfo["entity_id"] as? String,
                  let entityURL = AppConstants.openEntityDeeplinkURL(
                      entityId: entityId,
                      serverId: server.identifier.rawValue
                  ) {
            // No tap action was specified, so open the notification's entity on the server it
            // came from.
            Current.Log.info("opening entity \(entityId) from notification tap")
            Current.sceneManager.appCoordinator.done { _ in
                URLOpener.shared.open(entityURL, options: [:], completionHandler: nil)
            }
        }

        if let info = HomeAssistantAPI.PushActionInfo(response: response) {
            Current.backgroundTask(withName: BackgroundTask.handlePushAction.rawValue) { _ in
                Current.api(for: server)?
                    .handlePushAction(for: info) ?? .init(error: HomeAssistantAPI.APIError.noAPIAvailable)
            }.ensure {
                completionHandler()
            }.catch { err in
                Current.Log.error("Error when handling push action: \(err)")
            }
        } else {
            completionHandler()
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(notification.request.content.userInfo)

        // Handle commands (including Live Activities) for foreground notifications.
        // didReceiveRemoteNotification handles background pushes via Firebase/APNs,
        // but willPresent fires when the app is in the foreground. Without this,
        // notifications received while the app is open would never trigger the
        // Live Activity handler.
        // If a command is recognized, suppress the notification banner so the user
        // sees only the Live Activity (not a duplicate standard notification).
        if let hadict = notification.request.content.userInfo["homeassistant"] as? [String: Any],
           (hadict["command"] as? String) != nil || (hadict["live_update"] as? Bool) == true {
            commandManager.handle(notification.request.content.userInfo).done {
                // Play the chime if the notification has sound (non-silent live update),
                // but never show a banner — the Live Activity widget is the visual feedback.
                let options: UNNotificationPresentationOptions = notification.request.content.sound != nil
                    ? [.sound]
                    : []
                completionHandler(options)
            }.catch { error in
                // Unknown command — fall through to normal banner presentation so the user isn't silently swallowed.
                if case NotificationCommandManager.CommandError.unknownCommand = error {
                    completionHandler([.badge, .sound, .list, .banner])
                } else {
                    completionHandler([])
                }
            }
            return
        }

        if notification.request.content.userInfo[XCGLogger.notifyUserInfoKey] != nil,
           UIApplication.shared.applicationState != .background {
            completionHandler([])
            return
        }

        if let options = kioskPushPresentationOptions(for: notification.request) {
            completionHandler(options)
            return
        }

        var methods: UNNotificationPresentationOptions = [.badge, .sound, .list, .banner]
        if let presentationOptions = notification.request.content.userInfo["presentation_options"] as? [String] {
            methods = []
            if presentationOptions.contains("sound") || notification.request.content.sound != nil {
                methods.insert(.sound)
            }
            if presentationOptions.contains("badge") {
                methods.insert(.badge)
            }
            if presentationOptions.contains("list") {
                methods.insert(.list)
            }
            if presentationOptions.contains("banner") {
                methods.insert(.banner)
            }
        }
        return completionHandler(methods)
    }

    /// Takes the request rather than the `UNNotification` wrapping it: everything here needs only the
    /// request, and unlike a notification a request can be built in tests.
    func kioskPushPresentationOptions(for request: UNNotificationRequest) -> UNNotificationPresentationOptions? {
        let content = request.content
        let message = content.body
        guard KioskPushCommand.isKioskCommand(message: message) else {
            return nil
        }

        let kioskSettings = Current.kiosk.settings
        guard kioskSettings.acceptRemoteCommands else {
            Current.Log.info("Ignoring kiosk remote command (disabled in settings): \(message)")
            return nil
        }

        guard let command = KioskPushCommand(message: message) else {
            Current.Log.warning("Unhandled kiosk push command, using default presentation: \(message)")
            return nil
        }

        performKioskCommand(command, userInfo: content.userInfo)

        // The command already ran above; the toast is only its visual confirmation, which the user can
        // switch off for a kiosk that should react silently.
        if #available(iOS 18, *),
           let toast = command.confirmationToast(id: request.identifier, settings: kioskSettings) {
            Task { @MainActor in
                ToastPresenter.shared.show(toast: toast, duration: 4)
            }
        }

        return []
    }

    private func performKioskCommand(_ command: KioskPushCommand, userInfo: [AnyHashable: Any]) {
        switch command {
        case .showScreensaver:
            Current.kiosk.requestScreensaver(.show)
        case .hideScreensaver:
            Current.kiosk.requestScreensaver(.hide)
        case .showCamera:
            openCamera(from: userInfo)
        case .hideCamera:
            hideCamera()
        case .showDoorbell:
            showDoorbell(from: userInfo)
        case .hideDoorbell:
            hideDoorbell()
        case .setBrightness:
            if let level = command.level(from: userInfo) {
                setScreenBrightness(level)
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid level in payload")
            }
        case .setVolume:
            if let level = command.level(from: userInfo) {
                setSystemVolume(level)
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid volume in payload")
            }
        case .playMedia:
            playKioskMedia(command, userInfo: userInfo)
        case .stopMedia:
            stopKioskMedia()
        case .showAlarm:
            showKioskAlarm(userInfo: userInfo)
        case .hideAlarm:
            hideKioskAlarm()
        case .setScreensaverMode:
            if let mode = command.screensaverMode(from: userInfo) {
                Current.kiosk.setScreensaverMode(mode)
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid mode in payload")
            }
        case .setScreensaverBrightness:
            if let level = command.level(from: userInfo) {
                Current.kiosk.setScreensaverDimLevel(Double(level))
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid level in payload")
            }
        case .reload:
            Current.sceneManager.webViewControllerPromise.done { $0.refresh() }
        case .defaultDashboard:
            returnToKioskDefault()
        }
    }

    private func showKioskAlarm(userInfo: [AnyHashable: Any]) {
        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { webViewController in
                let server = self.cameraServer(from: userInfo, fallback: webViewController.server)
                let alarm = KioskAlarmPayload(userInfo: userInfo)

                KioskAlarmOverlayPresenter.shared.show(
                    alarm: alarm,
                    server: server,
                    on: webViewController
                )
            }.catch { error in
                Current.Log.error("Failed to show kiosk alarm overlay: \(error)")
            }
    }

    private func hideKioskAlarm() {
        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { webViewController in
                KioskAlarmOverlayPresenter.shared.hide(on: webViewController)
            }.catch { error in
                Current.Log.error("Failed to hide kiosk alarm overlay: \(error)")
            }
    }

    /// Returns the kiosk to its configured server and dashboard. If the kiosk is pinned to a server
    /// other than the one on screen, switching to it rebuilds the web view (which loads the kiosk
    /// dashboard on creation); otherwise the current web view navigates to the configured dashboard.
    /// Mirrors `OnboardingStateObservable.applyKioskTarget(_:)`.
    private func returnToKioskDefault() {
        let serverId = Current.kioskSettings.serverId
        Current.sceneManager.webViewControllerPromise.done { webViewController in
            if let serverId, serverId != webViewController.server.identifier.rawValue,
               let server = Current.servers.server(forServerIdentifier: serverId) {
                Current.sceneManager.appCoordinator.done { $0.open(server: server) }
            } else {
                webViewController.applyKioskDashboard()
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        let rootView = NavigationView {
            NotificationSettingsView(showsDoneButton: true)
        }
        .navigationViewStyle(.stack)
        let hostingController = rootView.embeddedInHostingController()

        Current.sceneManager.appCoordinator.done {
            var rootViewController = $0.window?.rootViewController
            if let navigationController = rootViewController as? UINavigationController {
                rootViewController = navigationController.viewControllers.first
            }
            rootViewController?.dismiss(animated: false, completion: {
                rootViewController?.present(hostingController, animated: true, completion: nil)
            })
        }
    }
}


private struct KioskDoorbellPayload {
    let stationId: String?
    let triggerEntityId: String?

    init(userInfo: [AnyHashable: Any]) {
        stationId = Self.string("station", in: userInfo)
            ?? Self.string("station_id", in: userInfo)
        triggerEntityId = Self.string("trigger_entity_id", in: userInfo)
            ?? Self.string("doorbell_entity_id", in: userInfo)
    }

    private static func string(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let homeassistant = userInfo["homeassistant"] as? [String: Any],
           let value = homeassistant[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let homeassistant = userInfo["homeassistant"] as? [AnyHashable: Any],
           let value = homeassistant[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }
}

private struct KioskDoorbellOpener: Identifiable, Equatable {
    enum Kind: Int {
        case door
        case gate
        case generic
    }

    let entityId: String
    let name: String
    let kind: Kind
    let serviceDomain: String
    let service: String

    var id: String { entityId }

    var buttonTitle: String {
        switch kind {
        case .door:
            return "Tür öffnen"
        case .gate:
            return "Tor öffnen"
        case .generic:
            return name
        }
    }

    var systemImage: String {
        switch kind {
        case .door:
            return "lock.open.fill"
        case .gate:
            return "door.garage.open"
        case .generic:
            return "lock.open"
        }
    }
}

private struct KioskDoorbellStation {
    let id: String
    let name: String
    let cameraEntityId: String
    let cameraName: String?
    let triggerEntityId: String?
    let intercomEntityId: String?
    let openers: [KioskDoorbellOpener]
}

private enum KioskDoorbellStationResolver {
    enum ResolveError: LocalizedError {
        case stationMissing
        case stationNotFound(String)
        case cameraMissing(String)

        var errorDescription: String? {
            switch self {
            case .stationMissing:
                return "No station label or trigger entity was supplied"
            case let .stationNotFound(station):
                return "No entities found for doorbell station \(station)"
            case let .cameraMissing(station):
                return "Doorbell station \(station) has no camera with label function_camera"
            }
        }
    }

    private static let stationPrefix = "station_"
    private static let functionDoorbell = "function_doorbell"
    private static let functionCamera = "function_camera"
    private static let functionIntercom = "function_intercom"
    private static let functionOpener = "function_opener"
    private static let typeDoor = "type_door"
    private static let typeGate = "type_gate"

    static func resolve(
        server: Server,
        userInfo: [AnyHashable: Any]
    ) throws -> KioskDoorbellStation {
        let serverId = server.identifier.rawValue
        let entities = try EntityRegistryListForDisplay.Entity.config(serverId: serverId)
        let devices = try AppDeviceRegistry.config(serverId: serverId)
        let devicesById = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0) })

        func labels(for entity: EntityRegistryListForDisplay.Entity) -> Set<String> {
            var result = Set(entity.labels ?? [])
            if let deviceId = entity.deviceId,
               let device = devicesById[deviceId] {
                result.formUnion(device.labels ?? [])
            }
            return result
        }

        let payload = KioskDoorbellPayload(userInfo: userInfo)
        let requestedStation = payload.stationId.map(normalizedStationId)

        let triggerEntry = payload.triggerEntityId.flatMap { triggerEntityId in
            entities.first { $0.entityId == triggerEntityId }
        }

        let triggerStation = triggerEntry.flatMap { entry in
            labels(for: entry)
                .filter { $0.hasPrefix(stationPrefix) }
                .sorted()
                .first
        }

        let fallbackStations = Set(
            entities.flatMap { entity -> [String] in
                let entityLabels = labels(for: entity)
                guard entityLabels.contains(functionDoorbell) else { return [] }
                return entityLabels.filter { $0.hasPrefix(stationPrefix) }
            }
        )

        let stationId: String
        if let requestedStation {
            stationId = requestedStation
        } else if let triggerStation {
            stationId = triggerStation
        } else if fallbackStations.count == 1, let onlyStation = fallbackStations.first {
            stationId = onlyStation
        } else {
            throw ResolveError.stationMissing
        }

        let stationEntities = entities.filter { labels(for: $0).contains(stationId) }
        guard !stationEntities.isEmpty else {
            throw ResolveError.stationNotFound(stationId)
        }

        let camera = stationEntities
            .filter {
                $0.entityId.hasPrefix("camera.")
                    && labels(for: $0).contains(functionCamera)
            }
            .sorted { $0.entityId < $1.entityId }
            .first

        guard let camera else {
            throw ResolveError.cameraMissing(stationId)
        }

        let doorbell = stationEntities
            .filter { labels(for: $0).contains(functionDoorbell) }
            .sorted { $0.entityId < $1.entityId }
            .first

        let intercom = stationEntities
            .filter { labels(for: $0).contains(functionIntercom) }
            .sorted { $0.entityId < $1.entityId }
            .first

        let openers = stationEntities.compactMap { entity -> KioskDoorbellOpener? in
            let entityLabels = labels(for: entity)
            guard entityLabels.contains(functionOpener),
                  let service = openerService(for: entity.entityId) else {
                return nil
            }

            let kind: KioskDoorbellOpener.Kind
            if entityLabels.contains(typeGate) {
                kind = .gate
            } else if entityLabels.contains(typeDoor) {
                kind = .door
            } else {
                kind = .generic
            }

            let name = entity.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return KioskDoorbellOpener(
                entityId: entity.entityId,
                name: name?.isEmpty == false ? name! : entity.entityId,
                kind: kind,
                serviceDomain: service.domain,
                service: service.service
            )
        }
        .sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let trimmedDoorbellName = doorbell?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String
        if let trimmedDoorbellName, !trimmedDoorbellName.isEmpty {
            displayName = trimmedDoorbellName
        } else {
            displayName = humanizedStationName(stationId)
        }

        return KioskDoorbellStation(
            id: stationId,
            name: displayName,
            cameraEntityId: camera.entityId,
            cameraName: camera.name,
            triggerEntityId: payload.triggerEntityId ?? doorbell?.entityId,
            intercomEntityId: intercom?.entityId,
            openers: openers
        )
    }

    private static func normalizedStationId(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.hasPrefix(stationPrefix) ? normalized : stationPrefix + normalized
    }

    private static func humanizedStationName(_ stationId: String) -> String {
        stationId
            .replacingOccurrences(of: stationPrefix, with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func openerService(for entityId: String) -> (domain: String, service: String)? {
        guard let domain = entityId.split(separator: ".", maxSplits: 1).first.map(String.init) else {
            return nil
        }

        switch domain {
        case "script":
            return ("script", "turn_on")
        case "button":
            return ("button", "press")
        case "input_button":
            return ("input_button", "press")
        case "lock":
            return ("lock", "unlock")
        case "cover":
            return ("cover", "open_cover")
        case "switch":
            return ("switch", "turn_on")
        default:
            return nil
        }
    }
}

private final class KioskDoorbellOverlayPresenter {
    static let shared = KioskDoorbellOverlayPresenter()

    private weak var overlayController: UIViewController?
    private var isTransitioning = false
    private var pendingShow: (() -> Void)?

    private init() {}

    func show(
        station: KioskDoorbellStation,
        server: Server,
        on webViewController: WebViewControllerProtocol
    ) {
        precondition(Thread.isMainThread)

        let present = { [weak self, weak webViewController] in
            guard let self, let webViewController else { return }
            self.present(station: station, server: server, on: webViewController)
        }

        if isTransitioning {
            pendingShow = present
            return
        }

        if webViewController.overlayedController != nil {
            isTransitioning = true
            pendingShow = present
            webViewController.dismissOverlayController(animated: false) { [weak self] in
                guard let self else { return }
                isTransitioning = false
                overlayController = nil
                let deferred = pendingShow
                pendingShow = nil
                deferred?()
            }
            return
        }

        present()
    }

    func showConfigurationError(
        message: String,
        on webViewController: WebViewControllerProtocol
    ) {
        precondition(Thread.isMainThread)

        let controller = KioskDoorbellConfigurationErrorView(
            message: message,
            dismiss: { [weak self, weak webViewController] in
                guard let self, let webViewController else { return }
                self.hide(on: webViewController)
            }
        )
        .embeddedInHostingController()

        controller.modalPresentationStyle = .overFullScreen
        overlayController = controller
        Current.kiosk.setCameraOverlayVisible(true)

        if webViewController.overlayedController != nil {
            webViewController.dismissOverlayController(animated: false) { [weak webViewController] in
                webViewController?.presentOverlayController(controller: controller, animated: true)
            }
        } else {
            webViewController.presentOverlayController(controller: controller, animated: true)
        }
    }

    func hide(on webViewController: WebViewControllerProtocol) {
        precondition(Thread.isMainThread)

        guard let overlayController,
              webViewController.overlayedController === overlayController else {
            self.overlayController = nil
            Current.kiosk.setCameraOverlayVisible(false)
            return
        }

        isTransitioning = true
        webViewController.dismissOverlayController(animated: true) { [weak self] in
            self?.overlayController = nil
            self?.isTransitioning = false
            Current.kiosk.setCameraOverlayVisible(false)
        }
    }

    private func present(
        station: KioskDoorbellStation,
        server: Server,
        on webViewController: WebViewControllerProtocol
    ) {
        let controller = KioskDoorbellView(
            station: station,
            server: server,
            dismiss: { [weak self, weak webViewController] in
                guard let self, let webViewController else { return }
                self.hide(on: webViewController)
            },
            performOpener: { [weak self] opener in
                self?.perform(opener: opener, server: server)
            }
        )
        .embeddedInHostingController()

        controller.modalPresentationStyle = .overFullScreen
        overlayController = controller
        Current.kiosk.setCameraOverlayVisible(true)
        webViewController.presentOverlayController(controller: controller, animated: true)

        Current.Log.info(
            "Doorbell overlay shown: station=\(station.id), camera=\(station.cameraEntityId), "
                + "openers=\(station.openers.map(\.entityId))"
        )
    }

    private func perform(opener: KioskDoorbellOpener, server: Server) {
        guard let api = Current.api(for: server) else {
            Current.Log.error("Doorbell opener failed: no API available")
            return
        }

        api.callServiceWithResponse(
            domain: opener.serviceDomain,
            service: opener.service,
            serviceData: ["entity_id": opener.entityId],
            returnResponse: false
        ).done { _ in
            Current.Log.info(
                "Doorbell opener executed: \(opener.entityId) via "
                    + "\(opener.serviceDomain).\(opener.service)"
            )
        }.catch { error in
            Current.Log.error("Doorbell opener \(opener.entityId) failed: \(error)")
        }
    }
}

private struct KioskDoorbellConfigurationErrorView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.orange)

                Text("Doorbell nicht konfiguriert")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 700)

                Text("Prüfe station_* und function_camera in Home Assistant.")
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)

                Button(action: dismiss) {
                    Label("Schließen", systemImage: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(maxWidth: 320)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(48)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }
}

private struct KioskDoorbellView: View {
    let station: KioskDoorbellStation
    let server: Server
    let dismiss: () -> Void
    let performOpener: (KioskDoorbellOpener) -> Void

    @State private var pendingOpener: KioskDoorbellOpener?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            CameraPlayerView(
                server: server,
                cameraEntityId: station.cameraEntityId,
                cameraName: station.cameraName,
                allowsCameraSelection: false,
                showsCloseButton: false
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.fill")
                    Text(station.name)
                        .font(.title2.bold())
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Klingeldialog schließen")
                }

                if station.intercomEntityId != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.slash.fill")
                        Text("Gegensprechen vorbereitet")
                        Spacer()
                        Text("Mikrofon aus")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                if !station.openers.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(station.openers) { opener in
                            Button {
                                pendingOpener = opener
                            } label: {
                                Label(opener.buttonTitle, systemImage: opener.systemImage)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }
            }
            .padding(20)
            .background(.ultraThinMaterial)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            pendingOpener.map { "\($0.buttonTitle)?" } ?? "Öffnen?",
            isPresented: Binding(
                get: { pendingOpener != nil },
                set: { if !$0 { pendingOpener = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let opener = pendingOpener {
                Button(opener.buttonTitle, role: .destructive) {
                    performOpener(opener)
                    pendingOpener = nil
                }
            }
            Button("Abbrechen", role: .cancel) {
                pendingOpener = nil
            }
        }
    }
}

private struct KioskAlarmPayload {
    let title: String
    let area: String
    let source: String
    let priority: Int
    let message: String
    let buttonText: String
    let acknowledgeEntityId: String

    init(userInfo: [AnyHashable: Any]) {
        title = Self.string("alarm_title", in: userInfo) ?? "ALARM"
        area = Self.string("alarm_area", in: userInfo) ?? "Unbekannter Bereich"
        source = Self.string("alarm_source", in: userInfo) ?? "Unbekannte Alarmquelle"
        priority = Self.integer("alarm_priority", in: userInfo) ?? 0
        message = Self.string("alarm_message", in: userInfo)
            ?? "Die akustische Alarmierung ist aktiv.\nBitte Ursache prüfen und anschließend den Alarm quittieren."
        buttonText = Self.string("alarm_button_text", in: userInfo) ?? "QUITTIEREN"
        acknowledgeEntityId = Self.string("ack_entity_id", in: userInfo) ?? "script.alarmansage_quittieren"
    }

    private static func string(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let homeassistant = userInfo["homeassistant"] as? [String: Any],
           let value = homeassistant[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let homeassistant = userInfo["homeassistant"] as? [AnyHashable: Any],
           let value = homeassistant[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    private static func integer(_ key: String, in userInfo: [AnyHashable: Any]) -> Int? {
        if let number = userInfo[key] as? NSNumber {
            return number.intValue
        }
        if let string = userInfo[key] as? String, let value = Int(string) {
            return value
        }
        if let homeassistant = userInfo["homeassistant"] as? [String: Any] {
            if let number = homeassistant[key] as? NSNumber {
                return number.intValue
            }
            if let string = homeassistant[key] as? String, let value = Int(string) {
                return value
            }
        }
        if let homeassistant = userInfo["homeassistant"] as? [AnyHashable: Any] {
            if let number = homeassistant[key] as? NSNumber {
                return number.intValue
            }
            if let string = homeassistant[key] as? String, let value = Int(string) {
                return value
            }
        }
        return nil
    }
}

private final class KioskAlarmOverlayPresenter {
    static let shared = KioskAlarmOverlayPresenter()

    private weak var overlayController: UIViewController?
    private var isTransitioning = false
    private var pendingShow: (() -> Void)?

    private init() {}

    func show(
        alarm: KioskAlarmPayload,
        server: Server,
        on webViewController: WebViewControllerProtocol
    ) {
        precondition(Thread.isMainThread)

        let present = { [weak self, weak webViewController] in
            guard let self, let webViewController else { return }
            self.present(alarm: alarm, server: server, on: webViewController)
        }

        if isTransitioning {
            pendingShow = present
            return
        }

        if webViewController.overlayedController != nil {
            isTransitioning = true
            pendingShow = present
            webViewController.dismissOverlayController(animated: false) { [weak self] in
                guard let self else { return }
                isTransitioning = false
                overlayController = nil
                let deferred = pendingShow
                pendingShow = nil
                deferred?()
            }
            return
        }

        present()
    }

    func hide(on webViewController: WebViewControllerProtocol) {
        precondition(Thread.isMainThread)

        guard let overlayController,
              webViewController.overlayedController === overlayController else {
            self.overlayController = nil
            Current.kiosk.setAlarmOverlayVisible(false)
            return
        }

        isTransitioning = true
        webViewController.dismissOverlayController(animated: true) { [weak self] in
            self?.overlayController = nil
            self?.isTransitioning = false
            Current.kiosk.setAlarmOverlayVisible(false)
        }
    }

    private func present(
        alarm: KioskAlarmPayload,
        server: Server,
        on webViewController: WebViewControllerProtocol
    ) {
        let controller = KioskAlarmView(
            alarm: alarm,
            acknowledge: { [weak self, weak webViewController] in
                guard let self, let webViewController else { return }
                self.acknowledge(alarm: alarm, server: server, on: webViewController)
            }
        )
        .embeddedInHostingController()

        controller.modalPresentationStyle = .overFullScreen
        overlayController = controller
        Current.kiosk.setAlarmOverlayVisible(true)
        webViewController.presentOverlayController(controller: controller, animated: true)

        Current.Log.info(
            "Kiosk alarm overlay shown: title=\(alarm.title), area=\(alarm.area), " +
                "source=\(alarm.source), priority=\(alarm.priority)"
        )
    }

    private func acknowledge(
        alarm: KioskAlarmPayload,
        server: Server,
        on webViewController: WebViewControllerProtocol
    ) {
        guard alarm.acknowledgeEntityId.hasPrefix("script.") else {
            Current.Log.error(
                "Kiosk alarm acknowledgement rejected: invalid script entity \(alarm.acknowledgeEntityId)"
            )
            return
        }

        guard let api = Current.api(for: server) else {
            Current.Log.error("Kiosk alarm acknowledgement failed: no API available")
            return
        }

        api.callServiceWithResponse(
            domain: "script",
            service: "turn_on",
            serviceData: ["entity_id": alarm.acknowledgeEntityId],
            returnResponse: false
        ).done { [weak self, weak webViewController] _ in
            DispatchQueue.main.async {
                guard let self, let webViewController else { return }
                Current.Log.info("Kiosk alarm acknowledged via \(alarm.acknowledgeEntityId)")
                self.hide(on: webViewController)
            }
        }.catch { error in
            Current.Log.error("Kiosk alarm acknowledgement failed: \(error)")
        }
    }
}

private struct KioskAlarmView: View {
    let alarm: KioskAlarmPayload
    let acknowledge: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(.red)

                Text(alarm.title)
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)

                VStack(spacing: 12) {
                    Text("Bereich: \(alarm.area)")
                    Text("Alarmquelle: \(alarm.source)")
                    if alarm.priority > 0 {
                        Text("Priorität: \(alarm.priority)")
                    }
                }
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

                Text(alarm.message)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 8)

                Button(action: acknowledge) {
                    Label(alarm.buttonText, systemImage: "checkmark.shield.fill")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .frame(maxWidth: 520)
                        .padding(.vertical, 22)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(.top, 12)
            }
            .padding(48)
            .frame(maxWidth: 900)
        }
        .interactiveDismissDisabled(true)
    }
}

extension NotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        let loggableCurrent = Current.settingsStore.pushID ?? "(null)"
        let loggableNew = fcmToken ?? "(null)"

        Current.Log.info("Firebase registration token refreshed, new token: \(loggableNew)")

        if loggableCurrent != loggableNew {
            Current.Log.warning("FCM token has changed from \(loggableCurrent) to \(loggableNew)")
        }

        Current.crashReporter.setUserProperty(value: fcmToken, name: "FCM Token")
        Current.settingsStore.pushID = fcmToken

        Current.backgroundTask(withName: BackgroundTask.notificationManagerDidReceiveRegistrationToken.rawValue) { _ in
            when(fulfilled: Current.apis.map { api in
                api.updateRegistration()
            })
        }.cauterize()
    }
}
