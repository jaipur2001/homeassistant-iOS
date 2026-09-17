from pathlib import Path

path = Path("Sources/App/Notifications/NotificationManager.swift")
source = path.read_text(encoding="utf-8")

old_view = """    /// Hidden, off-screen volume view; `MPVolumeView` only drives the hardware volume while in a window.
    private lazy var volumeControlView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
"""

new_view = """    /// Persistent off-screen MPVolumeView used for kiosk hardware-volume control.
    /// It must remain attached to a window and must not be hidden for iOS to back it
    /// with the system volume control.
    private lazy var volumeControlView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
        view.showsVolumeSlider = true
        view.showsRouteButton = false
        return view
    }()
"""

start_marker = "    private func setSystemVolume(_ level: Float) {"
end_marker = "\n    private func playKioskMedia("

new_func = """    private func systemVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider {
            return slider
        }

        for subview in view.subviews {
            if let slider = systemVolumeSlider(in: subview) {
                return slider
            }
        }

        return nil
    }

    private func setSystemVolume(_ level: Float) {
        let clamped = min(max(level, 0), 1)

        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in
                guard let self else { return }

                #if os(iOS) && !targetEnvironment(macCatalyst)
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setCategory(.playback, mode: .default, options: [])
                    try audioSession.setActive(true)
                } catch {
                    Current.Log.warning("Unable to activate audio session before kiosk volume change: \\(error)")
                }
                #endif

                if self.volumeControlView.superview == nil {
                    webViewController.view.addSubview(self.volumeControlView)
                }

                self.volumeControlView.setNeedsLayout()
                self.volumeControlView.layoutIfNeeded()

                let applyVolume: (TimeInterval) -> Void = { [weak self] delay in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard let self else { return }

                        self.volumeControlView.setNeedsLayout()
                        self.volumeControlView.layoutIfNeeded()

                        guard let slider = self.systemVolumeSlider(in: self.volumeControlView) else {
                            Current.Log.error("Unable to locate system volume slider for kiosk command")
                            return
                        }

                        slider.setValue(clamped, animated: false)
                        slider.sendActions(for: .valueChanged)
                        slider.sendActions(for: .touchUpInside)

                        Current.Log.info(
                            "Kiosk requested system volume \\(clamped); MPVolumeView slider now \\(slider.value)"
                        )
                    }
                }

                applyVolume(0.05)
                applyVolume(0.20)
                applyVolume(0.50)

                #if os(iOS) && !targetEnvironment(macCatalyst)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    let actual = AVAudioSession.sharedInstance().outputVolume
                    Current.Log.info(
                        "Kiosk system volume verification: requested=\\(clamped), actual=\\(actual)"
                    )
                }
                #endif
            }.catch { error in
                Current.Log.error("Failed to set volume from push command: \\(error)")
            }
    }
"""

if "Kiosk system volume verification: requested=" in source and "width: 120, height: 40" in source:
    print("Robust volume fix already present")
else:
    if source.count(old_view) != 1:
        raise SystemExit(f"Expected one old MPVolumeView block, found {source.count(old_view)}")

    start = source.find(start_marker)
    if start == -1:
        raise SystemExit("setSystemVolume start marker not found")

    end = source.find(end_marker, start)
    if end == -1:
        raise SystemExit("playKioskMedia marker not found")

    source = source.replace(old_view, new_view, 1)
    source = source[:start] + new_func + source[end:]
    path.write_text(source, encoding="utf-8")
    print("Robust volume fix applied")
