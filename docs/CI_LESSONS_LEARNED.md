# CI Lessons Learned — Home Assistant iOS / Kiosk

Stand: 2026-10-13  
Geltungsbereich: `jaipur2001/homeassistant-iOS`, insbesondere Kiosk-/Doorbell-Integrationsarbeiten.

## Grundprinzipien

1. **Erst schnelle Prüfungen, dann teure Xcode-Tests.** Kein Testlauf wegen vermeidbarer Formatierungs-, YAML- oder Konfigurationsfehler.
2. **Bereits verifizierte Ergebnisse erhalten.** Erfolgreiche Builds, Caches und Referenzcommits weiterverwenden; nicht grundlos neu bauen.
3. **Ursache vor Änderung.** Zuerst Job, fehlerhaften Schritt, erste aussagekräftige Fehlermeldung und betroffene Dateien lesen.
4. **Keine Scheinerfolge.** „Committed“ ist nicht „CI erfolgreich“; eine übersprungene Coverage-Messung ist kein bestandenes Coverage-Gate.
5. **Produktivcode nicht für grüne Checks verbiegen.** Tests sollen Verhalten absichern. Coverage-Anforderung nicht heimlich absenken oder ausklammern.
6. **Stabilen Kiosk-Branch schützen.** Änderungen zuerst im Integrationsbranch; Merge erst bei verifizierter CI und gezielter Funktionsprüfung.

## Historische Befunde und Gegenmaßnahmen

| Lauf | Verifizierter Befund | Lesson / Prävention |
| --- | --- | --- |
| CI #20–#24 | Wiederholte fehlgeschlagene bzw. abgebrochene Läufe, darunter lange Testlaufzeiten; nicht jede Einzelursache hier rekonstruiert | Logs und Status je Lauf sichern; Testlaufzeit begrenzen, schneller Preflight vor macOS-Runner |
| CI #25 | Erfolgreicher CI-Lauf, SHA `5337aa9d85fb3cc1dbc210e993e2926b1284b042` | Als funktionierende Referenz beibehalten; erfolgreiche Artefakte und Cache-Eingangsbedingungen nicht ohne Grund verwerfen |
| CI #26–#28 | Fehlgeschlagene Integrationsläufe; Ursachen nicht abschließend in diesem Dokument ausgewertet | Bei erneutem Auftreten Job-Logs auswerten, bevor Code geändert wird |
| CI #29 | `test` fehlgeschlagen: `WebViewControllerTests.testFinishedNavigationClearsClientCertificateIssue`; Fatal Error durch implizit entpackte fehlende `webView` in der Kiosk-Policy; zusätzlich Simulator-Diagnose-Timeout (600 s) | Optional-Sicherheit bei WebView-Lifecycle; Unit-Test für fehlende WebView; Simulator-Hänger von echter Testassertion unterscheiden |
| CI #30 | Lint und Tests erfolgreich; Patch Coverage nur **58,06 % (180/310)** statt 90 % | Coverage als eigene Schranke behandeln, fehlende Zeilen gezielt testen |
| CI #31 | `lint` / SwiftFormat fehlgeschlagen; fehlende Leerzeile bei `// MARK:` und überflüssige Leerzeile vor `}`; Tests übersprungen | SwiftFormat 0.53.1 mit **projektspezifischer** `.swiftformat` vor Commit |
| CI #32 | Lint und Tests erfolgreich; Coverage **67,74 % (210/310)**; u. a. `NotificationManager.swift` 30/95 und `CameraStreamServer.swift` 2/33 | Tests für fachliche Pfade ausbauen; für asynchrones RTP/RTSP echte Test-Seams und Fake-Verbindungen nutzen |
| CI #33 | SwiftFormat fehlgeschlagen: doppelte Leerzeile vor `// MARK:`; Tests übersprungen | Konsequente Formatprüfung **nach der letzten Dateiänderung** und vor jedem Commit |
| CI #35 | 7 fehlgeschlagene Testfälle in ZoneManager und App-Shortcut-Tests; Xcode-Simulator-Diagnose dauerte weitere 600 s | Gemeinsam genutzten `Current`-Zustand aufräumen; betroffene Suites zuerst isolieren |
| CI #36 | YamlLint fehlgeschlagen: Zeile mit 127 Zeichen bei Grenzwert 120 | Vor jedem Workflow-Commit YamlLint und Zeilenlänge kontrollieren |
| CI #37 | Diagnosegruppen erfolgreich: Zone 12/12, Shortcuts 6/6, kombiniert 18/18 bei abgeschalteter Xcode-Parallelisierung | Gezielte Diagnose validiert die Fälle, ersetzt aber weder vollständigen Unit-Testlauf noch Coverage-Messung |
| CI #41 | Alle Unit-Tests und statischen Checks erfolgreich; Patch Coverage 89,59 % (284/317) knapp unter 90 % | Drei bislang ungetestete Zeilen der AVCC/H.264-Längenfeldverarbeitung gezielt mit gültigen und defekten NAL-Paketen abdecken, Coverage-Grenze unverändert lassen |
| CI #42 | SwiftLint und SwiftFormat grün, 4.508/4.509 Unit-Tests bestanden; der WebView-Render-Test wartete 5 s auf WKWebView und schlug fehl, während eine relative Bildressource von `example.com` geladen werden konnte | WebKit-Tests mit Inline-SVG offline gestalten, damit `isLoading` nicht von Netzwerkzugriffen abhängt; Coverage nach bestandenem Testlauf messen |
| CI #43 | SwiftFormat grün; ein SwiftUI-Test `NotificationSettingsViewTests.rendersWithForceCloseWarningRow` hing beim Layout in einem temporären `UIWindow` und erreichte das 180-s-Testlimit; der Simulator meldete Service-Hub-Verbindungsprobleme. LCOV aus dem Artefakt ergab nach eigener Auswertung 288/320 = 90,00 % Patch Coverage, jedoch keine gültige grüne CI | UIHostingController/Window-Layout nicht für reine Plattform- und Index-Prüfungen aufrufen. Stattdessen den `View.body`-Builder ohne Fenster auswerten und UI/Index-Bedingungen deterministisch prüfen. Echte E2E-UI-Prüfungen separat behandeln |
| CI #38 | 4.506 Unit-Tests, nur `AppIconShortcutItemsUpdaterTests.resolvesNameAndArea()` fehlgeschlagen. Test wartete lediglich auf einen beliebigen Shortcut und las den zuvor gesetzten `test.pending`-Platzhalter. Zusätzlich 600 s Simulator-Sysdiagnose | Asynchrone Tests müssen auf **die erwartete Identität und den erwarteten Inhalt** warten, nicht auf `isEmpty == false`; Xcode-Diagnose mit `-collect-test-diagnostics never` abschalten |

## Unverzichtbarer Preflight vor jedem Code-Commit

- [ ] Diff lesen: Nur beabsichtigte Dateien/Zeilen, keine Seiteneffekte auf Kiosk, Türstation oder reguläres Home Assistant.
- [ ] `git diff --check` ohne Beanstandungen.
- [ ] Bei Swift-Änderungen **exakt** `ghcr.io/nicklockwood/swiftformat:0.53.1` mit `.swiftformat` und `--lint` ausführen; im PR-Workflow wird eine Dateiliste geprüft.
- [ ] SwiftLint mit `.swiftlint.yml` prüfen (SwiftLint und SwiftFormat sind unterschiedliche Gates).
- [ ] Bei Workflow-/YAML-Änderungen `yamllint --strict` und das vorhandene Ruby/RuboCop-Gate prüfen.
- [ ] Neue Tests: Swift-Sichtbarkeit, Target-Mitgliedschaft, Test-Doubles, Actor-Isolation und deterministisches Verhalten prüfen.
- [ ] Coverage-relevante Änderungen: verfügbare Coveragedaten und exakte Diffbasis verwenden; keine 90-%-Prognose ohne Messung.
- [ ] Erst nach bestandenem Preflight den Commit/PR aktualisieren und teure Xcode-Tests starten.
- [ ] GitHub-Jobs einzeln überprüfen; erst nach Abschluss den Lauf als erfolgreich bezeichnen.

### SwiftFormat-Fallstricke (bereits mehrfach aufgetreten)

- **Eine** Leerzeile zwischen Methoden.
- **Eine** Leerzeile vor und nach `// MARK:`.
- Keine aufeinanderfolgenden Leerzeilen.
- Keine Leerzeile unmittelbar vor dem schließenden `}` eines Typs.
- Diese Regeln sind eine Gedächtnisstütze; **maßgeblich bleibt der tatsächliche SwiftFormat-Lauf** mit Repository-Konfiguration, nicht manuelles Augenmaß.

Beispiel für einen schnellen lokalen SwiftFormat-Check (Linux/Docker, vom Repository-Root):

```bash
git diff --name-only --diff-filter=ACMR -- '*.swift' > .swiftformat-changed-files
if [ -s .swiftformat-changed-files ]; then
  docker run --rm -v "$PWD:$PWD" -w "$PWD" \
    ghcr.io/nicklockwood/swiftformat:0.53.1 \
    --lint --config .swiftformat --filelist .swiftformat-changed-files
fi
rm -f .swiftformat-changed-files
```

**Achtung:** Der Befehl betrachtet uncommittete Änderungen. Für gestagte oder bereits committed Dateien ist die Dateiliste aus dem jeweiligen `git diff --cached` bzw. Commit-Diff zu erzeugen; in GitHub-PRs nutzt `.github/workflows/ci.yml` die eigene Dateiauswahl.

## Workflow-Optimierung

1. **Lint-first:** `test` hängt von `lint` ab, damit kein teurer Xcode-Runner für einen schon statisch ungültigen Commit startet.
2. **Gezielt testen:** Lokal/auf einem geeigneten macOS-Runner zunächst die betroffene Testklasse bzw. Testmethode ausführen. Nur danach die vollständige Testsuite.
3. **Coverage ehrlich auswerten:** `Patch coverage` benötigt eine erfolgreiche Messung; bei Testabbruch ist ein erfolgreich beendeter Coverage-Job ggf. lediglich **übersprungen**. Nach erfolgreichen Tests ohne LCOV muss der Coverage-Job fehlschlagen.
4. **SPM-/DerivedData-Cache:** Nur bei unveränderten relevanten Eingangsbedingungen wiederverwenden. Bei geänderten Package-Pins veraltete vorkompilierte Module entsprechend Workflow-Logik entfernen.
5. **Xcode-/Simulator-Diagnosen:** Timeout beim Einsammeln von Simulator-Diagnosen nicht mit dem ursprünglichen Testfehler verwechseln.
6. **Keine unbedachten Workflow-Pushes:** Auch Dokumentations-Commits können bei offenem PR CI auslösen. Wenn reine Docs ohne lange Tests gepflegt werden sollen, erst separat eine überprüfte und sichere Pfadfilter-Regel entwickeln.

## Vorlage für künftige Fehler

| Feld | Eintrag |
| --- | --- |
| CI-Link / Run / Commit | |
| Fehlgeschlagener Job / Schritt | |
| Erste relevante Fehlermeldung | |
| Primärursache (belegt) | |
| Änderung / Commit | |
| Schnellste reproduzierbare Vorprüfung | |
| Erneute Verifikation / Ergebnis | |
| Dauerhafte Schutzmaßnahme | |

## Quellen im Repository

- `.github/workflows/ci.yml` — Gates, Test- und Coverage-Reihenfolge
- `.swiftformat` und `.swiftlint.yml` — Formatierungs- und Lintregeln
- `fastlane/lanes/testing.rb` — Test-Lanes, Simulator- und Timeoutparameter
- `Tools/diff_coverage.py` — Berechnung der Patch Coverage
- GitHub Actions: CI [#25](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38257618698), [#29](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38375075948), [#30](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38381888584), [#31](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38390763311), [#32](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38391146496), [#33](https://github.com/jaipur2001/homeassistant-iOS/actions/runs/38399201419)

**Pflegepflicht:** Jeden neuen Fehlertyp mit Ursache, Prävention und verifiziertem Ergebnis ergänzen. Bei wiederholten Fehlern insbesondere dokumentieren, warum der Preflight sie nicht erkannt hat.

## CI #37: bestätigte Test-Isolation und Rückkehr zur regulären CI

Die fokussierten Tests bestanden ohne Xcode-Parallelisierung. Das ist ein Indiz für
Zustands- oder Timing-Wechselwirkungen, noch **kein** eindeutiger Ursachennachweis.
Die reguläre Testsuite bleibt das maßgebliche Gate. Die Diagnose-Lane kann bei
Bedarf separat wiederverwendet werden. Globale `Current`-Test-Doubles müssen
nach jedem Test zuverlässig auf den vorherigen Zustand zurückgesetzt werden.

## CI #38: Konkrete Änderungen zur Vermeidung langer Fehlerschleifen

- `AppIconShortcutItemsUpdaterTests.resolvesNameAndArea()` wartet auf den tatsächlichen
  Shortcut-Typ `appIconShortcut.1|entity|light.kitchen`, bevor Titel und Bereich geprüft werden.
- `test_xcodebuild_arguments` enthält `-collect-test-diagnostics never`. Dadurch
  entfällt die automatische langwierige Simulator-Sysdiagnose bei Testfehlern.
  Normale Testfehler, Konsolenlogs und die `.xcresult`-Datei bleiben erhalten.
- Der LCOV-Konverter läuft nach einem fehlgeschlagenen, abgeschlossenen Testlauf
  best effort weiter. Falls er eine verwertbare Coverage-Datei erzeugt,
  wird diese in `test-logs` für die nächste Diagnose archiviert.
  Die **verbindliche Patch-Coverage-Prüfung** läuft weiterhin nur mit der
  regulären Coverage-Datei aus erfolgreich abgeschlossenen Tests.
- `CI success` ist erst dann wahr, wenn die vollständige Testsuite und die
  tatsächliche 90-%-Patch-Coverage-Prüfung erfolgreich sind.

## CI #42: Offline-WebKit-Fixtures

Eine Testseite mit `<img src="icon.png">` und einer HTTPS-`baseURL` kann beim
`loadHTMLString` echte Netzwerkanfragen auslösen. Wird gleichzeitig auf das Ende
von `WKWebView.isLoading` gewartet, hängt der Test ungewollt von externen
Ressourcen ab. Für die Render-Erkennung deshalb lokal eingebettete HTML-/SVG-
Inhalte verwenden, auch in anderen WebView-Tests. Kein pauschales Erhöhen der
Timeouts und keine Deaktivierung der inhaltlichen Assertion.

## CI #43: Keine UIWindow-Layouts fuer reine Bedingungs-Tests

`NotificationSettingsViewTests` hatte zwei rendernde Smoke-Tests ohne eine
inhaltliche Assertion ueber den dargestellten Zeileninhalt. Ein solcher Test
blockierte den Simulator 180 Sekunden lang. Beide Tests evaluieren stattdessen
den `View.body`-Builder ohne `UIWindow` und pruefen explizit die
plattformabhaengigen Suchindizes. Die vorhandenen beiden Suchindex-Tests
bleiben erhalten.

Die aus `test-logs` extrahierte `coverage.lcov` von CI #43 enthaelt 288
abgedeckte unter 320 geaenderten ausfuehrbaren Zeilen gegen Merge-Base
`62f05b7fd397dcd627a2d11bc325e6b61a028796`: genau **90,00 %**.
Dies ist eine eigene Nachrechnung mit unveraenderter Messlogik; ein offizieller
Coverage-Gate-Erfolg erfordert weiterhin eine vollstaendig gruene Test-Suite.
