# Kiosk Alarm PIN – Home Assistant Integration

**Referenzstand:** `kiosk-alarm-golden-v0.2.1` (Home Assistant), zugehöriger
iPad-Kiosk-Golden-State `kiosk-golden-81` (signierter Build #81, 28.10.2026).

Die PIN-geschützte Alarmquittierung und die Administrator-PIN-Verwaltung
wurden vom Betreiber auf dem Produktivsystem erfolgreich getestet. Das
petrolfarbene `mdi:shield-lock`-Icon ist im `brand/`-Ordner enthalten;
die Anzeige auf dem Produktivsystem wurde nicht gesondert bestätigt.
Der HA-Code und die iOS-App sind **separat versioniert**.

## Updates ohne Änderung am Golden State #81

Die HA-Integration liegt in diesem Repository unter
`ha/kiosk_alarm/custom_components/kiosk_alarm/`. Nur **diesen Ordner**
nach `/config/custom_components/kiosk_alarm/` übertragen. Das ist
**kein separates GitHub-Repository**. iOS-Build #81 muss dafür nicht neu
gebaut werden.

Vor einer Aktualisierung ein Backup der HA-Konfiguration anlegen. Bestehende
`configuration.yaml`, `secrets.yaml`, `scripts.yaml`,
`automations.yaml` und `.storage/` **nicht** mit Beispieldateien
überschreiben. HA nach dem Austausch der Integrationsdateien neu starten.

## Sechsstellige PIN – serverseitig verbindlich

Unter **Einstellungen → Geräte & Dienste → Kiosk Alarm PIN → Konfigurieren**
können nur HA-Administratoren die PIN ändern. Beide Eingaben werden mit
einem Passwort-Selektor verdeckt dargestellt. Die Integration akzeptiert
**genau sechs ASCII-Ziffern (0–9)**, einschließlich führender Nullen.
Zu kurze, zu lange, nichtnumerische oder voneinander abweichende Eingaben
werden **vor dem Hashing und Speichern** abgewiesen.

Hinweis: Der Standard-Home-Assistant-`TextSelector` bietet aktuell
keine `maxlength`-Option. Mehr als sechs Zeichen lassen sich daher
gegebenenfalls **eingeben**, aber **nicht speichern**. Diese serverseitige
Prüfung ist die maßgebliche Sicherheitsgrenze. Die PIN wird nicht als
Entity-Zustand angelegt. Der generierte PBKDF2-SHA256-Hash mit zufälligem
Salt wird im HA-Config-Entry gespeichert, nicht die Klartext-PIN.

Der Endpoint `POST /api/kiosk_alarm/acknowledge` akzeptiert ebenfalls
ausschließlich sechs ASCII-Ziffern; drei falsche Versuche sperren die
PIN-Prüfung fünf Minuten. Die Admin-Konfiguration nutzt die administrativen
HA-Config-Flow-Endpunkte, **keinen** frei aufrufbaren Änderungsdienst.


## Sicherheitsarchitektur

Der HA-Endpunkt POST /api/kiosk_alarm/acknowledge verlangt eine vorhandene HA-Anmeldung und eine sechsstellige PIN.
Der HA-Server prüft den PBKDF2-SHA256-Hash. Drei Fehlversuche sperren global für fünf Minuten; die Sperre überlebt Neustarts.
Ein erfolgreich geprüfter Aufruf erzeugt ein einmaliges, zehn Sekunden gültiges 256-Bit-Freigabetoken.
Die ersten zwei Aktionen in script.alarmansage_quittieren müssen dieses Token über kiosk_alarm.consume_grant abfragen.
Ohne gültige Freigabe wird das Skript abgebrochen. Das bestehende Stoppen von Echo/Kiosk/Android sowie das Rücksetzen der Alarmwarteschlange bleiben unverändert.

Die beiden bisherigen Mobile-App-Quittierungsautomationen und der Dashboard-Handler werden bei der Migration entfernt.
Der neue Handler erlaubt die Ereignisse ALARM_QUITTIEREN und input_button.alarmansage_quittieren nur für explizit eingetragene trusted_user_ids.
Die iPad-Benutzer-ID darf niemals auf dieser Liste stehen. Ohne Eintrag wird eine Smartphone-Quittierung aus Sicherheitsgründen verweigert.

## Sicherheitsgrenzen

Der Guard schützt den Quittierungsablauf, aber NICHT jeden denkbaren anderen Weg, den Alarm zu manipulieren.
Ein HA-Konto mit allgemeinen Steuerrechten kann beispielsweise input_boolean.alarmansage_aktiv direkt ausschalten.
HA-Standardbenutzer sind nicht automatisch schreibgeschützt. Die iPads müssen mit eigenem, minimal berechtigtem HA-Zugang betrieben werden.
Das Benutzer- und Dashboard-Berechtigungsmodell muss gesondert geprüft werden; die PIN ersetzt diese Prüfung nicht.
Ein Einbruch muss VOR einer möglichen Quittierung an Smartphones gemeldet und dauerhaft protokolliert werden.
Quittieren darf eine Alarmanlage nicht entschärfen. Administratoren mit Vollzugriff können die Schutzmechanismen grundsätzlich umgehen.

## Installation nur nach Prüfung des tatsächlichen Live-Standes

1. Kopiere ha/kiosk_alarm/custom_components/kiosk_alarm nach /mnt/apps/homeassistant/custom_components/kiosk_alarm.
2. Erzeuge den PIN-Hash lokal; PIN oder Klartext nicht in GitHub/Chat posten:

        python3 - <<'PY'
        import getpass, hashlib, os
        pin = getpass.getpass('6-stellige PIN: ')
        if len(pin) != 6 or not pin.isascii() or not pin.isdigit():
            raise SystemExit('Genau sechs ASCII-Ziffern erforderlich.')
        salt = os.urandom(16)
        rounds = 600000
        digest = hashlib.pbkdf2_hmac('sha256', pin.encode('ascii'), salt, rounds)
        print('pbkdf2_sha256$' + str(rounds) + '$' + salt.hex() + '$' + digest.hex())
        PY

3. Ergänze in /mnt/apps/homeassistant/configuration.yaml den folgenden Block:

        kiosk_alarm:
          pin_hash: !secret kiosk_alarm_pin_hash
          script_entity_id: script.alarmansage_quittieren
          trusted_user_ids: []
          mobile_action: ALARM_QUITTIEREN
          dashboard_button_entity_id: input_button.alarmansage_quittieren

4. Speichere den erzeugten Hash als kiosk_alarm_pin_hash in der lokalen secrets.yaml. Die Smartphone-HA-Benutzer-IDs erst nach Prüfung in trusted_user_ids eintragen.
5. Prüfe vor jedem Schreibzugriff die echten Konfigurationsdateien und den Trockenlauf:

        python3 apply_guards.py --config /mnt/apps/homeassistant

6. Prüfe die gemeldeten Änderungen. Der Installer erhält die übrigen YAML-Abschnitte und erstellt beim Schreiben Zeitstempel-Backups.
   Der ältere YAML-Export vom 17.09.2026 ist keine bestätigte aktuelle Live-Konfiguration!
7. Nur nach Prüfung in einem Wartungsfenster anwenden:

        python3 apply_guards.py --config /mnt/apps/homeassistant --apply

8. Vor dem HA-Neustart Konfiguration prüfen:

        docker exec homeassistant python -m homeassistant --script check_config --config /config

9. Kontrolliert HA neu starten und auf echter Instanz prüfen: Guard erste Aktionen, direkten Skriptaufruf abweisen, PIN falsch/richtig, Sperre, Smartphone-Aktion, Alarmstatus.

## API und Tests

POST /api/kiosk_alarm/acknowledge mit HA-Bearer und JSON-Body (pin = sechsstellige Zeichenfolge).
HTTP 200 {ok:true}: nur wenn der Alarm nach Skriptende tatsächlich inaktiv ist.
HTTP 400: ungültiges Format, 401: keine Anmeldung, 403: falscher PIN, 409: kein aktiver Alarm, 429: gesperrt, 503: Fehler.
Nach erfolgreicher Quittierung wird HA-Ereignis kiosk_alarm_acknowledged mit Quelltyp ausgelöst.

Linux-Tests:

        python -m compileall -q ha/kiosk_alarm
        python -m unittest discover -s ha/kiosk_alarm/tests -p 'test_*.py' -v

Die GitHub-CI prüft Python-Syntax, PIN-Hash-Logik, die Authentifizierungs-Guards, YAML-Migration, Passwort-Felder, Service-Metadaten und die Brand-Dateien. Diese Unit-Tests ersetzen keine vollständigen Home-Assistant-Integrationstests; der Betreiber hat die produktive PIN-Verwaltung und den iPad-Build #81 praktisch bestätigt.

## Integrations-Icon (`mdi:shield-lock`)

Ab **Home Assistant 2026.3** lädt Home Assistant das Icon direkt aus
`custom_components/kiosk_alarm/brand/`. Die PNG-Dateien heißen
`icon.png` (256 × 256) und `icon@2x.png` (512 × 512); Hintergrund
transparent, Schild in Petrol/Türkis (`#008C9B`). Kein Brands-PR oder
zusätzlicher Manifest-Eintrag notwendig. Lizenz und editierbare Quelle
liegen im selben Ordner.

Für eine bestehende Installation **nur den Ordner `brand/`** nach
`/config/custom_components/kiosk_alarm/brand/` kopieren. Danach HA neu
starten und gegebenenfalls den Browsercache aktualisieren. Die bestehende
PIN, der Hash und die Adminrechte werden dabei nicht verändert.
