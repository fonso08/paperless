# Paperless GDrive + Gemini: Integrationsentwurf (nicht produktiv getestet)

## Umfang

Die drei Cron-Einstiegspunkte bleiben `01_gdrive_scan_to_pool.sh`, `02_scanpool_to_paperless.sh`, `03_archive_to_gdrive.sh`. 01 filtert PDF/JPG/JPEG/PNG. 02 behält seine bisherige Rolle (genau ein Paperless-Upload). 03 führt nach erfolgreich abgeschlossener OCR Gemini-Analyse und Metadatenübernahme aus; bei unsicheren Vorschlägen wird `QUARANTINE` gesetzt. Nach manueller Freigabe erfolgt im nächsten 03-Lauf die Übernahme und Archivierung.

Die Weboberfläche ist ein separater Dienst, **kein zusätzlicher Cron-Schritt**. Sie nutzt Paperless-Benutzernamen und Passwort zur Token-Anmeldung am Paperless-Endpunkt `/api/token/`. Ob dieser Endpunkt und die Berechtigungen in der konkreten Installation verfügbar sind, muss vor Inbetriebnahme getestet werden. Das ist keine automatische Single-Sign-On-Übernahme einer bestehenden Browser-Sitzung.

## Wichtige Einschränkungen vor der Freigabe

1. **NICHT produktiv aktivieren, bevor die End-to-End-Tests auf einer Testkopie erfolgreich sind.** Shell-Syntax und Python-Kompilierung sind geprüft, aber kein Zugriff auf das echte Paperless, Gemini oder rclone war möglich.
2. Bestehende Jobs im Status `PAPERLESS_DONE` bleiben beim bisherigen Archivpfad; neu importierte Jobs wechseln in `GEMINI_PENDING`.
3. Die Weboberfläche schreibt Freigaben direkt in Proposal und Jobdatei. Der gemeinsame Lock zwischen Web und Cron muss vor Produktivbetrieb noch abgesichert werden; gleichzeitig laufende Freigaben und Cron-Schreibzugriffe könnten sonst kollidieren.
4. Ein Login über Paperless-Token bestätigt die Identität; eine gesonderte Berechtigungsprüfung für Administrator-/Bearbeiterrollen ist noch nicht implementiert. Bis dahin nur einem vertrauenswürdigen Paperless-Benutzerkreis Zugriff gewähren.
5. Der Webdienst muss an die **konkrete LAN-IP** gebunden und über Host-Firewall auf das Heimnetz beschränkt werden. Geplante Bind-Adresse ist `0.0.0.0`. Keine Portfreigabe am Router.
6. In der Metadata-Konfiguration muss `GEMINI_API_KEY` dem Cron-Kontext sicher zur Verfügung stehen. Secrets nicht in den ZIP-Dateien hinterlegen.
7. Dateinamen sind auf 80 Zeichen einschließlich Erweiterung begrenzt. Der Entwurf hängt die Paperless-Dokument-ID zur Eindeutigkeit an.
8. Google-Drive-Archivierung erfolgt weiterhin durch die bestehende `03`-Upload-/Verifikations- und Löschlogik; diese ist vor der Aktivierung mit Testdateien zu validieren.

## Zustandsverzeichnisse

- GDrive-Jobs: `/media/BlueDisc3/PAPERLESS/state/jobs`
- GDrive-Temp: `/media/BlueDisc3/PAPERLESS/state/tmp`
- Gemini-Vorschläge: `/media/BlueDisc3/PAPERLESS/state/metadata/proposals`
- Gemini-Analysen: `/media/BlueDisc3/PAPERLESS/state/metadata/analysis`

**State-Migration nicht automatisch ausführen.** Cron und Webdienst vorher stoppen, dann mit Backup und `rsync -a` aus den bisherigen `paperless_gdrive/state/` und `paperless_metadata/state/` in die neuen Pfade kopieren; Jobanzahl und Hashes vergleichen, erst danach Konfiguration umstellen. Die alten Verzeichnisse zunächst erhalten. `mkdir -p` wird beim regulären Start durch die vorhandenen Bibliotheken ausgeführt, aber Migration und Berechtigungen müssen vorab stimmen.

## Prüfung ohne produktiven Upload

```bash
bash -n paperless_gdrive/scripts/01_gdrive_scan_to_pool.sh
bash -n paperless_gdrive/scripts/02_scanpool_to_paperless.sh
bash -n paperless_gdrive/scripts/03_archive_to_gdrive.sh
python3 -m py_compile quarantine_web/app.py
```

Empfohlene Integrationsfälle: sicheres Gemini-Ergebnis, `requires_review=true`, fehlende Hauptkategorie, Gemini-Timeout, vorhandener Korrespondent, PDF/JPEG/PNG, Kollision bei 80 Zeichen, Cron-Neustart zwischen jedem Statuswechsel, Quarantänefreigabe und verifizierter Upload vor Löschung.

## Weboberfläche (Testumgebung)

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r quarantine_web/requirements.txt
export QUARANTINE_SESSION_SECRET="$(openssl rand -hex 32)"
export PAPERLESS_STATE_DIR=/media/BlueDisc3/PAPERLESS/state
export PAPERLESS_URL=http://rasp2:1888
export QUARANTINE_BIND=0.0.0.0
python3 quarantine_web/app.py
```

`0.0.0.0:1889` ist nur mit wirksamer Firewall-Regel fuer das Heimnetz zulaessig; keine Router-Portweiterleitung. Die Anwendung speichert Paperless-API-Tokens nur im Arbeitsspeicher; Neustart meldet Benutzer ab.

## Geänderte Dateien

- `paperless_gdrive/config/paperless-gdrive.conf`: `STATE_DIR` auf BlueDisc3.
- `paperless_gdrive/scripts/01_gdrive_scan_to_pool.sh`: PDF/JPG/JPEG/PNG-Filter.
- `paperless_gdrive/scripts/03_archive_to_gdrive.sh`: Gemini- und Quarantäne-Statuspfad sowie Namens-/Ordnerbildung.
- `paperless_metadata/scripts/lib/common.sh`: Metadata-State auf BlueDisc3.
- `quarantine_web/app.py` und `requirements.txt`: Weboberfläche als separater Dienst.

`02_scanpool_to_paperless.sh` bleibt bewusst unverändert, da die Dokument-ID bereits durch `03` nach erfolgreichem Paperless-Task ermittelt wird. Keine zusätzlichen Cron-Skripte.

## Update: Webport 1889 (Testpaket)

- Gewuenschte Erreichbarkeit: `http://rasp2:1889`.
- Dienst bindet `0.0.0.0:1889`, Beispiel in `quarantine_web/compose.example.yml`.
- Bind an `0.0.0.0` ist NICHT auf das Heimnetz beschraenkt: Host-Firewall und Router-Konfiguration muessen dies durchsetzen.
- Vor Produktivbetrieb: gemeinsame Lock-Datei fuer Cron/Web, Paperless-Berechtigungspruefung, CSRF fuer Login und Freigaben, und Authentifizierung im Browser testen.
- Bestehende Paperless-Zugangsdaten werden zur Anmeldung am Paperless-Token-Endpunkt verwendet; das ist kein Single Sign-On der vorhandenen Paperless-Browser-Sitzung.
- Dieses Paket ist eine Testvorlage und darf noch nicht die produktiven Cron-Skripte ersetzen.
