#!/usr/bin/env python3
"""Safely migrate live HA YAML to PIN-guarded alarm acknowledgements.

Defaults to DRY RUN. Only --apply writes files; each modified original gets a
timestamped backup. All other scripts and automations are left byte-for-byte
unchanged. Run against the ACTUAL /config files, not an older export.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from datetime import datetime, timezone

SCRIPT_START = re.compile(r"(?m)^alarmansage_quittieren:\s*$")
SCRIPT_END = re.compile(r"(?m)^[a-z][a-z0-9_]*:\s*$")
SEQUENCE = re.compile(r"(?m)^  sequence:\s*$")
GUARD_MARKER = "kiosk_alarm.consume_grant"
GUARD_STEPS = """\
  - alias: PIN-Schutz - einmalige serverseitige Freigabe prüfen
    action: kiosk_alarm.consume_grant
    data:
      grant: "{{ kiosk_alarm_grant | default('', true) }}"
    response_variable: kiosk_alarm_authorization
  - alias: Ohne gültige Freigabe keine Alarmquittierung
    condition: template
    value_template: "{{ kiosk_alarm_authorization.allowed | default(false) | bool }}"
"""
BROWSER_MOD_BUTTON = """\
          right_button: QUITTIEREN
          right_button_variant: danger
          right_button_appearance: filled
          right_button_close: false
          right_button_action:
            action: script.alarmansage_quittieren
"""
IPAD_NOTIFICATION_ACTION = """\
                actions:
                - action: ALARM_QUITTIEREN
                  title: QUITTIEREN
                  authenticationRequired: true
                  destructive: true
"""
LEGACY_AUTOMATIONS = {
    "1787816100270": "Alarmansage – Quittierung über Dashboard",
    "1789632695059": "Alarm - Mobile Quittierung",
    "1789633560127": "Alarm - Push Quittierung",
}
AUTOMATION_START = re.compile(r"(?m)^- id: ['\"]?([0-9]+)['\"]?\s*$")


def locate_script_section(source: str) -> tuple[int, int]:
    matches = list(SCRIPT_START.finditer(source))
    if len(matches) != 1:
        raise ValueError(
            "Genau ein Skript alarmansage_quittieren in scripts.yaml erwartet; "
            f"gefunden: {len(matches)}. Nichts geändert."
        )
    start = matches[0].start()
    next_script = SCRIPT_END.search(source, matches[0].end())
    end = next_script.start() if next_script else len(source)
    return start, end


def patch_scripts(source: str) -> tuple[str, list[str]]:
    start, end = locate_script_section(source)
    script = source[start:end]
    notes: list[str] = []

    seq_matches = list(SEQUENCE.finditer(script))
    if len(seq_matches) != 1:
        raise ValueError(
            "Das Quittierungsskript benötigt genau einen Haupt-sequence-Block; "
            f"gefunden: {len(seq_matches)}."
        )
    seq = seq_matches[0]
    after_sequence = script[seq.end():].lstrip("\r\n")
    if GUARD_MARKER in script:
        if not after_sequence.startswith(
            "  - alias: PIN-Schutz - einmalige serverseitige Freigabe prüfen\n"
        ) or "response_variable: kiosk_alarm_authorization" not in script or \
                "kiosk_alarm_authorization.allowed" not in script:
            raise ValueError("Vorhandener PIN-Guard ist unvollständig oder falsch platziert.")
        notes.append("PIN-Guard bereits an erster Stelle: unverändert")
    else:
        if not after_sequence.startswith("  - "):
            raise ValueError("Erste Skript-Aktion nicht erkannt; Sicherheits-Patch verweigert.")
        script = script[:seq.end()] + "\n" + GUARD_STEPS + script[seq.end():]
        notes.append("PIN-Guard als erste Skript-Aktionen eingefügt")

    source = source[:start] + script + source[end:]

    if BROWSER_MOD_BUTTON in source:
        if source.count(BROWSER_MOD_BUTTON) != 1:
            raise ValueError("Mehrere unerwartete Browser-Mod-Aktionsblöcke gefunden.")
        source = source.replace(BROWSER_MOD_BUTTON, "", 1)
        notes.append("Ungeschützte Browser-Mod-QUITTIEREN-Taste entfernt")
    else:
        notes.append("Kein bekannter Browser-Mod-Aktionsblock; manuelle Prüfung erforderlich")

    if IPAD_NOTIFICATION_ACTION in source:
        if source.count(IPAD_NOTIFICATION_ACTION) != 1:
            raise ValueError("Unerwartete Anzahl iPad-Notification-Aktionsblöcke.")
        source = source.replace(IPAD_NOTIFICATION_ACTION, "", 1)
        notes.append("Ungeschützte iPad-Push-Aktion entfernt (nativer PIN-Dialog bleibt)")
    else:
        notes.append("Kein alter iPad-Push-Aktionsblock; manuelle Prüfung erforderlich")

    return source, notes


def patch_automations(source: str) -> tuple[str, list[str]]:
    matches = list(AUTOMATION_START.finditer(source))
    if not matches:
        raise ValueError("automations.yaml enthält keine erkennbaren '- id:'-Blöcke.")
    notes: list[str] = []
    chunks: list[str] = [source[:matches[0].start()]]
    removed = set()

    for index, item in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        chunk = source[item.start():end]
        automation_id = item.group(1)
        if automation_id in LEGACY_AUTOMATIONS:
            if "script.alarmansage_quittieren" not in chunk:
                raise ValueError(
                    f"Automation {automation_id} wurde verändert; Migration verweigert."
                )
            if automation_id in removed:
                raise ValueError(f"Doppelte Automation-ID: {automation_id}")
            removed.add(automation_id)
            notes.append(
                f"Veralteten, nicht autorisierenden Handler entfernt: "
                f"{LEGACY_AUTOMATIONS[automation_id]} ({automation_id})"
            )
            continue
        chunks.append(chunk)

    for key in LEGACY_AUTOMATIONS:
        if key not in removed:
            notes.append(f"Handler {key} nicht vorhanden; keine Änderung nötig")
    return "".join(chunks), notes


def write_with_backup(path: Path, new_content: str, timestamp: str) -> Path | None:
    old = path.read_text(encoding="utf-8")
    if old == new_content:
        return None

    original = path.stat()
    backup = path.with_name(f"{path.name}.pre-kiosk80-{timestamp}.bak")
    if backup.exists():
        raise FileExistsError(f"Backup existiert bereits: {backup}")
    shutil.copy2(path, backup)

    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=path.parent,
            prefix=f".{path.name}.", delete=False
        ) as handle:
            temp_path = Path(handle.name)
            handle.write(new_content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, stat.S_IMODE(original.st_mode))
        if hasattr(os, "chown"):
            try:
                os.chown(temp_path, original.st_uid, original.st_gid)
            except PermissionError:
                pass
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()
    return backup


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/config"))
    parser.add_argument("--apply", action="store_true", help="Dateien ändern (Backup zuerst)")
    args = parser.parse_args()

    scripts_path = args.config / "scripts.yaml"
    automations_path = args.config / "automations.yaml"
    for path in (scripts_path, automations_path):
        if not path.is_file():
            parser.error(f"Nicht gefunden: {path}")

    old_scripts = scripts_path.read_text(encoding="utf-8")
    old_automations = automations_path.read_text(encoding="utf-8")
    new_scripts, script_notes = patch_scripts(old_scripts)
    new_automations, automation_notes = patch_automations(old_automations)
    notes = script_notes + automation_notes
    for note in notes:
        print(f"  - {note}")

    changed = [
        (path, content) for path, previous, content in (
            (scripts_path, old_scripts, new_scripts),
            (automations_path, old_automations, new_automations),
        ) if previous != content
    ]
    print(f"Dateien mit Änderungen: {len(changed)}")
    if not args.apply:
        print("DRY RUN: Nichts geändert. Für die Umsetzung --apply ergänzen.")
        return 0

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for path, content in changed:
        backup = write_with_backup(path, content, stamp)
        print(f"Geändert: {path}")
        print(f"Backup:   {backup}")
    print("Migration geschrieben; HA-Konfigurationsprüfung und Neustart stehen noch aus.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
