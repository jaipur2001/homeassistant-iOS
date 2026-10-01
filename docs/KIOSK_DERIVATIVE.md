# Home Assistant Kiosk derivative

This fork contains a dedicated iPad kiosk derivative of the Home Assistant iOS app.

## Branch model

- `upstream-main`: mirror point for the official `home-assistant/iOS` main branch.
- `kiosk-main`: production branch for the kiosk derivative.
- `kiosk-recovery-signals`: historical integration/recovery branch; no longer the production branch.
- short-lived feature branches: optional for larger kiosk changes.

## Production baseline

Initial kiosk-main baseline:

- commit: `1c13699e0edd7ea522a29d49c33a71063b389758`
- validated by Kiosk IPA Build #16
- Build #16 result: success

The baseline includes the native kiosk features that were validated on the supervised iPad:

- kiosk WebSocket/local-push command path
- native media playback via `kiosk_play_media` / `kiosk_stop_media`
- native full-screen alarm overlay via `kiosk_show_alarm` / `kiosk_hide_alarm`
- customizable alarm title, area, source, priority, message and button text from Home Assistant
- alarm acknowledgement through a Home Assistant script entity
- alarm display lifecycle with temporary maximum brightness
- dimming/screensaver suppression while the alarm is visible
- restoration of the prior brightness/screensaver state after acknowledgement
- native camera overlay and existing kiosk controls

## Build policy

Normal source commits must not trigger a signed IPA build.

The production workflow is `.github/workflows/kiosk_ipa.yml`.

A signed IPA build is triggered only by changing:

`.github/kiosk-build-trigger`

on `kiosk-main`, or by explicitly using `workflow_dispatch`.

This keeps expensive Xcode archive/signing work separate from normal source changes.

## Upstream sync policy

Upstream source:

`https://github.com/home-assistant/iOS`

For every upstream sync:

1. Refresh `upstream-main` to the desired official upstream commit.
2. Compare `upstream-main` against `kiosk-main`.
3. Merge or rebase upstream changes into a temporary integration branch.
4. Resolve kiosk conflicts there.
5. Run source-level validation/tests.
6. Trigger exactly one signed IPA build after the integration result is ready.
7. Test the IPA on a supervised iPad.
8. Only then advance `kiosk-main`.

Never move `kiosk-main` directly to a new upstream commit without validating the kiosk-specific behavior.

## Kiosk code organization

New kiosk-specific functionality should be isolated as much as practical from upstream code.

Target structure:

```text
Sources/App/Kiosk/
  KioskCommandRouter.swift
  KioskAudioController.swift
  KioskAlarmController.swift
  KioskAlarmView.swift
  KioskDisplayController.swift
  KioskCameraController.swift
```

Existing modifications that currently live in upstream files can be migrated into these modules incrementally. Do not rewrite working code solely for cosmetic reasons.

## Compatibility contract with Home Assistant

The kiosk derivative currently accepts these native commands:

- `kiosk_show_screensaver`
- `kiosk_hide_screensaver`
- `kiosk_show_camera`
- `kiosk_hide_camera`
- `kiosk_set_brightness`
- `kiosk_set_volume`
- `kiosk_play_media`
- `kiosk_stop_media`
- `kiosk_show_alarm`
- `kiosk_hide_alarm`
- `kiosk_set_screensaver_mode`
- `kiosk_set_screensaver_brightness`
- `kiosk_reload`
- `kiosk_default`

Alarm payload fields:

- `alarm_title`
- `alarm_area`
- `alarm_source`
- `alarm_priority`
- `alarm_message`
- `alarm_button_text`
- `ack_entity_id`

Home Assistant remains the source of alarm semantics and text. The app is responsible for native presentation, playback and kiosk display behavior.

## Release naming

Use derivative release identifiers such as:

`2026.10-kiosk.1`

Increment the kiosk suffix for derivative-only releases. When adopting a new upstream Home Assistant app baseline, update the year/month portion accordingly.
