import Shared
import SwiftUI
import UIKit

/// A SwiftUI view for displaying MJPEG camera streams.
struct CameraMJPEGPlayerView: View {
    @Environment(\.dismiss) private var dismiss

    private let server: Server
    private let cameraEntityId: String
    private let cameraName: String?
    private let controlsVisible: Binding<Bool>?

    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        server: Server,
        cameraEntityId: String,
        cameraName: String? = nil,
        controlsVisible: Binding<Bool>? = nil
    ) {
        self.server = server
        self.cameraEntityId = cameraEntityId
        self.cameraName = cameraName
        self.controlsVisible = controlsVisible
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            if errorMessage == nil {
                MJPEGStreamContainerView(
                    server: server,
                    cameraEntityId: cameraEntityId,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea()
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
            }

            if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemSymbol: .exclamationmarkTriangle)
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                    Text(errorMessage)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            controlsVisible?.wrappedValue.toggle()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - UIViewControllerRepresentable wrapper

private struct MJPEGStreamContainerView: UIViewControllerRepresentable {
    let server: Server
    let cameraEntityId: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    func makeUIViewController(context: Context) -> MJPEGStreamViewController {
        MJPEGStreamViewController(
            server: server,
            cameraEntityId: cameraEntityId,
            coordinator: context.coordinator
        )
    }

    func updateUIViewController(_ uiViewController: MJPEGStreamViewController, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, errorMessage: $errorMessage)
    }

    class Coordinator {
        @Binding var isLoading: Bool
        @Binding var errorMessage: String?

        init(isLoading: Binding<Bool>, errorMessage: Binding<String?>) {
            _isLoading = isLoading
            _errorMessage = errorMessage
        }

        func didReceiveFirstFrame() {
            isLoading = false
        }

        func didEncounterError(_ error: Error) {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - UIKit View Controller for MJPEG streaming

private class MJPEGStreamViewController: UIViewController {
    private let server: Server
    private let cameraEntityId: String
    private weak var coordinator: MJPEGStreamContainerView.Coordinator?

    private var streamer: MJPEGStreamer?
    private let imageView = UIImageView()
    private var hasReceivedFirstFrame = false
    private var lastFrameDate: Date?
    private var watchdogTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var streamGeneration = UUID()

    private let watchdogInterval: TimeInterval = 2
    private let frameTimeout: TimeInterval = 6
    private let reconnectDelay: TimeInterval = 1

    init(
        server: Server,
        cameraEntityId: String,
        coordinator: MJPEGStreamContainerView.Coordinator
    ) {
        self.server = server
        self.cameraEntityId = cameraEntityId
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopStreaming()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        startStreaming(reason: "initial")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopStreaming()
    }

    @objc private func appDidBecomeActive() {
        guard viewIfLoaded?.window != nil else { return }
        Current.Log.info("MJPEG camera \(cameraEntityId) foregrounded, restarting stream")
        startStreaming(reason: "app-foreground")
    }

    private func startStreaming(reason: String) {
        stopStreaming(keepImage: true)

        guard let api = Current.api(for: server) else {
            coordinator?.didEncounterError(StreamError.unableToConnect)
            scheduleReconnect(reason: "api-unavailable")
            return
        }

        let generation = UUID()
        streamGeneration = generation
        hasReceivedFirstFrame = false
        lastFrameDate = Date()

        Current.Log.info("Starting MJPEG camera \(cameraEntityId), reason=\(reason), generation=\(generation)")

        startWatchdog(for: generation)

        Task { [weak self] in
            guard let self else { return }

            guard let baseURL = await api.server.activeURL() else {
                await MainActor.run {
                    guard self.streamGeneration == generation else { return }
                    self.coordinator?.didEncounterError(StreamError.unableToConnect)
                    self.scheduleReconnect(reason: "no-active-url")
                }
                return
            }

            guard streamGeneration == generation else { return }

            let mjpegURL = baseURL.appendingPathComponent("api/camera_proxy_stream/\(cameraEntityId)")
            let videoStreamer = api.VideoStreamer()
            streamer = videoStreamer

            videoStreamer.streamImages(fromURL: mjpegURL) { [weak self] image, error in
                guard let self, self.streamGeneration == generation else { return }

                if let image {
                    self.lastFrameDate = Date()
                    self.imageView.image = image

                    if !self.hasReceivedFirstFrame {
                        self.hasReceivedFirstFrame = true
                        self.coordinator?.didReceiveFirstFrame()
                        Current.Log.info("MJPEG camera \(self.cameraEntityId) received first frame")
                    }
                } else if let error {
                    Current.Log.error(
                        "MJPEG camera \(self.cameraEntityId) stream error: \(error.localizedDescription)"
                    )
                    self.scheduleReconnect(reason: "stream-error")
                }
            }
        }
    }

    private func startWatchdog(for generation: UUID) {
        watchdogTimer?.invalidate()

        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            guard let self, streamGeneration == generation else { return }
            guard viewIfLoaded?.window != nil else { return }

            let age = Date().timeIntervalSince(lastFrameDate ?? .distantPast)
            guard age >= frameTimeout else { return }

            Current.Log.warning(
                "MJPEG camera \(cameraEntityId) watchdog detected stale stream after \(age)s"
            )
            scheduleReconnect(reason: "frame-timeout")
        }

        watchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleReconnect(reason: String) {
        guard viewIfLoaded?.window != nil else { return }
        guard reconnectWorkItem == nil else { return }

        streamer?.cancel()
        streamer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        Current.Log.info(
            "Scheduling MJPEG camera \(cameraEntityId) reconnect in \(reconnectDelay)s, reason=\(reason)"
        )

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            reconnectWorkItem = nil
            guard viewIfLoaded?.window != nil else { return }
            startStreaming(reason: "automatic-reconnect:\(reason)")
        }

        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: item)
    }

    private func stopStreaming(keepImage: Bool = false) {
        streamGeneration = UUID()

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        watchdogTimer?.invalidate()
        watchdogTimer = nil

        streamer?.cancel()
        streamer = nil

        lastFrameDate = nil
        hasReceivedFirstFrame = false

        if !keepImage {
            imageView.image = nil
        }
    }

    private enum StreamError: LocalizedError {
        case unableToConnect

        var errorDescription: String? {
            L10n.CameraPlayer.Errors.unableToConnectToServer
        }
    }
}

#if DEBUG
#Preview {
    CameraMJPEGPlayerView(
        server: ServerFixture.standard,
        cameraEntityId: "camera.front_door",
        cameraName: "Front Door"
    )
}
#endif
