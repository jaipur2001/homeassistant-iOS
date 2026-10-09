import Foundation
import PromiseKit

#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
#endif

final class CameraStreamSensorUpdateSignaler: BaseSensorUpdateSignaler, SensorProviderUpdateSignaler {
    let signal: () -> Void

    init(signal: @escaping () -> Void) {
        self.signal = signal
        super.init(relatedSensorsIds: [
            .cameraStream,
        ])
    }

    override func observe() {
        super.observe()
        guard !isObserving else { return }
        // Enabling the sensor turns the stream server on: the listener starts and
        // the camera runs continuously (foreground only) so the stream is instantly
        // available to clients.
        Current.cameraStreamServer.onStateChange = { [weak self] in
            self?.signal()
        }
        Current.cameraStreamServer.setActive(true)
        isObserving = true
    }

    override func stopObserving() {
        super.stopObserving()
        guard isObserving else { return }
        Current.cameraStreamServer.onStateChange = nil
        Current.cameraStreamServer.setActive(false)
        isObserving = false
    }
}

/// Exposes the MJPEG camera stream server as a sensor: enabling it starts the server
/// (and the camera), the state reports whether a client is currently pulling the
/// stream. Consumed in Home Assistant through the MJPEG camera integration pointed
/// at `http://<device-ip>:<port>/camera`. iOS/iPadOS only.
final class CameraStreamSensor: SensorProvider {
    public enum CameraStreamError: Error, Equatable {
        case unavailable
    }

    let request: SensorProviderRequest
    init(request: SensorProviderRequest) {
        self.request = request
    }

    func sensors() -> Promise<[WebhookSensor]> {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard Current.motionDetection.canDetectMotion else {
            return .init(error: CameraStreamError.unavailable)
        }

        let server = Current.cameraStreamServer
        let isStreaming = server.isStreaming

        let sensor = WebhookSensor(
            name: "Camera Stream",
            uniqueID: WebhookSensorId.cameraStream.rawValue,
            icon: isStreaming ? "mdi:cctv" : "mdi:cctv-off",
            state: isStreaming ? "streaming" : "idle"
        )
        let rtspServer = Current.cameraRTSPServer
        let motionDetection = Current.motionDetection
        let audioSession = AVAudioSession.sharedInstance()
        let lastFrameDate = motionDetection.debugLastCapturedFrameDate
        let lastFrameAge = motionDetection.debugLastCapturedFrameAge
        let audioOutputs = audioSession.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ", ")

        sensor.Attributes = [
            "Port": server.port,
            "Clients": server.clientCount,
            "Stream URL": server.streamURL ?? "unavailable (no Wi-Fi address)",
            "RTSP Port": rtspServer.port,
            "RTSP Clients": rtspServer.clientCount,
            "RTSP URL": rtspServer.streamURL ?? "unavailable (no Wi-Fi address)",

            // Read-only diagnostics. These are intentionally attributes of the
            // existing Camera Stream sensor so debugging does not add another
            // lifecycle owner or alter the stable camera/audio behavior.
            "Debug App Foreground": Current.isForegroundApp(),
            "Debug Sensor Enabled": Current.sensors.isEnabled(
                uniqueID: WebhookSensorId.cameraStream.rawValue
            ),
            "Debug Capture Configured": motionDetection.debugCaptureSessionConfigured,
            "Debug Capture Running": motionDetection.debugCaptureSessionRunning,
            "Debug Captured Frames": motionDetection.debugCapturedFrameCount,
            "Debug Last Frame": lastFrameDate.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "never",
            "Debug Last Frame Age (s)": lastFrameAge.map {
                (100 * $0).rounded() / 100
            } ?? -1,
            "Debug MJPEG Active": server.isActive,
            "Debug MJPEG Listener": server.debugListenerRunning,
            "Debug MJPEG Camera Observer": server.debugObservingCamera,
            "Debug MJPEG Encoding": server.debugEncodingFrame,
            "Debug RTSP Active": rtspServer.isActive,
            "Debug RTSP Listener": rtspServer.debugListenerRunning,
            "Debug RTSP Encoder": rtspServer.debugEncoderRunning,
            "Debug RTSP Playing Clients": rtspServer.debugPlayingClientCount,
            "Debug RTSP Sending Clients": rtspServer.debugSendingClientCount,
            "Debug RTSP Send Watchdog Disconnects": rtspServer.debugStalledSendDisconnects,
            "Debug Audio Category": audioSession.category.rawValue,
            "Debug Audio Mode": audioSession.mode.rawValue,
            "Debug Audio Volume": audioSession.outputVolume,
            "Debug Audio Outputs": audioOutputs.isEmpty ? "none" : audioOutputs,
        ]
        sensor.detailFooter = L10n.Sensors.CameraStream.detailFooter

        sensor.Settings = [
            .init(
                type: .slider(
                    getter: { server.streamFrameRate },
                    setter: { server.streamFrameRate = $0 },
                    minimum: 1,
                    maximum: 30,
                    step: 1,
                    displayValueFor: { value in
                        value.map { String(format: "%.0f fps", $0) }
                    }
                ),
                title: L10n.Sensors.CameraStream.Setting.frameRate,
                subtitle: L10n.Sensors.Camera.frameRateWarning
            ),
            .init(
                type: .numericField(
                    getter: { Double(server.port) },
                    setter: { server.port = Int($0) },
                    minimum: 1024,
                    maximum: 65535
                ),
                title: L10n.Sensors.CameraStream.Setting.streamPort
            ),
            .init(
                type: .credentials(fields: [
                    .init(
                        title: L10n.Sensors.CameraStream.Setting.username,
                        placeholder: L10n.Sensors.CameraStream.Setting.credentialsPlaceholder,
                        getter: { server.username },
                        setter: { server.username = $0 }
                    ),
                    .init(
                        title: L10n.Sensors.CameraStream.Setting.password,
                        placeholder: L10n.Sensors.CameraStream.Setting.credentialsPlaceholder,
                        isSecure: true,
                        getter: { server.password },
                        setter: { server.password = $0 }
                    ),
                ]),
                title: L10n.Sensors.CameraStream.Setting.username,
                subtitle: L10n.Sensors.CameraStream.Setting.credentialsFooter
            ),
        ]

        // Set up our observer (starts/stops the server with sensor enablement)
        let _: CameraStreamSensorUpdateSignaler = request.dependencies.updateSignaler(for: self)

        return .value([sensor])
        #else
        return .init(error: CameraStreamError.unavailable)
        #endif
    }
}
