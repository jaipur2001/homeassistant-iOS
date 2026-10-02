import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreImage
import CoreVideo
import KeychainAccess
import Network
import VideoToolbox

/// Serves the front camera frames captured by `MotionDetectionManager` as an MJPEG
/// HTTP stream (`multipart/x-mixed-replace`), consumable by Home Assistant's MJPEG
/// camera integration at `http://<device-ip>:<port>/`.
///
/// Activation is driven by the "Camera Stream" sensor's enabled state: while active,
/// the listener runs and the camera capture session is kept alive continuously (not
/// only while clients are connected), so the stream is instantly available. Like all
/// camera capture, this only works while the app is in the foreground.
public class CameraStreamServer {
    private enum UserDefaultsKeys: String {
        case port = "camera_stream_port"
        case frameRate = "camera_stream_frame_rate"
        case username = "camera_stream_username"
    }

    private static let passwordKeychainKey = "camera_stream_password"
    private static let authRealm = "Home Assistant Camera"

    private static let boundary = "hacameraframe"

    /// Encoding in a plain SDR color space stops Core Image from trying (and failing,
    /// noisily) to build an HDR gain map for the JPEG when the camera delivers
    /// wide-gamut buffers.
    private static let sdrColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let keychain = AppConstants.Keychain
    private let queue = DispatchQueue(label: "camera-stream-server")
    private let encodingQueue = DispatchQueue(label: "camera-stream-encoding")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// State below is owned by `queue`. It prevents an unbounded backlog when
    /// JPEG encoding or a client socket is slower than the camera capture rate.
    private var isEncodingFrame = false
    private var sendingConnections: Set<ObjectIdentifier> = []
    private var active = false
    private var isObservingCamera = false
    private lazy var ciContext = CIContext(options: [.workingColorSpace: Self.sdrColorSpace])

    /// Called (on the main queue) whenever the streaming state changes, so the
    /// Camera Stream sensor can push an update.
    public var onStateChange: (() -> Void)?

    public init() {}

    // MARK: - State

    public var isActive: Bool {
        queue.sync { active }
    }

    public var isStreaming: Bool {
        queue.sync { !connections.isEmpty }
    }

    public var clientCount: Int {
        queue.sync { connections.count }
    }

    /// The URL clients should use to consume the stream, based on the Wi-Fi
    /// interface address. `nil` when the device has no Wi-Fi IPv4 address.
    /// The `/camera` path is canonical/advertised; the server accepts any path.
    public var streamURL: String? {
        guard let address = Self.localIPAddress() else { return nil }
        return "http://\(address):\(port)/camera"
    }

    /// IPv4 address of the Wi-Fi interface (`en0`), if any.
    fileprivate static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let ifaAddr = interface.ifa_addr,
                  ifaAddr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else {
                continue
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                ifaAddr,
                socklen_t(ifaAddr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                address = String(cString: hostname)
            }
        }
        return address
    }

    // MARK: - Persisted settings

    public var port: Int {
        get {
            let prefs = Current.settingsStore.prefs
            guard prefs.object(forKey: UserDefaultsKeys.port.rawValue) != nil else { return 8090 }
            return prefs.integer(forKey: UserDefaultsKeys.port.rawValue)
        }
        set {
            Current.settingsStore.prefs.set(newValue, forKey: UserDefaultsKeys.port.rawValue)
            queue.async { [weak self] in
                guard let self, active else { return }
                stopListener()
                // Restart on the new port after a beat, giving the cancelled listener
                // time to release its socket.
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, active else { return }
                    startListener()
                    notifyStateChange()
                    Current.Log.info("Camera stream: restarted on port \(port)")
                }
            }
        }
    }

    /// Desired stream frame rate in frames per second. The shared capture session
    /// runs at the highest rate any active consumer needs, so this only raises the
    /// capture rate while the server is active.
    public var streamFrameRate: Double {
        get {
            let prefs = Current.settingsStore.prefs
            guard prefs.object(forKey: UserDefaultsKeys.frameRate.rawValue) != nil else { return 15.0 }
            return prefs.double(forKey: UserDefaultsKeys.frameRate.rawValue)
        }
        set {
            Current.settingsStore.prefs.set(newValue, forKey: UserDefaultsKeys.frameRate.rawValue)
            Current.motionDetection.refreshFrameRate()
        }
    }

    /// Optional HTTP Basic auth credentials. When both are empty the stream is open
    /// to anyone on the network; setting either requires clients to authenticate.
    /// The password is kept in the Keychain rather than UserDefaults.
    public var username: String {
        get { Current.settingsStore.prefs.string(forKey: UserDefaultsKeys.username.rawValue) ?? "" }
        set { Current.settingsStore.prefs.set(newValue, forKey: UserDefaultsKeys.username.rawValue) }
    }

    public var password: String {
        get { keychain[Self.passwordKeychainKey] ?? "" }
        set { keychain[Self.passwordKeychainKey] = newValue.isEmpty ? nil : newValue }
    }

    // MARK: - Activation

    /// Turns the stream server on or off. While on, the listener accepts clients and
    /// the camera runs continuously (foreground only).
    public func setActive(_ newValue: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            let changed = active != newValue
            active = newValue

            if newValue {
                // Reconcile every time instead of treating repeated activation as
                // a no-op. Sensor refreshes can therefore restore a missing listener
                // or capture session without stopping a healthy stream first.
                startListener()
                ensureCameraObservation()
                Current.motionDetection.ensureRunning()
            } else {
                stopListener()
                updateCameraObservation()
            }

            // Keep the H.264/RTSP transport coupled to the same enabled Camera Stream
            // sensor while the new path is evaluated. MJPEG remains available in parallel.
            Current.cameraRTSPServer.setActive(newValue)

            if changed {
                notifyStateChange()
            }

            // The capture rate depends on which consumers are active.
            Current.motionDetection.refreshFrameRate()
        }
    }

    private func startListener() {
        guard listener == nil else { return }
        let portValue = UInt16(min(max(port, 1024), 65535))
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else { return }

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.setup(connection: connection)
                }
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    Current.Log.error("Camera stream: listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            Current.Log.info("Camera stream: listening on port \(portValue)")
        } catch {
            Current.Log.error("Camera stream: failed to start listener: \(error)")
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        sendingConnections.removeAll()
        isEncodingFrame = false
    }

    // MARK: - Connections

    private func setup(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.remove(connection: connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    /// Reads the HTTP request, accumulating chunks until the full header block arrives.
    /// Clients (e.g. Home Assistant's aiohttp-based MJPEG integration) may deliver the
    /// request line and headers in separate TCP segments, so a single read can miss the
    /// `Authorization` header.
    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                Current.Log.error("Camera stream: receive failed: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            let request = String(decoding: buffer, as: UTF8.self)
            guard request.contains("\r\n\r\n") || isComplete || buffer.count >= 16384 else {
                receiveRequest(on: connection, accumulated: buffer)
                return
            }

            respond(to: connection, request: request)
        }
    }

    private func respond(to connection: NWConnection, request: String) {
        guard Self.isAuthorized(request: request, username: username, password: password) else {
            let parsed = Self.basicAuthCredentials(fromRequest: request)
            let lines = request.split(whereSeparator: \.isNewline)
            let requestLine = lines.first.map(String.init) ?? "(none)"
            let headerNames = lines.dropFirst().compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            }
            Current.Log.error(
                "Camera stream: auth rejected — request: \"\(requestLine)\", "
                    + "headers: [\(headerNames.joined(separator: ", "))], authHeader: \(parsed != nil), "
                    + "userMatch: \(parsed?.username == username), passMatch: \(parsed?.password == password), "
                    + "configuredUserEmpty: \(username.isEmpty), configuredPassEmpty: \(password.isEmpty)"
            )
            sendUnauthorized(on: connection)
            return
        }

        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)",
            "Cache-Control: no-cache",
            "",
            "",
        ].joined(separator: "\r\n")

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            queue.async {
                if error == nil {
                    self.connections[ObjectIdentifier(connection)] = connection
                    Current.Log.info("Camera stream: client connected (\(self.connections.count) total)")
                    self.notifyStateChange()
                } else {
                    connection.cancel()
                }
            }
        })
    }

    private func remove(connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        sendingConnections.remove(identifier)
        guard connections.removeValue(forKey: identifier) != nil else { return }
        Current.Log.info("Camera stream: client disconnected (\(connections.count) left)")
        notifyStateChange()
    }

    // MARK: - Authentication

    /// Whether the request satisfies the configured credentials. With no username and
    /// no password set, every request is allowed.
    static func isAuthorized(request: String, username: String, password: String) -> Bool {
        guard !username.isEmpty || !password.isEmpty else { return true }
        guard let credentials = basicAuthCredentials(fromRequest: request) else { return false }
        return credentials.username == username && credentials.password == password
    }

    /// Extracts `(username, password)` from an `Authorization: Basic <base64>` header
    /// in the raw HTTP request, or `nil` when absent or malformed.
    static func basicAuthCredentials(fromRequest request: String) -> (username: String, password: String)? {
        // Note: split on Character.isNewline, not on "\r"/"\n" — Swift treats CRLF
        // as a single Character, so comparing against lone "\r" or "\n" never
        // matches the CRLF line breaks in an HTTP request.
        for line in request.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { continue }

            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let scheme = "Basic "
            guard value.count > scheme.count, value.lowercased().hasPrefix(scheme.lowercased()) else { return nil }

            let encoded = value.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
            guard let decodedData = Data(base64Encoded: encoded),
                  let decoded = String(data: decodedData, encoding: .utf8),
                  let separator = decoded.firstIndex(of: ":") else {
                return nil
            }
            return (String(decoded[..<separator]), String(decoded[decoded.index(after: separator)...]))
        }
        return nil
    }

    private func sendUnauthorized(on connection: NWConnection) {
        let response = [
            "HTTP/1.1 401 Unauthorized",
            "WWW-Authenticate: Basic realm=\"\(Self.authRealm)\"",
            "Content-Length: 0",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func notifyStateChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }

    /// While active, hold a camera observation so the shared capture session runs
    /// continuously and the stream is instantly available to clients.
    private func updateCameraObservation() {
        let shouldObserve = active
        guard shouldObserve != isObservingCamera else { return }
        isObservingCamera = shouldObserve
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldObserve {
                Current.motionDetection.register(observer: self)
            } else {
                Current.motionDetection.unregister(observer: self)
            }
        }
    }

    /// Ensures this server still owns a capture observation. Registering the same
    /// weak observer repeatedly is harmless, and repairs the relationship if the
    /// sensor lifecycle was rebuilt while `active` stayed true.
    private func ensureCameraObservation() {
        isObservingCamera = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Current.motionDetection.register(observer: self)
            Current.motionDetection.ensureRunning()
        }
    }

    // MARK: - Frames

    /// Called by `MotionDetectionManager` with every captured frame (on its
    /// processing queue). At most one frame is queued for JPEG encoding at a time.
    /// If encoding is still busy, newer capture frames are dropped instead of
    /// accumulating an ever-growing backlog.
    ///
    /// Each client may likewise have at most one outstanding socket send. Slow or
    /// stalled clients therefore cannot queue an unlimited number of MJPEG frames.
    public func handle(frame: CVPixelBuffer) {
        let shouldEncode = queue.sync { () -> Bool in
            guard !connections.isEmpty, !isEncodingFrame else { return false }
            isEncodingFrame = true
            return true
        }

        guard shouldEncode else { return }

        encodingQueue.async { [weak self] in
            guard let self else { return }

            let image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: Self.sdrColorSpace])
            guard let jpeg = ciContext.jpegRepresentation(
                of: image,
                colorSpace: Self.sdrColorSpace
            ) else {
                queue.async {
                    self.isEncodingFrame = false
                }
                return
            }

            let part = [
                "--\(Self.boundary)",
                "Content-Type: image/jpeg",
                "Content-Length: \(jpeg.count)",
                "",
                "",
            ].joined(separator: "\r\n")

            var payload = Data(part.utf8)
            payload.append(jpeg)
            payload.append(Data("\r\n".utf8))

            queue.async {
                self.isEncodingFrame = false
                self.broadcast(payload: payload)
            }
        }
    }

    /// Broadcasts one already-encoded MJPEG part without allowing socket writes to
    /// pile up. A client that is still sending the previous frame simply skips this
    /// one and receives the next available frame after its send completes.
    private func broadcast(payload: Data) {
        for (identifier, connection) in connections {
            guard !sendingConnections.contains(identifier) else { continue }
            sendingConnections.insert(identifier)

            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                queue.async {
                    self.sendingConnections.remove(identifier)

                    if let error {
                        Current.Log.warning("Camera stream: send failed: \(error)")
                        connection.cancel()
                        self.remove(connection: connection)
                    }
                }
            })
        }
    }
}

// MARK: - MotionDetectionObserver

extension CameraStreamServer: MotionDetectionObserver {
    // Registration is only used to keep the capture session running while the
    // stream server is active; motion state changes are irrelevant to the stream.
    public func motionStateDidChange(for manager: MotionDetectionManager) {}
}


// MARK: - H.264 / RTSP server

/// Low-latency H.264 RTSP server for the kiosk front camera.
///
/// The server uses VideoToolbox for hardware H.264 encoding and serves RTP interleaved
/// over the RTSP TCP connection. This keeps the transport local and simple for go2rtc:
///
///   rtsp://<ipad-ip>:8555/camera
///
/// MJPEG remains available in parallel on port 8090 while the RTSP path is evaluated.
public final class CameraRTSPServer {
    private enum UserDefaultsKeys: String {
        case port = "camera_rtsp_port"
    }

    private final class Client {
        let connection: NWConnection
        let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var receiveBuffer = Data()
        var playing = false
        var rtpChannel: UInt8 = 0
        var rtcpChannel: UInt8 = 1
        var sequence = UInt16.random(in: UInt16.min ... UInt16.max)
        let ssrc = UInt32.random(in: UInt32.min ... UInt32.max)
        var sendInFlight = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "camera-rtsp-server")
    private let encoderQueue = DispatchQueue(label: "camera-rtsp-encoder")

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var active = false

    // Encoder-owned state. Only touched on encoderQueue unless noted otherwise.
    private var compressionSession: VTCompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var frameIndex: Int64 = 0
    private var forceNextKeyframe = true

    // RTSP/RTP metadata. Owned by queue.
    private var sps: Data?
    private var pps: Data?

    private static let payloadType: UInt8 = 96
    private static let rtpClockRate: Int32 = 90_000
    private static let maxRTPPayload = 1_200

    public init() {}

    public var port: Int {
        get {
            let prefs = Current.settingsStore.prefs
            guard prefs.object(forKey: UserDefaultsKeys.port.rawValue) != nil else { return 8555 }
            return prefs.integer(forKey: UserDefaultsKeys.port.rawValue)
        }
        set {
            Current.settingsStore.prefs.set(newValue, forKey: UserDefaultsKeys.port.rawValue)
            queue.async { [weak self] in
                guard let self, active else { return }
                stopListener()
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, active else { return }
                    startListener()
                }
            }
        }
    }

    public var isActive: Bool {
        queue.sync { active }
    }

    public var clientCount: Int {
        queue.sync { clients.count }
    }

    public var streamURL: String? {
        guard let address = CameraStreamServer.localIPAddress() else { return nil }
        return "rtsp://\(address):\(port)/camera"
    }

    public func setActive(_ newValue: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            active = newValue

            if newValue {
                startListener()
            } else {
                stopListener()
                sps = nil
                pps = nil
                resetEncoder()
            }
        }
    }

    private func startListener() {
        guard listener == nil else { return }

        let portValue = UInt16(min(max(port, 1024), 65535))
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else { return }

        do {
            let newListener = try NWListener(using: .tcp, on: nwPort)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection: connection)
                }
            }
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Current.Log.info("Camera RTSP: listening on port \(portValue)")
                case let .failed(error):
                    Current.Log.error("Camera RTSP: listener failed: \(error)")
                default:
                    break
                }
            }
            newListener.start(queue: queue)
            listener = newListener
        } catch {
            Current.Log.error("Camera RTSP: failed to start listener: \(error)")
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil

        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
    }

    private func accept(connection: NWConnection) {
        let client = Client(connection: connection)
        let identifier = ObjectIdentifier(connection)
        clients[identifier] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                queue.async {
                    self.remove(client: client)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: client)
    }

    private func remove(client: Client) {
        let identifier = ObjectIdentifier(client.connection)
        guard clients.removeValue(forKey: identifier) != nil else { return }
        client.connection.cancel()
        Current.Log.info("Camera RTSP: client disconnected (\(clients.count) left)")
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }

            queue.async {
                if let error {
                    Current.Log.warning("Camera RTSP: receive failed: \(error)")
                    self.remove(client: client)
                    return
                }

                if let data {
                    client.receiveBuffer.append(data)
                    self.consumeRequests(from: client)
                }

                if isComplete {
                    self.remove(client: client)
                    return
                }

                self.receive(on: client)
            }
        }
    }

    private func consumeRequests(from client: Client) {
        let delimiter = Data("\r\n\r\n".utf8)

        while !client.receiveBuffer.isEmpty {
            // RTSP-over-TCP multiplexes RTP/RTCP on the same connection. Incoming
            // receiver reports use the '
    private func handle(request: String, client: Client) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return }

        let method = requestParts[0].uppercased()
        let requestURL = String(requestParts[1])
        let headers = parseHeaders(lines.dropFirst())
        let cseq = headers["cseq"] ?? "1"

        switch method {
        case "OPTIONS":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Public": "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN",
                ]
            )

        case "DESCRIBE":
            guard let sdp = makeSDP() else {
                sendResponse(
                    client: client,
                    status: "503 Service Unavailable",
                    cseq: cseq,
                    headers: ["Retry-After": "1"]
                )
                return
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Content-Base": requestURL.hasSuffix("/") ? requestURL : requestURL + "/",
                    "Content-Type": "application/sdp",
                ],
                body: Data(sdp.utf8)
            )

        case "SETUP":
            if let transport = headers["transport"] {
                let channels = parseInterleavedChannels(transport)
                client.rtpChannel = channels.rtp
                client.rtcpChannel = channels.rtcp
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Transport": "RTP/AVP/TCP;unicast;interleaved=\(client.rtpChannel)-\(client.rtcpChannel)",
                    "Session": client.sessionID,
                ]
            )

        case "PLAY":
            client.playing = true
            encoderQueue.async { [weak self] in
                self?.forceNextKeyframe = true
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Session": client.sessionID,
                    "RTP-Info": "url=\(requestURL)/trackID=0;seq=\(client.sequence);rtptime=0",
                ]
            )
            Current.Log.info("Camera RTSP: PLAY (\(clients.values.filter { $0.playing }.count) clients)")

        case "GET_PARAMETER":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: ["Session": client.sessionID]
            )

        case "TEARDOWN":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: ["Session": client.sessionID]
            )
            remove(client: client)

        default:
            sendResponse(client: client, status: "405 Method Not Allowed", cseq: cseq)
        }
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return headers
    }

    private func parseInterleavedChannels(_ transport: String) -> (rtp: UInt8, rtcp: UInt8) {
        for component in transport.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("interleaved=") else { continue }

            let value = trimmed.dropFirst("interleaved=".count)
            let channels = value.split(separator: "-", maxSplits: 1)
            if channels.count == 2,
               let rtp = UInt8(channels[0]),
               let rtcp = UInt8(channels[1]) {
                return (rtp, rtcp)
            }
        }

        return (0, 1)
    }

    private func sendResponse(
        client: Client,
        status: String,
        cseq: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        var responseLines = [
            "RTSP/1.0 \(status)",
            "CSeq: \(cseq)",
            "Server: HomeAssistant-Kiosk-RTSP/1.0",
        ]

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            responseLines.append("\(name): \(value)")
        }

        if let body {
            responseLines.append("Content-Length: \(body.count)")
        } else {
            responseLines.append("Content-Length: 0")
        }

        responseLines.append("")
        responseLines.append("")

        var data = Data(responseLines.joined(separator: "\r\n").utf8)
        if let body {
            data.append(body)
        }

        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, let error else { return }
            queue.async {
                Current.Log.warning("Camera RTSP: response send failed: \(error)")
                self.remove(client: client)
            }
        })
    }

    private func makeSDP() -> String? {
        guard let sps, let pps else { return nil }

        let profileLevelID: String
        if sps.count >= 4 {
            profileLevelID = String(format: "%02X%02X%02X", sps[1], sps[2], sps[3])
        } else {
            profileLevelID = "42E01F"
        }

        return [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=Home Assistant Kiosk Camera",
            "t=0 0",
            "a=control:*",
            "m=video 0 RTP/AVP \(Self.payloadType)",
            "c=IN IP4 0.0.0.0",
            "a=rtpmap:\(Self.payloadType) H264/90000",
            "a=fmtp:\(Self.payloadType) packetization-mode=1;profile-level-id=\(profileLevelID);sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())",
            "a=control:trackID=0",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: Encoding

    /// Feeds one camera frame to the hardware H.264 encoder.
    /// Encoding runs only while the RTSP server is active and until at least one
    /// client is playing, apart from the initial bootstrap needed to obtain SPS/PPS.
    public func handle(frame: CVPixelBuffer) {
        let shouldEncode = queue.sync {
            active && (sps == nil || pps == nil || clients.values.contains { $0.playing })
        }

        guard shouldEncode else { return }

        encoderQueue.async { [weak self] in
            self?.encode(frame: frame)
        }
    }

    private func encode(frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        if compressionSession == nil || encoderWidth != width || encoderHeight != height {
            guard configureEncoder(width: width, height: height) else { return }
        }

        guard let compressionSession else { return }

        let fps = max(1, min(Current.cameraStreamServer.streamFrameRate, 30))
        let timescale = CMTimeScale(max(1, Int32(fps.rounded())))
        let presentationTime = CMTime(value: frameIndex, timescale: timescale)
        let duration = CMTime(value: 1, timescale: timescale)
        frameIndex += 1

        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true,
            ] as CFDictionary
            forceNextKeyframe = false
        }

        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: frame,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        if status != noErr {
            Current.Log.error("Camera RTSP: H.264 encode failed with status \(status)")
        }
    }

    private func configureEncoder(width: Int, height: Int) -> Bool {
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            Current.Log.error("Camera RTSP: unable to create H.264 encoder, status \(status)")
            return false
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: max(1, min(Current.cameraStreamServer.streamFrameRate, 30)))
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: 1_200_000)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: 30)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 2)
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            Current.Log.error("Camera RTSP: H.264 encoder prepare failed, status \(prepareStatus)")
            VTCompressionSessionInvalidate(session)
            return false
        }

        compressionSession = session
        encoderWidth = width
        encoderHeight = height
        frameIndex = 0
        forceNextKeyframe = true

        Current.Log.info("Camera RTSP: H.264 encoder configured at \(width)x\(height)")
        return true
    }

    private func resetEncoder() {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            if let compressionSession {
                VTCompressionSessionCompleteFrames(
                    compressionSession,
                    untilPresentationTimeStamp: .invalid
                )
                VTCompressionSessionInvalidate(compressionSession)
            }
            compressionSession = nil
            encoderWidth = 0
            encoderHeight = 0
            frameIndex = 0
            forceNextKeyframe = true
        }
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon,
        _,
        status,
        _,
        sampleBuffer
        in
        guard status == noErr,
              let outputCallbackRefCon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let server = Unmanaged<CameraRTSPServer>
            .fromOpaque(outputCallbackRefCon)
            .takeUnretainedValue()

        server.handleEncoded(sampleBuffer: sampleBuffer)
    }

    private func handleEncoded(sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]

        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKeyframe,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let parameterSets = Self.h264ParameterSets(from: formatDescription)
            if let parameterSets {
                queue.async { [weak self] in
                    self?.sps = parameterSets.sps
                    self?.pps = parameterSets.pps
                }
            }
        }

        guard let nalUnits = Self.nalUnits(from: sampleBuffer), !nalUnits.isEmpty else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scaledPTS = CMTimeConvertScale(pts, timescale: Self.rtpClockRate, method: .default)
        let timestamp = UInt32(truncatingIfNeeded: scaledPTS.value)

        queue.async { [weak self] in
            self?.broadcast(nalUnits: nalUnits, timestamp: timestamp, isKeyframe: isKeyframe)
        }
    }

    private static func h264ParameterSets(
        from formatDescription: CMFormatDescription
    ) -> (sps: Data, pps: Data)? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer else {
            return nil
        }

        return (
            Data(bytes: spsPointer, count: spsSize),
            Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func nalUnits(from sampleBuffer: CMSampleBuffer) -> [Data]? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer else { return nil }

        let bytes = Data(bytes: dataPointer, count: totalLength)
        var offset = 0
        var nalUnits: [Data] = []

        while offset + 4 <= bytes.count {
            let nalLength =
                (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])

            offset += 4

            guard nalLength > 0, offset + nalLength <= bytes.count else { break }
            nalUnits.append(bytes.subdata(in: offset ..< (offset + nalLength)))
            offset += nalLength
        }

        return nalUnits
    }

    // MARK: RTP

    private func broadcast(nalUnits: [Data], timestamp: UInt32, isKeyframe: Bool) {
        guard active else { return }

        for client in clients.values where client.playing && !client.sendInFlight {
            var accessUnit = Data()

            if isKeyframe {
                if let sps {
                    appendRTPPackets(
                        for: sps,
                        timestamp: timestamp,
                        markerOnLastPacket: false,
                        client: client,
                        to: &accessUnit
                    )
                }
                if let pps {
                    appendRTPPackets(
                        for: pps,
                        timestamp: timestamp,
                        markerOnLastPacket: false,
                        client: client,
                        to: &accessUnit
                    )
                }
            }

            for (index, nalUnit) in nalUnits.enumerated() {
                appendRTPPackets(
                    for: nalUnit,
                    timestamp: timestamp,
                    markerOnLastPacket: index == nalUnits.count - 1,
                    client: client,
                    to: &accessUnit
                )
            }

            guard !accessUnit.isEmpty else { continue }

            client.sendInFlight = true
            client.connection.send(content: accessUnit, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                queue.async {
                    client.sendInFlight = false
                    if let error {
                        Current.Log.warning("Camera RTSP: RTP send failed: \(error)")
                        self.remove(client: client)
                    }
                }
            })
        }
    }

    private func appendRTPPackets(
        for nalUnit: Data,
        timestamp: UInt32,
        markerOnLastPacket: Bool,
        client: Client,
        to output: inout Data
    ) {
        guard let nalHeader = nalUnit.first else { return }

        if nalUnit.count <= Self.maxRTPPayload {
            let packet = makeRTPPacket(
                payload: nalUnit,
                timestamp: timestamp,
                marker: markerOnLastPacket,
                client: client
            )
            appendInterleaved(packet: packet, channel: client.rtpChannel, to: &output)
            return
        }

        let fuIndicator = (nalHeader & 0xE0) | 28
        let nalType = nalHeader & 0x1F
        let payloadBytes = Data(nalUnit.dropFirst())
        let chunkSize = Self.maxRTPPayload - 2

        var offset = 0
        while offset < payloadBytes.count {
            let end = min(offset + chunkSize, payloadBytes.count)
            let isStart = offset == 0
            let isEnd = end == payloadBytes.count

            var fuHeader = nalType
            if isStart { fuHeader |= 0x80 }
            if isEnd { fuHeader |= 0x40 }

            var fragment = Data([fuIndicator, fuHeader])
            fragment.append(contentsOf: payloadBytes[offset ..< end])

            let packet = makeRTPPacket(
                payload: fragment,
                timestamp: timestamp,
                marker: markerOnLastPacket && isEnd,
                client: client
            )
            appendInterleaved(packet: packet, channel: client.rtpChannel, to: &output)

            offset = end
        }
    }

    private func makeRTPPacket(
        payload: Data,
        timestamp: UInt32,
        marker: Bool,
        client: Client
    ) -> Data {
        var packet = Data(capacity: 12 + payload.count)

        packet.append(0x80)
        packet.append((marker ? 0x80 : 0x00) | Self.payloadType)

        let sequence = client.sequence
        client.sequence &+= 1

        packet.append(UInt8((sequence >> 8) & 0xFF))
        packet.append(UInt8(sequence & 0xFF))

        packet.append(UInt8((timestamp >> 24) & 0xFF))
        packet.append(UInt8((timestamp >> 16) & 0xFF))
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))

        let ssrc = client.ssrc
        packet.append(UInt8((ssrc >> 24) & 0xFF))
        packet.append(UInt8((ssrc >> 16) & 0xFF))
        packet.append(UInt8((ssrc >> 8) & 0xFF))
        packet.append(UInt8(ssrc & 0xFF))

        packet.append(payload)
        return packet
    }

    private func appendInterleaved(packet: Data, channel: UInt8, to output: inout Data) {
        guard packet.count <= Int(UInt16.max) else { return }

        let length = UInt16(packet.count)
        output.append(0x24)
        output.append(channel)
        output.append(UInt8((length >> 8) & 0xFF))
        output.append(UInt8(length & 0xFF))
        output.append(packet)
    }
}

#else

/// Stub for platforms without camera capture (watchOS, Mac Catalyst).
public class CameraStreamServer {
    public var onStateChange: (() -> Void)?
    public var isActive: Bool { false }
    public var isStreaming: Bool { false }
    public var clientCount: Int { 0 }
    public var port: Int = 8090
    public var streamFrameRate: Double = 15
    public var username: String = ""
    public var password: String = ""

    public init() {}

    public func setActive(_ newValue: Bool) {}
}


public final class CameraRTSPServer {
    public var port: Int = 8555
    public var isActive: Bool { false }
    public var clientCount: Int { 0 }
    public var streamURL: String? { nil }

    public init() {}

    public func setActive(_ newValue: Bool) {}
}

#endif
 framing too, so consume and ignore those
            // binary frames before trying to parse the next textual RTSP request.
            if client.receiveBuffer.first == 0x24 {
                guard client.receiveBuffer.count >= 4 else { return }

                let payloadLength =
                    (Int(client.receiveBuffer[2]) << 8)
                    | Int(client.receiveBuffer[3])
                let frameLength = 4 + payloadLength

                guard client.receiveBuffer.count >= frameLength else { return }
                client.receiveBuffer.removeSubrange(..<frameLength)
                continue
            }

            guard let range = client.receiveBuffer.range(of: delimiter) else { return }

            let requestData = client.receiveBuffer[..<range.upperBound]
            client.receiveBuffer.removeSubrange(..<range.upperBound)

            guard let request = String(data: requestData, encoding: .utf8) else { continue }
            handle(request: request, client: client)
        }
    }

    private func handle(request: String, client: Client) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return }

        let method = requestParts[0].uppercased()
        let requestURL = String(requestParts[1])
        let headers = parseHeaders(lines.dropFirst())
        let cseq = headers["cseq"] ?? "1"

        switch method {
        case "OPTIONS":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Public": "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN",
                ]
            )

        case "DESCRIBE":
            guard let sdp = makeSDP() else {
                sendResponse(
                    client: client,
                    status: "503 Service Unavailable",
                    cseq: cseq,
                    headers: ["Retry-After": "1"]
                )
                return
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Content-Base": requestURL.hasSuffix("/") ? requestURL : requestURL + "/",
                    "Content-Type": "application/sdp",
                ],
                body: Data(sdp.utf8)
            )

        case "SETUP":
            if let transport = headers["transport"] {
                let channels = parseInterleavedChannels(transport)
                client.rtpChannel = channels.rtp
                client.rtcpChannel = channels.rtcp
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Transport": "RTP/AVP/TCP;unicast;interleaved=\(client.rtpChannel)-\(client.rtcpChannel)",
                    "Session": client.sessionID,
                ]
            )

        case "PLAY":
            client.playing = true
            encoderQueue.async { [weak self] in
                self?.forceNextKeyframe = true
            }

            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: [
                    "Session": client.sessionID,
                    "RTP-Info": "url=\(requestURL)/trackID=0;seq=\(client.sequence);rtptime=0",
                ]
            )
            Current.Log.info("Camera RTSP: PLAY (\(clients.values.filter { $0.playing }.count) clients)")

        case "GET_PARAMETER":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: ["Session": client.sessionID]
            )

        case "TEARDOWN":
            sendResponse(
                client: client,
                status: "200 OK",
                cseq: cseq,
                headers: ["Session": client.sessionID]
            )
            remove(client: client)

        default:
            sendResponse(client: client, status: "405 Method Not Allowed", cseq: cseq)
        }
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return headers
    }

    private func parseInterleavedChannels(_ transport: String) -> (rtp: UInt8, rtcp: UInt8) {
        for component in transport.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("interleaved=") else { continue }

            let value = trimmed.dropFirst("interleaved=".count)
            let channels = value.split(separator: "-", maxSplits: 1)
            if channels.count == 2,
               let rtp = UInt8(channels[0]),
               let rtcp = UInt8(channels[1]) {
                return (rtp, rtcp)
            }
        }

        return (0, 1)
    }

    private func sendResponse(
        client: Client,
        status: String,
        cseq: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        var responseLines = [
            "RTSP/1.0 \(status)",
            "CSeq: \(cseq)",
            "Server: HomeAssistant-Kiosk-RTSP/1.0",
        ]

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            responseLines.append("\(name): \(value)")
        }

        if let body {
            responseLines.append("Content-Length: \(body.count)")
        } else {
            responseLines.append("Content-Length: 0")
        }

        responseLines.append("")
        responseLines.append("")

        var data = Data(responseLines.joined(separator: "\r\n").utf8)
        if let body {
            data.append(body)
        }

        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, let error else { return }
            queue.async {
                Current.Log.warning("Camera RTSP: response send failed: \(error)")
                self.remove(client: client)
            }
        })
    }

    private func makeSDP() -> String? {
        guard let sps, let pps else { return nil }

        let profileLevelID: String
        if sps.count >= 4 {
            profileLevelID = String(format: "%02X%02X%02X", sps[1], sps[2], sps[3])
        } else {
            profileLevelID = "42E01F"
        }

        return [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=Home Assistant Kiosk Camera",
            "t=0 0",
            "a=control:*",
            "m=video 0 RTP/AVP \(Self.payloadType)",
            "c=IN IP4 0.0.0.0",
            "a=rtpmap:\(Self.payloadType) H264/90000",
            "a=fmtp:\(Self.payloadType) packetization-mode=1;profile-level-id=\(profileLevelID);sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())",
            "a=control:trackID=0",
            "",
        ].joined(separator: "\r\n")
    }

    // MARK: Encoding

    /// Feeds one camera frame to the hardware H.264 encoder.
    /// Encoding runs only while the RTSP server is active and until at least one
    /// client is playing, apart from the initial bootstrap needed to obtain SPS/PPS.
    public func handle(frame: CVPixelBuffer) {
        let shouldEncode = queue.sync {
            active && (sps == nil || pps == nil || clients.values.contains { $0.playing })
        }

        guard shouldEncode else { return }

        encoderQueue.async { [weak self] in
            self?.encode(frame: frame)
        }
    }

    private func encode(frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        if compressionSession == nil || encoderWidth != width || encoderHeight != height {
            guard configureEncoder(width: width, height: height) else { return }
        }

        guard let compressionSession else { return }

        let fps = max(1, min(Current.cameraStreamServer.streamFrameRate, 30))
        let timescale = CMTimeScale(max(1, Int32(fps.rounded())))
        let presentationTime = CMTime(value: frameIndex, timescale: timescale)
        let duration = CMTime(value: 1, timescale: timescale)
        frameIndex += 1

        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true,
            ] as CFDictionary
            forceNextKeyframe = false
        }

        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: frame,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        if status != noErr {
            Current.Log.error("Camera RTSP: H.264 encode failed with status \(status)")
        }
    }

    private func configureEncoder(width: Int, height: Int) -> Bool {
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            Current.Log.error("Camera RTSP: unable to create H.264 encoder, status \(status)")
            return false
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: max(1, min(Current.cameraStreamServer.streamFrameRate, 30)))
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: 1_200_000)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: 30)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 2)
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            Current.Log.error("Camera RTSP: H.264 encoder prepare failed, status \(prepareStatus)")
            VTCompressionSessionInvalidate(session)
            return false
        }

        compressionSession = session
        encoderWidth = width
        encoderHeight = height
        frameIndex = 0
        forceNextKeyframe = true

        Current.Log.info("Camera RTSP: H.264 encoder configured at \(width)x\(height)")
        return true
    }

    private func resetEncoder() {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            if let compressionSession {
                VTCompressionSessionCompleteFrames(
                    compressionSession,
                    untilPresentationTimeStamp: .invalid
                )
                VTCompressionSessionInvalidate(compressionSession)
            }
            compressionSession = nil
            encoderWidth = 0
            encoderHeight = 0
            frameIndex = 0
            forceNextKeyframe = true
        }
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon,
        _,
        status,
        _,
        sampleBuffer
        in
        guard status == noErr,
              let outputCallbackRefCon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let server = Unmanaged<CameraRTSPServer>
            .fromOpaque(outputCallbackRefCon)
            .takeUnretainedValue()

        server.handleEncoded(sampleBuffer: sampleBuffer)
    }

    private func handleEncoded(sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]

        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKeyframe,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let parameterSets = Self.h264ParameterSets(from: formatDescription)
            if let parameterSets {
                queue.async { [weak self] in
                    self?.sps = parameterSets.sps
                    self?.pps = parameterSets.pps
                }
            }
        }

        guard let nalUnits = Self.nalUnits(from: sampleBuffer), !nalUnits.isEmpty else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scaledPTS = CMTimeConvertScale(pts, timescale: Self.rtpClockRate, method: .default)
        let timestamp = UInt32(truncatingIfNeeded: scaledPTS.value)

        queue.async { [weak self] in
            self?.broadcast(nalUnits: nalUnits, timestamp: timestamp, isKeyframe: isKeyframe)
        }
    }

    private static func h264ParameterSets(
        from formatDescription: CMFormatDescription
    ) -> (sps: Data, pps: Data)? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer else {
            return nil
        }

        return (
            Data(bytes: spsPointer, count: spsSize),
            Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func nalUnits(from sampleBuffer: CMSampleBuffer) -> [Data]? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer else { return nil }

        let bytes = Data(bytes: dataPointer, count: totalLength)
        var offset = 0
        var nalUnits: [Data] = []

        while offset + 4 <= bytes.count {
            let nalLength =
                (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])

            offset += 4

            guard nalLength > 0, offset + nalLength <= bytes.count else { break }
            nalUnits.append(bytes.subdata(in: offset ..< (offset + nalLength)))
            offset += nalLength
        }

        return nalUnits
    }

    // MARK: RTP

    private func broadcast(nalUnits: [Data], timestamp: UInt32, isKeyframe: Bool) {
        guard active else { return }

        for client in clients.values where client.playing && !client.sendInFlight {
            var accessUnit = Data()

            if isKeyframe {
                if let sps {
                    appendRTPPackets(
                        for: sps,
                        timestamp: timestamp,
                        markerOnLastPacket: false,
                        client: client,
                        to: &accessUnit
                    )
                }
                if let pps {
                    appendRTPPackets(
                        for: pps,
                        timestamp: timestamp,
                        markerOnLastPacket: false,
                        client: client,
                        to: &accessUnit
                    )
                }
            }

            for (index, nalUnit) in nalUnits.enumerated() {
                appendRTPPackets(
                    for: nalUnit,
                    timestamp: timestamp,
                    markerOnLastPacket: index == nalUnits.count - 1,
                    client: client,
                    to: &accessUnit
                )
            }

            guard !accessUnit.isEmpty else { continue }

            client.sendInFlight = true
            client.connection.send(content: accessUnit, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                queue.async {
                    client.sendInFlight = false
                    if let error {
                        Current.Log.warning("Camera RTSP: RTP send failed: \(error)")
                        self.remove(client: client)
                    }
                }
            })
        }
    }

    private func appendRTPPackets(
        for nalUnit: Data,
        timestamp: UInt32,
        markerOnLastPacket: Bool,
        client: Client,
        to output: inout Data
    ) {
        guard let nalHeader = nalUnit.first else { return }

        if nalUnit.count <= Self.maxRTPPayload {
            let packet = makeRTPPacket(
                payload: nalUnit,
                timestamp: timestamp,
                marker: markerOnLastPacket,
                client: client
            )
            appendInterleaved(packet: packet, channel: client.rtpChannel, to: &output)
            return
        }

        let fuIndicator = (nalHeader & 0xE0) | 28
        let nalType = nalHeader & 0x1F
        let payloadBytes = Data(nalUnit.dropFirst())
        let chunkSize = Self.maxRTPPayload - 2

        var offset = 0
        while offset < payloadBytes.count {
            let end = min(offset + chunkSize, payloadBytes.count)
            let isStart = offset == 0
            let isEnd = end == payloadBytes.count

            var fuHeader = nalType
            if isStart { fuHeader |= 0x80 }
            if isEnd { fuHeader |= 0x40 }

            var fragment = Data([fuIndicator, fuHeader])
            fragment.append(contentsOf: payloadBytes[offset ..< end])

            let packet = makeRTPPacket(
                payload: fragment,
                timestamp: timestamp,
                marker: markerOnLastPacket && isEnd,
                client: client
            )
            appendInterleaved(packet: packet, channel: client.rtpChannel, to: &output)

            offset = end
        }
    }

    private func makeRTPPacket(
        payload: Data,
        timestamp: UInt32,
        marker: Bool,
        client: Client
    ) -> Data {
        var packet = Data(capacity: 12 + payload.count)

        packet.append(0x80)
        packet.append((marker ? 0x80 : 0x00) | Self.payloadType)

        let sequence = client.sequence
        client.sequence &+= 1

        packet.append(UInt8((sequence >> 8) & 0xFF))
        packet.append(UInt8(sequence & 0xFF))

        packet.append(UInt8((timestamp >> 24) & 0xFF))
        packet.append(UInt8((timestamp >> 16) & 0xFF))
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))

        let ssrc = client.ssrc
        packet.append(UInt8((ssrc >> 24) & 0xFF))
        packet.append(UInt8((ssrc >> 16) & 0xFF))
        packet.append(UInt8((ssrc >> 8) & 0xFF))
        packet.append(UInt8(ssrc & 0xFF))

        packet.append(payload)
        return packet
    }

    private func appendInterleaved(packet: Data, channel: UInt8, to output: inout Data) {
        guard packet.count <= Int(UInt16.max) else { return }

        let length = UInt16(packet.count)
        output.append(0x24)
        output.append(channel)
        output.append(UInt8((length >> 8) & 0xFF))
        output.append(UInt8(length & 0xFF))
        output.append(packet)
    }
}

#else

/// Stub for platforms without camera capture (watchOS, Mac Catalyst).
public class CameraStreamServer {
    public var onStateChange: (() -> Void)?
    public var isActive: Bool { false }
    public var isStreaming: Bool { false }
    public var clientCount: Int { 0 }
    public var port: Int = 8090
    public var streamFrameRate: Double = 15
    public var username: String = ""
    public var password: String = ""

    public init() {}

    public func setActive(_ newValue: Bool) {}
}


public final class CameraRTSPServer {
    public var port: Int = 8555
    public var isActive: Bool { false }
    public var clientCount: Int { 0 }
    public var streamURL: String? { nil }

    public init() {}

    public func setActive(_ newValue: Bool) {}
}

#endif
