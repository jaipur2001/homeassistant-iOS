import Combine
import Foundation
import GRDB

public enum KioskScreensaverCommand: Equatable {
    case show
    case hide
}

/// Holds the live kiosk mode configuration for the running app.
///
/// The configuration is loaded from GRDB on creation and kept up to date through a
/// `ValueObservation`, so any change persisted by the settings UI is reflected here
/// (and in `Current.kioskSettings`) without manual refreshes.
public final class KioskModeManager: ObservableObject {
    public static let mandatorySensorIds: [WebhookSensorId] = [
        .kioskMode,
        .kioskBrightness,
        .kioskVolume,
        .kioskScreensaver,
        .cameraStream,
    ]

    public static func isMandatorySensor(uniqueID: String) -> Bool {
        mandatorySensorIds.contains { $0.rawValue == uniqueID }
    }

    @Published public private(set) var settings: KioskSettings
    @Published public private(set) var isCameraOverlayVisible = false
    @Published public private(set) var isAlarmOverlayVisible = false
    @Published public private(set) var isScreensaverVisible = false

    public var shouldKeepScreenOn: Bool {
        settings.enabled && settings.keepScreenOn
    }

    /// Emits the current configuration and every subsequent change, for observers outside this module.
    public var settingsPublisher: AnyPublisher<KioskSettings, Never> {
        $settings.eraseToAnyPublisher()
    }

    public var screensaverCommandPublisher: AnyPublisher<KioskScreensaverCommand, Never> {
        screensaverCommandSubject.eraseToAnyPublisher()
    }

    public var cameraOverlayVisiblePublisher: AnyPublisher<Bool, Never> {
        $isCameraOverlayVisible.eraseToAnyPublisher()
    }

    public var alarmOverlayVisiblePublisher: AnyPublisher<Bool, Never> {
        $isAlarmOverlayVisible.eraseToAnyPublisher()
    }

    /// Emits the current screensaver visibility and every subsequent change, so the kiosk screensaver
    /// sensor can report whether the screensaver is on screen.
    public var screensaverVisiblePublisher: AnyPublisher<Bool, Never> {
        $isScreensaverVisible.eraseToAnyPublisher()
    }

    public func requestScreensaver(_ command: KioskScreensaverCommand) {
        screensaverCommandSubject.send(command)
    }

    public func setScreensaverMode(_ mode: KioskScreensaverMode) {
        do {
            try Current.database().write { db in
                var settings = try KioskSettings.fetchOne(db) ?? KioskSettings()
                settings.screensaver.mode = mode
                try settings.insert(db, onConflict: .replace)
            }
        } catch {
            Current.Log.error("Failed to set kiosk screensaver mode: \(error)")
        }
    }

    public func setScreensaverDimLevel(_ level: Double) {
        do {
            try Current.database().write { db in
                var settings = try KioskSettings.fetchOne(db) ?? KioskSettings()
                settings.screensaver.dimLevel = min(max(level, 0), 1)
                try settings.insert(db, onConflict: .replace)
            }
        } catch {
            Current.Log.error("Failed to set kiosk screensaver dim level: \(error)")
        }
    }

    public func setCameraOverlayVisible(_ visible: Bool) {
        isCameraOverlayVisible = visible
    }

    public func setAlarmOverlayVisible(_ visible: Bool) {
        isAlarmOverlayVisible = visible
    }

    /// Called by the screensaver controller whenever the screensaver is shown or dismissed.
    public func setScreensaverVisible(_ visible: Bool) {
        isScreensaverVisible = visible
    }

    private let screensaverCommandSubject = PassthroughSubject<KioskScreensaverCommand, Never>()
    private var observation: AnyDatabaseCancellable?
    /// The kiosk `enabled` flag the sensor sync last saw, used to detect actual transitions.
    private var lastSyncedKioskEnabled: Bool

    public init() {
        let settings = (try? KioskSettings.current()) ?? KioskSettings()
        self.settings = settings
        self.lastSyncedKioskEnabled = settings.enabled
        observe()
    }

    private func observe() {
        let observation = ValueObservation.tracking { db in try KioskSettings.fetchOne(db) }
        self.observation = observation.start(
            in: Current.database(),
            onError: { error in
                Current.Log.error("Kiosk settings observation failed: \(error)")
            },
            onChange: { [weak self] settings in
                // ValueObservation notifies on the main queue by default.
                let settings = settings ?? KioskSettings()
                Current.Log.info("Kiosk settings changed, enabled: \(settings.enabled)")
                self?.settings = settings
                self?.enforceAuthenticationRequirement(with: settings)
                self?.syncKioskSensorsEnabled(with: settings)
            }
        )
    }

    /// Managed kiosk policy:
    /// - while kiosk mode is active, critical sensors are always enabled;
    /// - disabling kiosk keeps the historical behaviour for the kiosk-only
    ///   brightness/volume/screensaver sensors;
    /// - authentication is enforced separately below.
    private func syncKioskSensorsEnabled(with settings: KioskSettings) {
        let didTransition = settings.enabled != lastSyncedKioskEnabled
        lastSyncedKioskEnabled = settings.enabled

        if settings.enabled {
            for sensorId in Self.mandatorySensorIds {
                guard !Current.sensors.isEnabled(uniqueID: sensorId.rawValue) else { continue }
                Current.Log.warning(
                    "Managed kiosk policy: enabling mandatory sensor \(sensorId.rawValue)"
                )
                Current.sensors.setEnabled(true, forUniqueID: sensorId.rawValue)
            }
            return
        }

        guard didTransition else { return }

        for sensorId in [WebhookSensorId.kioskBrightness, .kioskVolume, .kioskScreensaver] {
            guard Current.sensors.isEnabled(uniqueID: sensorId.rawValue) else { continue }
            Current.sensors.setEnabled(false, forUniqueID: sensorId.rawValue)
        }
    }

    /// An enabled kiosk must never be left with an unprotected configuration
    /// entry point. Persist the hardened setting so every settings surface sees
    /// the same policy after the next database observation.
    private func enforceAuthenticationRequirement(with settings: KioskSettings) {
        guard settings.enabled, !settings.requireAuthentication else { return }

        do {
            try Current.database().write { db in
                var hardened = try KioskSettings.fetchOne(db) ?? settings
                guard hardened.enabled, !hardened.requireAuthentication else { return }
                hardened.requireAuthentication = true
                try hardened.insert(db, onConflict: .replace)
            }
            Current.Log.warning("Managed kiosk policy: administrator authentication enforced")
        } catch {
            Current.Log.error("Managed kiosk policy: failed to enforce authentication: \(error)")
        }
    }

}
