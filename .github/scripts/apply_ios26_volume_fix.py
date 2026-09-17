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

new_section = """    private func setScreenBrightness(_ level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        DispatchQueue.main.async {
            UIScreen.main.brightness = clamped
            Current.Log.info("Kiosk set screen brightness to \\(clamped)")
        }
    }

    private func systemVolumeSlider(in view: UIView) -> UISlider? {
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

# Normalize the MPVolumeView block independently. Never calculate offsets before
# changing text earlier in the source file.
if old_view in source:
    source = source.replace(old_view, new_view, 1)
elif "width: 120, height: 40" not in source:
    raise SystemExit("Unable to locate either the old or robust MPVolumeView block")

# Replace the complete brightness/volume section. This intentionally also repairs
# any partially spliced code left by the previous one-time patch.
start_marker = "    private func setScreenBrightness"
end_marker = "\n    private func playKioskMedia("

start = source.find(start_marker)
if start == -1:
    raise SystemExit("setScreenBrightness section start not found")

end = source.find(end_marker, start)
if end == -1:
    raise SystemExit("playKioskMedia section end not found")

source = source[:start] + new_section + source[end:]

# Guard against the exact corruption produced by the previous patch.
for forbidden in (
    "setScreenBrightness    private func",
    "\nchUpInside)",
):
    if forbidden in source:
        raise SystemExit(f"Corrupt fragment still present: {forbidden!r}")

required = (
    "private func setScreenBrightness(_ level: Float)",
    "private func systemVolumeSlider(in view: UIView) -> UISlider?",
    "width: 120, height: 40",
    "slider.sendActions(for: .valueChanged)",
    "applyVolume(0.05)",
    "applyVolume(0.20)",
    "applyVolume(0.50)",
    "Kiosk system volume verification: requested=",
)

for marker in required:
    if marker not in source:
        raise SystemExit(f"Required marker missing after repair: {marker}")

path.write_text(source, encoding="utf-8")
print("Robust iOS 26 kiosk volume section repaired successfully")
