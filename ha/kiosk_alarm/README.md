# Kiosk #80: geschützte Alarmquittierung (Teststand)

## Status und Sicherheit

**Noch nicht produktiv aktivieren.** Der neue Endpoint schützt nur seinen eigenen Aufruf. Das bestehende
`script.alarmansage_quittieren` ist per HA-Script-Service für angemeldete Clients weiterhin direkt aufrufbar,
sofern der Benutzer dazu berechtigt ist. **Damit ist die gewünschte Einbruchssicherheit noch nicht erreicht.**
Vor Produktivsetzung muss die Quittierlogik so umgebaut werden, dass kein iPad-Konto einen ungeschützten
Alternativweg zur Quittierung nutzen kann. Auch `kiosk_hide_alarm` kann lokal die Oberfläche verbergen;
das ist keine gesicherte Alarmquittierung.

## Bereitstellung der Test-API

1. `ha/kiosk_alarm/custom_components/kiosk_alarm` nach `/config/custom_components/kiosk_alarm` kopieren.
2. Für den **Test-PIN**, der später geändert werden muss, lokal folgenden Hash erzeugen:

```sh
python3 - <<'PY'
import getpass, hashlib, os
pin = getpass.getpass("6-stellige Test-PIN: ")
if len(pin) != 6 or not pin.isascii() or not pin.isdigit():
    raise SystemExit("PIN muss aus 6 ASCII-Ziffern bestehen.")
salt = os.urandom(16)
rounds = 600000
digest = hashlib.pbkdf2_hmac("sha256", pin.encode("ascii"), salt, rounds)
print(f"pbkdf2_sha256${rounds}${salt.hex()}${digest.hex()}")
PY
```

3. In `configuration.yaml` eintragen:

```yaml
kiosk_alarm:
  pin_hash: !secret kiosk_alarm_pin_hash
  script_entity_id: script.alarmansage_quittieren
```

4. Den erzeugten Hash unter `kiosk_alarm_pin_hash:` in der lokalen `secrets.yaml` hinterlegen.
5. Home Assistant Konfiguration prüfen, dann kontrolliert neu starten.
6. API benötigt eine bestehende HA-Anmeldung via Bearer-Token:
   `POST /api/kiosk_alarm/acknowledge` mit JSON `{"pin":"123456"}` (Beispielwert,
   **niemals in Produktion verwenden**). Rückgabe `{"ok":true}` nur bei korrekter PIN und
   erfolgreichem Startaufruf des Zielskripts. Fehler: 400/401/403/429/503.

Der Zähler für Fehlversuche und das Sperrende werden unter `.storage/kiosk_alarm_pin_attempts`
persistiert. Drei falsche Versuche sperren fünf Minuten. PIN wird nicht geloggt. Die
Sperre gilt für den Endpoint global, nicht pro Nutzer oder Gerät.

## Offene Sicherheitsarbeiten vor dem Rollout

- Alternativzugriffe auf das bisherige Quittierungsskript unterbinden.
- Gesicherte Prüfung des aktiven Alarmereignisses und eindeutige Zuordnung einer Quittierung
  zum jeweiligen Ereignis, inklusive Protokollierung und Push an Smartphones.
- Verhindern, dass ein fremder HA-Benutzer den Alarmstatus oder das Alarm-Dashboard direkt
  manipulieren kann.
- Sicherheits- und Regressionstests auf einer getrennten Home-Assistant-Testinstanz.
- Reale iPad-Tests einschließlich HA-Neustart, falscher PIN, Sperre und Offline-Verhalten.

Golden State: `kiosk-golden-79`. Neuer Testzweig: `feature/kiosk80-alarm-pin`.
