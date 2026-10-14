@testable import HomeAssistant
import SFSafeSymbols
@testable import Shared
import XCTest

final class KioskPushCommandTests: XCTestCase {
    func testParsesKnownCommands() {
        XCTAssertEqual(KioskPushCommand(message: "kiosk_show_screensaver"), .showScreensaver)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_hide_screensaver"), .hideScreensaver)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_show_camera"), .showCamera)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_hide_camera"), .hideCamera)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_set_brightness"), .setBrightness)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_set_volume"), .setVolume)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_show_alarm"), .showAlarm)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_hide_alarm"), .hideAlarm)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_set_screensaver_mode"), .setScreensaverMode)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_set_screensaver_brightness"), .setScreensaverBrightness)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_reload"), .reload)
        XCTAssertEqual(KioskPushCommand(message: "kiosk_default"), .defaultDashboard)
    }

    func testParsingTrimsWhitespaceAndIgnoresCase() {
        XCTAssertEqual(KioskPushCommand(message: "  KIOSK_Show_Screensaver \n"), .showScreensaver)
    }

    func testDoorbellCommandParsesMessageRoutingArgument() {
        XCTAssertEqual(
            KioskPushCommand(message: "kiosk_show_doorbell|station_haustuer"),
            .showDoorbell
        )
        XCTAssertEqual(
            KioskPushCommand.argument(from: "kiosk_show_doorbell|station_haustuer"),
            "station_haustuer"
        )
        XCTAssertEqual(
            KioskPushCommand.argument(from: "kiosk_show_doorbell|binary_sensor.klingel_haustuer"),
            "binary_sensor.klingel_haustuer"
        )
        XCTAssertEqual(
            KioskPushCommand.arguments(
                from: "kiosk_show_doorbell|station_haustuer|media-source://media_source/local/doorbell/doorbell.mp3"
            ),
            [
                "station_haustuer",
                "media-source://media_source/local/doorbell/doorbell.mp3",
            ]
        )
    }

    func testUnknownKioskTokenReturnsNil() {
        XCTAssertNil(KioskPushCommand(message: "kiosk_unknown_command"))
    }

    func testNonKioskMessageReturnsNil() {
        XCTAssertNil(KioskPushCommand(message: "Motion detected"))
    }

    func testIsKioskCommandDetectsPrefix() {
        XCTAssertTrue(KioskPushCommand.isKioskCommand(message: "kiosk_anything"))
        XCTAssertTrue(KioskPushCommand.isKioskCommand(message: "  KIOSK_x"))
        XCTAssertFalse(KioskPushCommand.isKioskCommand(message: "hello"))
    }

    func testRawValuesAreStableTokens() {
        XCTAssertEqual(KioskPushCommand.showScreensaver.rawValue, "kiosk_show_screensaver")
        XCTAssertEqual(KioskPushCommand.hideScreensaver.rawValue, "kiosk_hide_screensaver")
        XCTAssertEqual(KioskPushCommand.showCamera.rawValue, "kiosk_show_camera")
        XCTAssertEqual(KioskPushCommand.hideCamera.rawValue, "kiosk_hide_camera")
        XCTAssertEqual(KioskPushCommand.setBrightness.rawValue, "kiosk_set_brightness")
        XCTAssertEqual(KioskPushCommand.setVolume.rawValue, "kiosk_set_volume")
        XCTAssertEqual(KioskPushCommand.showAlarm.rawValue, "kiosk_show_alarm")
        XCTAssertEqual(KioskPushCommand.hideAlarm.rawValue, "kiosk_hide_alarm")
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.rawValue, "kiosk_set_screensaver_mode")
        XCTAssertEqual(KioskPushCommand.setScreensaverBrightness.rawValue, "kiosk_set_screensaver_brightness")
        XCTAssertEqual(KioskPushCommand.reload.rawValue, "kiosk_reload")
        XCTAssertEqual(KioskPushCommand.defaultDashboard.rawValue, "kiosk_default")
    }

    func testEveryCommandResolvesASymbol() {
        for command in KioskPushCommand.allCases {
            XCTAssertFalse(command.symbol.rawValue.isEmpty, "\(command) has no symbol")
        }
    }

    // MARK: - Confirmation toast

    @available(iOS 18, *)
    func testConfirmationToastCarriesTheCommandPresentation() throws {
        let command = KioskPushCommand.showScreensaver
        let toast = try XCTUnwrap(command.confirmationToast(id: "notification-1", settings: KioskSettings()))

        XCTAssertEqual(toast.id, "notification-1")
        XCTAssertEqual(toast.symbol, .moonStarsFill)
        XCTAssertEqual(toast.title, L10n.Kiosk.PushCommand.showScreensaver)
        XCTAssertEqual(toast.message, L10n.Kiosk.PushCommand.subtitle)
    }

    @available(iOS 18, *)
    func testEveryCommandConfirmsItselfByDefault() {
        // Confirmations default to on, so an untouched kiosk keeps the feedback it always had.
        for command in KioskPushCommand.allCases {
            XCTAssertNotNil(
                command.confirmationToast(id: "notification-1", settings: KioskSettings()),
                "\(command) has no confirmation toast"
            )
        }
    }

    @available(iOS 18, *)
    func testNoConfirmationToastWhenConfirmationsAreDisabled() {
        // The command still runs; it just does so without anything appearing on screen.
        let settings = KioskSettings(showRemoteCommandConfirmations: false)
        for command in KioskPushCommand.allCases {
            XCTAssertNil(command.confirmationToast(id: "notification-1", settings: settings))
        }
    }

    // MARK: - Payload level parsing

    func testOnlyLevelCommandsHaveLevelKey() {
        XCTAssertEqual(KioskPushCommand.setBrightness.levelKey, "level")
        XCTAssertEqual(KioskPushCommand.setVolume.levelKey, "volume")
        XCTAssertEqual(KioskPushCommand.setScreensaverBrightness.levelKey, "level")
        XCTAssertNil(KioskPushCommand.showScreensaver.levelKey)
        XCTAssertNil(KioskPushCommand.hideScreensaver.levelKey)
        XCTAssertNil(KioskPushCommand.showCamera.levelKey)
        XCTAssertNil(KioskPushCommand.hideCamera.levelKey)
        XCTAssertNil(KioskPushCommand.setScreensaverMode.levelKey)
    }

    func testScreensaverBrightnessParsesLevel() {
        XCTAssertEqual(
            KioskPushCommand.setScreensaverBrightness.level(from: ["level": 20]) ?? .nan,
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            KioskPushCommand.setScreensaverBrightness.level(from: ["level": 0.35]) ?? .nan,
            0.35,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            KioskPushCommand.setScreensaverBrightness.level(from: ["homeassistant": ["level": "80"]]) ?? .nan,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertNil(KioskPushCommand.setScreensaverBrightness.level(from: [:]))
    }

    func testLevelParsesFraction() {
        XCTAssertEqual(KioskPushCommand.setBrightness.level(from: ["level": 0.5]) ?? .nan, 0.5, accuracy: 0.0001)
        XCTAssertEqual(KioskPushCommand.setVolume.level(from: ["volume": 0.25]) ?? .nan, 0.25, accuracy: 0.0001)
    }

    func testLevelParsesPercentage() {
        XCTAssertEqual(KioskPushCommand.setBrightness.level(from: ["level": 75]) ?? .nan, 0.75, accuracy: 0.0001)
        XCTAssertEqual(KioskPushCommand.setVolume.level(from: ["volume": 100]) ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testLevelParsesNumericString() {
        XCTAssertEqual(KioskPushCommand.setBrightness.level(from: ["level": "0.4"]) ?? .nan, 0.4, accuracy: 0.0001)
        XCTAssertEqual(KioskPushCommand.setVolume.level(from: ["volume": "60"]) ?? .nan, 0.6, accuracy: 0.0001)
    }

    func testLevelReadsNestedHomeassistantPayload() {
        XCTAssertEqual(
            KioskPushCommand.setBrightness.level(from: ["homeassistant": ["level": 30]]) ?? .nan,
            0.3,
            accuracy: 0.0001
        )
    }

    func testLevelClampsOutOfRangeValues() {
        XCTAssertEqual(KioskPushCommand.setBrightness.level(from: ["level": 150]) ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(KioskPushCommand.setVolume.level(from: ["volume": -10]) ?? .nan, 0.0, accuracy: 0.0001)
    }

    func testLevelReturnsNilWhenMissingOrInvalid() {
        XCTAssertNil(KioskPushCommand.setBrightness.level(from: [:]))
        XCTAssertNil(KioskPushCommand.setBrightness.level(from: ["level": "loud"]))
        XCTAssertNil(KioskPushCommand.setVolume.level(from: ["level": 0.5]))
    }

    func testLevelReturnsNilForValuelessCommands() {
        XCTAssertNil(KioskPushCommand.showScreensaver.level(from: ["level": 0.5]))
        XCTAssertNil(KioskPushCommand.hideCamera.level(from: ["volume": 0.5]))
    }

    // MARK: - Payload screensaver mode parsing

    func testOnlyModeCommandHasModeKey() {
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.modeKey, "mode")
        XCTAssertNil(KioskPushCommand.showScreensaver.modeKey)
        XCTAssertNil(KioskPushCommand.setBrightness.modeKey)
        XCTAssertNil(KioskPushCommand.setScreensaverBrightness.modeKey)
    }

    func testModeParsesKnownModes() {
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "clock"]), .clock)
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "dim"]), .dim)
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "blank"]), .blank)
    }

    func testModeTrimsWhitespaceAndIgnoresCase() {
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "  Clock \n"]), .clock)
        XCTAssertEqual(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "DIM"]), .dim)
    }

    func testModeReadsNestedHomeassistantPayload() {
        XCTAssertEqual(
            KioskPushCommand.setScreensaverMode.screensaverMode(from: ["homeassistant": ["mode": "blank"]]),
            .blank
        )
    }

    func testModeReturnsNilWhenMissingOrInvalid() {
        XCTAssertNil(KioskPushCommand.setScreensaverMode.screensaverMode(from: [:]))
        XCTAssertNil(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": "off"]))
        XCTAssertNil(KioskPushCommand.setScreensaverMode.screensaverMode(from: ["mode": 3]))
    }

    func testModeReturnsNilForNonModeCommands() {
        XCTAssertNil(KioskPushCommand.showScreensaver.screensaverMode(from: ["mode": "clock"]))
        XCTAssertNil(KioskPushCommand.setBrightness.screensaverMode(from: ["mode": "clock"]))
    }

    // MARK: - Doorbell payload routing

    func testDoorbellPayloadUsesRoutedTriggerEntity() {
        let payload = KioskDoorbellPayload(
            userInfo: ["homeassistant": ["station_id": "haustuer"]],
            message: "kiosk_show_doorbell|binary_sensor.klingel_haustuer"
        )

        XCTAssertEqual(payload.stationId, "haustuer")
        XCTAssertEqual(payload.triggerEntityId, "binary_sensor.klingel_haustuer")
        XCTAssertTrue(payload.diagnosticSummary.contains("message_route=binary_sensor.klingel_haustuer"))
    }

    func testDoorbellPayloadUsesRoutedStationAndNestedTrigger() {
        let payload = KioskDoorbellPayload(
            userInfo: ["homeassistant": ["data": ["trigger_entity_id": "binary_sensor.klingel_haustuer"]]],
            message: "kiosk_show_doorbell|station_haustuer"
        )

        XCTAssertEqual(payload.stationId, "station_haustuer")
        XCTAssertEqual(payload.triggerEntityId, "binary_sensor.klingel_haustuer")
    }

    func testDoorbellPayloadFindsFieldsInsideGenericWrapper() {
        let payload = KioskDoorbellPayload(userInfo: [
            "notification": [
                "data": [
                    "station": "  station_haustuer  ",
                    "doorbell_entity_id": "binary_sensor.klingel_haustuer",
                ],
            ],
        ])

        XCTAssertEqual(payload.stationId, "station_haustuer")
        XCTAssertEqual(payload.triggerEntityId, "binary_sensor.klingel_haustuer")
    }

    func testDoorbellPayloadPrefersHomeAssistantContainerOverUnrelatedFields() {
        let payload = KioskDoorbellPayload(userInfo: [
            "other": ["station": "station_wrong"],
            "homeassistant": ["station": "station_haustuer"],
        ])

        XCTAssertEqual(payload.stationId, "station_haustuer")
    }

    func testDoorbellPayloadKeepsMissingRoutingFieldsNil() {
        let payload = KioskDoorbellPayload(userInfo: ["aps": ["alert": "Doorbell"]])

        XCTAssertNil(payload.stationId)
        XCTAssertNil(payload.triggerEntityId)
        XCTAssertTrue(payload.diagnosticSummary.contains("keys=[aps]"))
    }

    // MARK: - Alarm push payload

    func testAlarmPayloadUsesDefaultsWhenMissing() {
        let payload = KioskAlarmPayload(userInfo: [:])

        XCTAssertEqual(payload.title, "ALARM")
        XCTAssertEqual(payload.area, "Unbekannter Bereich")
        XCTAssertEqual(payload.source, "Unbekannte Alarmquelle")
        XCTAssertEqual(payload.priority, 0)
        XCTAssertEqual(payload.buttonText, "QUITTIEREN")
        XCTAssertEqual(payload.acknowledgeEntityId, "script.alarmansage_quittieren")
        XCTAssertTrue(payload.message.contains("Alarmierung"))
    }

    func testAlarmPayloadReadsRootValuesAndNumericPriority() {
        let payload = KioskAlarmPayload(userInfo: [
            "alarm_title": "Einbruch",
            "alarm_area": "Garage",
            "alarm_source": "Fenster",
            "alarm_priority": 5,
            "alarm_message": "Fenster geöffnet",
            "alarm_button_text": "Bestätigen",
            "ack_entity_id": "script.alarm_ack",
        ])

        XCTAssertEqual(payload.title, "Einbruch")
        XCTAssertEqual(payload.area, "Garage")
        XCTAssertEqual(payload.source, "Fenster")
        XCTAssertEqual(payload.priority, 5)
        XCTAssertEqual(payload.message, "Fenster geöffnet")
        XCTAssertEqual(payload.buttonText, "Bestätigen")
        XCTAssertEqual(payload.acknowledgeEntityId, "script.alarm_ack")
    }

    func testAlarmPayloadReadsNestedHomeAssistantValues() {
        let payload = KioskAlarmPayload(userInfo: [
            "homeassistant": [
                "alarm_title": "Tamper",
                "alarm_priority": "7",
                "alarm_area": "Haustür",
                "ack_entity_id": "script.quittieren",
            ],
        ])

        XCTAssertEqual(payload.title, "Tamper")
        XCTAssertEqual(payload.area, "Haustür")
        XCTAssertEqual(payload.priority, 7)
        XCTAssertEqual(payload.acknowledgeEntityId, "script.quittieren")
    }

    func testAlarmPayloadIgnoresEmptyStringsAndInvalidPriority() {
        let payload = KioskAlarmPayload(userInfo: [
            "alarm_title": " ",
            "alarm_priority": "invalid",
            "alarm_message": "",
        ])

        XCTAssertEqual(payload.title, "ALARM")
        XCTAssertEqual(payload.priority, 0)
        XCTAssertTrue(payload.message.contains("Alarmierung"))
    }

    func testAlarmPayloadRootValuesWinOverNestedValues() {
        let payload = KioskAlarmPayload(userInfo: [
            "alarm_title": "Root",
            "alarm_priority": "3",
            "homeassistant": [
                "alarm_title": "Nested",
                "alarm_priority": 8,
            ],
        ])

        XCTAssertEqual(payload.title, "Root")
        XCTAssertEqual(payload.priority, 3)
    }

    // MARK: - Doorbell station registry

    private func stationEntity(
        _ entityId: String,
        labels: [String]? = nil,
        deviceId: String? = nil,
        name: String? = nil
    ) -> EntityRegistryListForDisplay.Entity {
        EntityRegistryListForDisplay.Entity(
            entityId: entityId,
            labels: labels,
            deviceId: deviceId,
            name: name
        )
    }

    private func resolveStation(
        entities: [EntityRegistryListForDisplay.Entity],
        userInfo: [AnyHashable: Any] = [:],
        message: String? = nil,
        deviceLabelsById: [String: Set<String>] = [:]
    ) throws -> KioskDoorbellStation {
        try KioskDoorbellStationResolver.resolve(
            userInfo: userInfo,
            message: message,
            entities: entities,
            deviceLabelsById: deviceLabelsById
        )
    }

    func testDoorbellStationResolvesTriggerAndInheritedDeviceLabels() throws {
        let entities = [
            stationEntity(
                "binary_sensor.klingel_haustuer",
                labels: ["station_haustuer", "function_doorbell"],
                name: "Haustür"
            ),
            stationEntity("camera.house_entrance", deviceId: "camera-device"),
            stationEntity("switch.intercom_marker", labels: ["station_haustuer", "function_intercom"]),
            stationEntity(
                "input_number.haustuer_timeout",
                labels: ["station_haustuer", "function_doorbell_timeout"]
            ),
        ]

        let station = try resolveStation(
            entities: entities,
            message: "kiosk_show_doorbell|binary_sensor.klingel_haustuer",
            deviceLabelsById: ["camera-device": ["station_haustuer", "function_camera"]]
        )

        XCTAssertEqual(station.id, "station_haustuer")
        XCTAssertEqual(station.name, "Haustür")
        XCTAssertEqual(station.cameraEntityId, "camera.house_entrance")
        XCTAssertEqual(station.triggerEntityId, "binary_sensor.klingel_haustuer")
        XCTAssertEqual(station.intercomTargetEntityId, "camera.house_entrance")
        XCTAssertEqual(station.timeoutEntityId, "input_number.haustuer_timeout")
    }

    func testDoorbellStationFallsBackToSingleStationAndGlobalTimeout() throws {
        let entities = [
            stationEntity("camera.house_entrance", labels: ["station_haustuer", "function_camera"]),
            stationEntity(
                "binary_sensor.front_door",
                labels: ["station_haustuer", "function_doorbell"],
                name: " "
            ),
            stationEntity("input_number.haustuer_timeout", labels: ["function_doorbell_timeout"]),
        ]

        let station = try resolveStation(entities: entities)

        XCTAssertEqual(station.id, "station_haustuer")
        XCTAssertEqual(station.name, "Haustuer")
        XCTAssertEqual(station.triggerEntityId, "binary_sensor.front_door")
        XCTAssertEqual(station.timeoutEntityId, "input_number.haustuer_timeout")
        XCTAssertNil(station.intercomTargetEntityId)
    }

    func testDoorbellStationHonorsExplicitRouteAndLocalTimeout() throws {
        let entities = [
            stationEntity("camera.house", labels: ["station_haus_tuer", "function_camera"]),
            stationEntity(
                "input_number.local_timeout",
                labels: ["station_haus_tuer", "function_doorbell_timeout"]
            ),
            stationEntity("input_number.global_timeout", labels: ["function_doorbell_timeout"]),
        ]

        let station = try resolveStation(
            entities: entities,
            userInfo: ["station_id": "  Haus Tuer  "]
        )

        XCTAssertEqual(station.id, "station_haus_tuer")
        XCTAssertEqual(station.name, "Haus Tuer")
        XCTAssertEqual(station.timeoutEntityId, "input_number.local_timeout")
    }

    func testDoorbellStationOpenersHaveCorrectServicesAndSymbols() throws {
        let entities = [
            stationEntity("camera.entrance", labels: ["station_haustuer", "function_camera"]),
            stationEntity("script.open_door", labels: ["station_haustuer", "function_opener", "type_door"]),
            stationEntity("cover.open_gate", labels: ["station_haustuer", "function_opener", "type_gate"]),
            stationEntity("button.latch", labels: ["station_haustuer", "function_opener"], name: "Latch"),
            stationEntity("sensor.invalid_opener", labels: ["station_haustuer", "function_opener"]),
        ]

        let station = try resolveStation(
            entities: entities,
            userInfo: ["station": "haustuer"]
        )

        XCTAssertEqual(station.openers.count, 3)
        XCTAssertEqual(station.openers[0].serviceDomain, "script")
        XCTAssertEqual(station.openers[0].service, "turn_on")
        XCTAssertEqual(station.openers[0].buttonTitle, "Tür öffnen")
        XCTAssertEqual(station.openers[0].systemSymbol, .lockOpenFill)
        XCTAssertEqual(station.openers[1].serviceDomain, "cover")
        XCTAssertEqual(station.openers[1].service, "open_cover")
        XCTAssertEqual(station.openers[1].buttonTitle, "Tor öffnen")
        XCTAssertEqual(station.openers[1].systemSymbol, .doorGarageOpen)
        XCTAssertEqual(station.openers[2].serviceDomain, "button")
        XCTAssertEqual(station.openers[2].service, "press")
        XCTAssertEqual(station.openers[2].buttonTitle, "Latch")
        XCTAssertEqual(station.openers[2].systemSymbol, .lockOpen)
    }

    func testDoorbellStationRejectsUnknownTrigger() {
        XCTAssertThrowsError(try resolveStation(
            entities: [
                stationEntity("camera.entrance", labels: ["station_haustuer", "function_camera"]),
            ],
            message: "kiosk_show_doorbell|binary_sensor.unknown"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("binary_sensor.unknown"))
        }
    }

    func testDoorbellStationRejectsUnlabelledTrigger() {
        XCTAssertThrowsError(try resolveStation(
            entities: [
                stationEntity("binary_sensor.klingel_haustuer", labels: ["function_doorbell"]),
                stationEntity("camera.entrance", labels: ["station_haustuer", "function_camera"]),
            ],
            message: "kiosk_show_doorbell|binary_sensor.klingel_haustuer"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("no station_* label"))
        }
    }

    func testDoorbellStationRejectsAmbiguousFallback() {
        XCTAssertThrowsError(try resolveStation(entities: [
            stationEntity("binary_sensor.door1", labels: ["station_haustuer", "function_doorbell"]),
            stationEntity("binary_sensor.door2", labels: ["station_gartentor", "function_doorbell"]),
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("No station routing found"))
        }
    }

    func testDoorbellStationRejectsMissingCamera() {
        XCTAssertThrowsError(try resolveStation(
            entities: [
                stationEntity("binary_sensor.door", labels: ["station_haustuer", "function_doorbell"]),
            ],
            userInfo: ["station": "haustuer"]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("has no camera"))
        }
    }

    func testDoorbellStationRejectsMissingStationEntities() {
        XCTAssertThrowsError(try resolveStation(
            entities: [],
            userInfo: ["station_id": "haustuer"]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("No entities found"))
        }
    }
}
