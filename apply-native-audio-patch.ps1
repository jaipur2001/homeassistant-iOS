$ErrorActionPreference = "Stop"

# =============================================================================
# Home Assistant iOS
# Native Kiosk Audio Patch
#
# Basis:
#   release/2026.9.2/2026.2995
#
# Neue Kiosk-Kommandos:
#   kiosk_play_media
#   kiosk_stop_media
#
# Wiedergabe:
#   media-source://...
#       -> Home Assistant WebSocket media_source/resolve_media
#       -> signierte URL
#       -> lokaler Download
#       -> AVAudioSession
#       -> AVAudioPlayer
#
# Kein WKWebView.
# Kein HTMLAudioElement.
# Kein Browser-Mod-Audio.
# Keine User-Gesture erforderlich.
# =============================================================================

$ExpectedBranch = "native-kiosk-audio"
$ExpectedTag = "release/2026.9.2/2026.2995"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$KioskCommandPath = Join-Path `
    $Root `
    "Sources\App\Notifications\KioskPushCommand.swift"

$NotificationManagerPath = Join-Path `
    $Root `
    "Sources\App\Notifications\NotificationManager.swift"

$HAAPIPath = Join-Path `
    $Root `
    "Sources\Shared\API\HAAPI.swift"

$WorkflowDir = Join-Path `
    $Root `
    ".github\workflows"

$WorkflowPath = Join-Path `
    $WorkflowDir `
    "build-native-kiosk-audio.yml"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)


# =============================================================================
# Hilfsfunktionen
# =============================================================================

function Normalize-LF {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return $Text.Replace("`r`n", "`n")
}


function Replace-ExactlyOnce {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Old,

        [Parameter(Mandatory = $true)]
        [string]$New,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $OldNormalized = Normalize-LF $Old
    $NewNormalized = Normalize-LF $New

    $Pattern = [regex]::Escape($OldNormalized)

    $Count = (
        [regex]::Matches(
            $Content,
            $Pattern
        )
    ).Count

    if ($Count -ne 1) {
        throw @"
Patchstelle nicht eindeutig gefunden:

$Description

Erwartete Treffer:
  1

Gefundene Treffer:
  $Count

Der Patch wird aus Sicherheitsgruenden abgebrochen.
"@
    }

    return $Content.Replace(
        $OldNormalized,
        $NewNormalized
    )
}


function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (Normalize-LF $Content),
        $Utf8NoBom
    )
}


# =============================================================================
# Start
# =============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Home Assistant iOS - Native Kiosk Audio"
Write-Host "============================================================"
Write-Host ""


# =============================================================================
# Repository pruefen
# =============================================================================

Push-Location $Root

try {

    $CurrentBranch = (
        git branch --show-current
    ).Trim()

    if ($CurrentBranch -ne $ExpectedBranch) {
        throw @"
Falscher Git-Branch.

Erwartet:
  $ExpectedBranch

Gefunden:
  $CurrentBranch
"@
    }


    $CurrentCommit = (
        git rev-parse HEAD
    ).Trim()

    $ExpectedCommit = (
        git rev-parse "${ExpectedTag}^{commit}"
    ).Trim()

    if ($CurrentCommit -ne $ExpectedCommit) {
        throw @"
Falscher Ausgangsstand.

Aktueller Commit:
  $CurrentCommit

Erwarteter Commit:
  $ExpectedCommit

Erwarteter Tag:
  $ExpectedTag

Bitte den Branch zuerst exakt auf den Release-Stand setzen.
"@
    }


    Write-Host "Branch:"
    Write-Host "  $CurrentBranch"
    Write-Host ""

    Write-Host "Basis-Commit:"
    Write-Host "  $CurrentCommit"
    Write-Host ""

    Write-Host "Basis-Tag:"
    Write-Host "  $ExpectedTag"
    Write-Host ""


    # =========================================================================
    # Arbeitsbaum pruefen
    #
    # Das Patch-Script selbst darf untracked sein.
    # Andere Aenderungen sind nicht erlaubt.
    # =========================================================================

    $StatusLines = @(
        git status --porcelain
    )

    $UnexpectedChanges = @(
        $StatusLines |
        Where-Object {
            $_ -notmatch '^\?\? apply-native-audio-patch\.ps1$'
        }
    )

    if ($UnexpectedChanges.Count -gt 0) {

        Write-Host "Unerwartete lokale Aenderungen:"
        $UnexpectedChanges | ForEach-Object {
            Write-Host "  $_"
        }

        throw @"
Der Arbeitsbaum ist nicht sauber.

Der Patch wird nicht auf bereits geaenderte Quelldateien angewendet.
"@
    }


    # =========================================================================
    # Dateien pruefen
    # =========================================================================

    foreach ($File in @(
        $KioskCommandPath,
        $NotificationManagerPath,
        $HAAPIPath
    )) {
        if (-not (Test-Path $File)) {
            throw "Datei nicht gefunden: $File"
        }
    }


    # =========================================================================
    # 1. KioskPushCommand.swift
    # =========================================================================

    Write-Host "Patche KioskPushCommand.swift ..."

    $Kiosk = Normalize-LF (
        [System.IO.File]::ReadAllText(
            $KioskCommandPath
        )
    )


    # -------------------------------------------------------------------------
    # Neue Kommandos
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Neue Kiosk-Audio-Kommandos" `
        -Old @'
    case setVolume = "kiosk_set_volume"
    case setScreensaverMode = "kiosk_set_screensaver_mode"
'@ `
        -New @'
    case setVolume = "kiosk_set_volume"
    case playMedia = "kiosk_play_media"
    case stopMedia = "kiosk_stop_media"
    case setScreensaverMode = "kiosk_set_screensaver_mode"
'@


    # -------------------------------------------------------------------------
    # volume fuer kiosk_play_media erlauben
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Volume-Key fuer playMedia" `
        -Old @'
        case .setVolume:
            return "volume"
        case .showScreensaver, .hideScreensaver, .showCamera, .hideCamera, .setScreensaverMode, .reload,
             .defaultDashboard:
            return nil
'@ `
        -New @'
        case .setVolume, .playMedia:
            return "volume"
        case .showScreensaver, .hideScreensaver, .showCamera, .hideCamera, .stopMedia, .setScreensaverMode,
             .reload, .defaultDashboard:
            return nil
'@


    # -------------------------------------------------------------------------
    # modeKey Switch erweitern
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Mode-Key um Audio-Kommandos erweitern" `
        -Old @'
        case .showScreensaver, .hideScreensaver, .showCamera, .hideCamera, .setBrightness, .setVolume,
             .setScreensaverBrightness, .reload, .defaultDashboard:
            return nil
'@ `
        -New @'
        case .showScreensaver, .hideScreensaver, .showCamera, .hideCamera, .setBrightness, .setVolume,
             .playMedia, .stopMedia, .setScreensaverBrightness, .reload, .defaultDashboard:
            return nil
'@


    # -------------------------------------------------------------------------
    # media_content_id aus Push-Payload lesen
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "mediaContentId Parser" `
        -Old @'
    private static func stringValue(forKey key: String, in userInfo: [AnyHashable: Any]) -> String? {
'@ `
        -New @'
    func mediaContentId(from userInfo: [AnyHashable: Any]?) -> String? {
        guard let userInfo,
              let value = Self.stringValue(forKey: "media_content_id", in: userInfo)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func stringValue(forKey key: String, in userInfo: [AnyHashable: Any]) -> String? {
'@


    # -------------------------------------------------------------------------
    # Titel
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Titel fuer Audio-Kommandos" `
        -Old @'
        case .setVolume:
            return L10n.Kiosk.PushCommand.setVolume
        case .setScreensaverMode:
'@ `
        -New @'
        case .setVolume:
            return L10n.Kiosk.PushCommand.setVolume
        case .playMedia:
            return "Play media"
        case .stopMedia:
            return "Stop media"
        case .setScreensaverMode:
'@


    # -------------------------------------------------------------------------
    # Symbole
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Symbole fuer Audio-Kommandos" `
        -Old @'
        case .setVolume:
            return .speakerWave3Fill
        case .setScreensaverMode:
'@ `
        -New @'
        case .setVolume:
            return .speakerWave3Fill
        case .playMedia:
            return .playCircleFill
        case .stopMedia:
            return .stopCircleFill
        case .setScreensaverMode:
'@


    # -------------------------------------------------------------------------
    # Toast-Farben
    # -------------------------------------------------------------------------

    $Kiosk = Replace-ExactlyOnce `
        -Content $Kiosk `
        -Description "Farben fuer Audio-Kommandos" `
        -Old @'
        case .setVolume:
            return (.white, .teal)
        case .setScreensaverMode:
'@ `
        -New @'
        case .setVolume:
            return (.white, .teal)
        case .playMedia:
            return (.white, .red)
        case .stopMedia:
            return (.white, .gray)
        case .setScreensaverMode:
'@


    Write-Utf8NoBom `
        -Path $KioskCommandPath `
        -Content $Kiosk


    # =========================================================================
    # 2. HAAPI.swift
    #
    # HomeAssistantAPI kann bereits:
    #
    # - HAKit WebSocket
    # - PromiseKit
    # - server.active URL
    # - authentifizierte / unauthentifizierte Downloads
    #
    # Deshalb sitzt media_source/resolve_media hier.
    # =========================================================================

    Write-Host "Patche HAAPI.swift ..."

    $HAAPI = Normalize-LF (
        [System.IO.File]::ReadAllText(
            $HAAPIPath
        )
    )


    $HAAPI = Replace-ExactlyOnce `
        -Content $HAAPI `
        -Description "Media-Source API vor removeOldDownloadDirectory" `
        -Old @'
    private func removeOldDownloadDirectory() {
'@ `
        -New @'
    /// Resolves a Home Assistant media-source URI into a temporary signed URL.
    ///
    /// Example:
    ///
    /// media-source://media_source/local/generated/alarm.mp3
    ///
    /// becomes a short-lived URL such as:
    ///
    /// /media/local/generated/alarm.mp3?authSig=...
    public func resolveMediaSource(
        _ mediaContentId: String,
        expires: Int = 300
    ) -> Promise<String> {
        connectWebSocketIfNeeded()

        let promise: Promise<HAData> = connection.send(
            .init(
                type: "media_source/resolve_media",
                data: [
                    "media_content_id": mediaContentId,
                    "expires": expires,
                ]
            )
        ).promise

        return promise.map { data in
            let resolvedURL: String = try data.decode("url")
            return resolvedURL
        }
    }

    /// Resolves and downloads a Home Assistant media-source item into a
    /// temporary local file.
    ///
    /// The returned file URL can be handed directly to AVAudioPlayer.
    public func downloadMediaSource(
        _ mediaContentId: String,
        expires: Int = 300
    ) -> Promise<URL> {
        resolveMediaSource(
            mediaContentId,
            expires: expires
        )
        .map { [server] resolvedURLString -> URL in

            guard let parsedURL = URL(
                string: resolvedURLString
            ) else {
                throw APIError.cantBuildURL
            }

            if parsedURL.scheme != nil {
                return parsedURL
            }

            guard
                let baseURL =
                    server.info.connection.evaluateActiveURL(),
                let absoluteURL = URL(
                    string: resolvedURLString,
                    relativeTo: baseURL
                )?.absoluteURL
            else {
                throw APIError.cantBuildURL
            }

            return absoluteURL
        }
        .then { [self] mediaURL in

            // media_source/resolve_media returns a signed URL.
            // No Authorization header is required for the file request itself.
            DownloadDataAt(
                url: mediaURL,
                needsAuth: false
            )
        }
    }

    private func removeOldDownloadDirectory() {
'@


    Write-Utf8NoBom `
        -Path $HAAPIPath `
        -Content $HAAPI


    # =========================================================================
    # 3. NotificationManager.swift
    # =========================================================================

    Write-Host "Patche NotificationManager.swift ..."

    $Manager = Normalize-LF (
        [System.IO.File]::ReadAllText(
            $NotificationManagerPath
        )
    )


    # -------------------------------------------------------------------------
    # AVFoundation
    # -------------------------------------------------------------------------

    $Manager = Replace-ExactlyOnce `
        -Content $Manager `
        -Description "AVFoundation Import" `
        -Old @'
import CallbackURLKit
'@ `
        -New @'
import AVFoundation
import CallbackURLKit
'@


    # -------------------------------------------------------------------------
    # Persistenter nativer Player
    # -------------------------------------------------------------------------

    $Manager = Replace-ExactlyOnce `
        -Content $Manager `
        -Description "Kiosk Audio Player Properties" `
        -Old @'
    private lazy var volumeControlView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    override init() {
'@ `
        -New @'
    private lazy var volumeControlView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Persistent native player for kiosk alarm audio.
    ///
    /// Audio deliberately bypasses WKWebView and therefore does not depend
    /// on WebKit autoplay or a browser user gesture.
    private var kioskAudioPlayer: AVAudioPlayer?
    private var kioskAudioFileURL: URL?
    #endif

    override init() {
'@


    # -------------------------------------------------------------------------
    # Audio-Funktionen vor resetPushID einfuegen
    # -------------------------------------------------------------------------

    $Manager = Replace-ExactlyOnce `
        -Content $Manager `
        -Description "Native Kiosk Audio Implementation" `
        -Old @'
    func resetPushID() -> Promise<String> {
'@ `
        -New @'
    private func playKioskMedia(
        _ command: KioskPushCommand,
        userInfo: [AnyHashable: Any]
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)

        guard let mediaContentId =
            command.mediaContentId(from: userInfo) else {
            Current.Log.error(
                "Ignoring \(command.rawValue): missing media_content_id in payload"
            )
            return
        }

        if let requestedVolume = command.level(from: userInfo) {
            setSystemVolume(requestedVolume)
        }

        Current.Log.info(
            "Native kiosk audio requested: \(mediaContentId)"
        )

        Current.sceneManager.webViewControllerPromise
            .done(on: .main) { [weak self] webViewController in

                guard let self else {
                    return
                }

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

                api.downloadMediaSource(
                    mediaContentId,
                    expires: 300
                )
                .done(on: .main) { [weak self] localFileURL in

                    guard let self else {
                        return
                    }

                    Current.Log.info(
                        "Native kiosk media downloaded to \(localFileURL.path)"
                    )

                    self.startKioskAudio(
                        fileURL: localFileURL
                    )
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

        Current.Log.warning(
            "kiosk_play_media is only supported by the native iOS application"
        )

        #endif
    }

    private func startKioskAudio(
        fileURL: URL
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)

        kioskAudioPlayer?.stop()
        kioskAudioPlayer = nil

        if let previousFileURL = kioskAudioFileURL,
           previousFileURL != fileURL {
            try? FileManager.default.removeItem(
                at: previousFileURL
            )
        }

        kioskAudioFileURL = fileURL

        do {
            let audioSession =
                AVAudioSession.sharedInstance()

            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try audioSession.setActive(true)

            let player = try AVAudioPlayer(
                contentsOf: fileURL
            )

            // Hardware/system volume is controlled separately by
            // kiosk_set_volume or the optional volume parameter.
            player.volume = 1.0
            player.numberOfLoops = 0

            guard player.prepareToPlay() else {
                throw NSError(
                    domain: "HomeAssistant.KioskAudio",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AVAudioPlayer prepareToPlay failed",
                    ]
                )
            }

            kioskAudioPlayer = player

            guard player.play() else {

                kioskAudioPlayer = nil

                throw NSError(
                    domain: "HomeAssistant.KioskAudio",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AVAudioPlayer refused to start playback",
                    ]
                )
            }

            Current.Log.info(
                "Native kiosk audio playback started: " +
                    "\(fileURL.lastPathComponent), " +
                    "duration=\(player.duration)s"
            )
        } catch {

            Current.Log.error(
                "Unable to start native kiosk audio: \(error)"
            )

            kioskAudioPlayer = nil

            if let currentFileURL = kioskAudioFileURL {
                try? FileManager.default.removeItem(
                    at: currentFileURL
                )
            }

            kioskAudioFileURL = nil
        }

        #endif
    }

    private func stopKioskMedia() {
        #if os(iOS) && !targetEnvironment(macCatalyst)

        Current.Log.info(
            "Stopping native kiosk audio"
        )

        kioskAudioPlayer?.stop()
        kioskAudioPlayer = nil

        if let currentFileURL = kioskAudioFileURL {
            try? FileManager.default.removeItem(
                at: currentFileURL
            )
        }

        kioskAudioFileURL = nil

        do {
            try AVAudioSession
                .sharedInstance()
                .setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
        } catch {
            Current.Log.warning(
                "Unable to deactivate native kiosk audio session: \(error)"
            )
        }

        #else

        Current.Log.warning(
            "kiosk_stop_media is only supported by the native iOS application"
        )

        #endif
    }

    func resetPushID() -> Promise<String> {
'@


    # -------------------------------------------------------------------------
    # Zentralen Kiosk-Switch erweitern
    # -------------------------------------------------------------------------

    $Manager = Replace-ExactlyOnce `
        -Content $Manager `
        -Description "performKioskCommand Audio Cases" `
        -Old @'
        case .setVolume:
            if let level = command.level(from: userInfo) {
                setSystemVolume(level)
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid volume in payload")
            }
        case .setScreensaverMode:
'@ `
        -New @'
        case .setVolume:
            if let level = command.level(from: userInfo) {
                setSystemVolume(level)
            } else {
                Current.Log.error("Ignoring \(command.rawValue): missing or invalid volume in payload")
            }
        case .playMedia:
            playKioskMedia(
                command,
                userInfo: userInfo
            )
        case .stopMedia:
            stopKioskMedia()
        case .setScreensaverMode:
'@


    Write-Utf8NoBom `
        -Path $NotificationManagerPath `
        -Content $Manager


    # =========================================================================
    # 4. GitHub Actions Workflow
    #
    # Offizieller Release verwendet:
    #
    #   runs-on: macos-26
    #   Xcode 26.4
    #
    # Wir bauen absichtlich UNSIGNED.
    # Signierung erfolgt spaeter separat.
    # =========================================================================

    Write-Host "Erzeuge GitHub-Actions-Build ..."

    if (-not (Test-Path $WorkflowDir)) {
        New-Item `
            -ItemType Directory `
            -Path $WorkflowDir `
            -Force |
            Out-Null
    }


    $Workflow = @'
name: Build Native Kiosk Audio IPA

on:
  workflow_dispatch:
  push:
    branches:
      - native-kiosk-audio

permissions:
  contents: read

env:
  DEVELOPER_DIR: /Applications/Xcode_26.4.app/Contents/Developer

jobs:
  build:
    name: Build unsigned iOS app
    runs-on: macos-26
    timeout-minutes: 90

    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1

      - name: Environment
        run: |
          set -euo pipefail

          echo "Xcode:"
          xcodebuild -version

          echo ""
          echo "Swift:"
          swift --version

          echo ""
          echo "Commit:"
          git rev-parse HEAD

      - name: Resolve Swift packages
        run: |
          set -euo pipefail

          xcodebuild \
            -project HomeAssistant.xcodeproj \
            -scheme App-Debug \
            -resolvePackageDependencies

      - name: Build unsigned device app
        run: |
          set -euo pipefail

          mkdir -p "$PWD/build"

          xcodebuild \
            -project HomeAssistant.xcodeproj \
            -scheme App-Debug \
            -configuration Debug \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "$PWD/build/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            DEVELOPMENT_TEAM="" \
            build \
            | tee "$PWD/build/xcodebuild.log"

      - name: Create unsigned IPA
        run: |
          set -euo pipefail

          PRODUCT_DIR="$PWD/build/DerivedData/Build/Products/Debug-iphoneos"
          APP_PATH="$PRODUCT_DIR/Home Assistant.app"

          if [ ! -d "$APP_PATH" ]; then
            echo "Home Assistant.app not found."
            echo ""
            echo "Available build products:"
            find "$PWD/build/DerivedData/Build/Products" \
              -maxdepth 3 \
              -print
            exit 1
          fi

          rm -rf "$PWD/build/Payload"
          mkdir -p "$PWD/build/Payload"

          ditto \
            "$APP_PATH" \
            "$PWD/build/Payload/Home Assistant.app"

          (
            cd "$PWD/build"

            /usr/bin/zip \
              -qry \
              HomeAssistant-NativeKioskAudio-unsigned.ipa \
              Payload
          )

          echo ""
          echo "Created:"
          ls -lh \
            "$PWD/build/HomeAssistant-NativeKioskAudio-unsigned.ipa"

      - name: Upload IPA
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
        with:
          name: HomeAssistant-NativeKioskAudio-unsigned
          path: build/HomeAssistant-NativeKioskAudio-unsigned.ipa
          if-no-files-found: error

      - name: Upload Xcode build log
        if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
        with:
          name: NativeKioskAudio-xcodebuild-log
          path: build/xcodebuild.log
          if-no-files-found: ignore
'@

    Write-Utf8NoBom `
        -Path $WorkflowPath `
        -Content $Workflow


    # =========================================================================
    # Abschlusspruefung
    # =========================================================================

    Write-Host ""
    Write-Host "Pruefe Git-Diff ..."
    Write-Host ""

    git diff --check

    if ($LASTEXITCODE -ne 0) {
        throw "git diff --check ist fehlgeschlagen."
    }


    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Patch erfolgreich angewendet"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "Geaenderte Dateien:"
    git status --short

    Write-Host ""
    Write-Host "Neue Funktion:"
    Write-Host ""
    Write-Host "  kiosk_play_media"
    Write-Host "  kiosk_stop_media"
    Write-Host ""

    Write-Host "Beispiel-Payload:"
    Write-Host ""
    Write-Host "  message: kiosk_play_media"
    Write-Host "  media_content_id: media-source://media_source/local/generated/alarm.mp3"
    Write-Host "  volume: 100"
    Write-Host ""

    Write-Host "Naechste Git-Befehle:"
    Write-Host ""
    Write-Host "  git add Sources/App/Notifications/KioskPushCommand.swift"
    Write-Host "  git add Sources/App/Notifications/NotificationManager.swift"
    Write-Host "  git add Sources/Shared/API/HAAPI.swift"
    Write-Host "  git add .github/workflows/build-native-kiosk-audio.yml"
    Write-Host "  git add apply-native-audio-patch.ps1"
    Write-Host ""
    Write-Host '  git commit -m "Add native kiosk audio playback"'
    Write-Host ""
    Write-Host "  git push -u origin native-kiosk-audio"
    Write-Host ""

}
finally {
    Pop-Location
}