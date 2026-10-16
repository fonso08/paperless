# Projektübergabe: Paperless-ngx, Gemini-Metadaten und Google-Drive-Automatisierung

**Stand: 16. Oktober 2026**

## 1. Projektziel

Ich möchte die bestehende Google-Drive-Automatisierung für Paperless-ngx um die bereits entwickelte Gemini-Metadatenanalyse, automatische Kategorisierung, Tag-Erkennung, Dateiumbenennung und Archivierung erweitern.

Ziel ist ein möglichst automatischer Prozess. Nur Dokumente mit unsicheren, unvollständigen oder widersprüchlichen Metadaten sollen manuell geprüft werden müssen.

Der gesamte Ablauf soll zuverlässig und nachvollziehbar sein. Quelldateien dürfen erst gelöscht werden, wenn der Upload in Google Drive erfolgreich abgeschlossen und verifiziert wurde und die ursprüngliche Drive-Datei nachweislich gelöscht werden konnte.

## 2. Systemumgebung und verbindliche Pfade

Raspberry Pi:
- Hostname: `rasp2`
- Paperless-URL: `http://rasp2:1888`
- Quarantäne-Weboberfläche: `http://rasp2:1889`

Projektverzeichnisse:
- Google-Drive-Automatisierung: `/home/pi/docker/paperless/paperless_gdrive`
- Gemini-Metadatenprojekt: `/home/pi/docker/paperless/paperless_metadata`
- Quarantäne-Webanwendung: `/home/pi/docker/paperless/quarantine_web`

Weitere wichtige Pfade:
- Paperless-Datenverzeichnis: `/media/BlueDisc3/PAPERLESS`
- Scanpool: `/media/BlueDisc3/PAPERLESS/scanpool`
- Job-Dateien: `/media/BlueDisc3/PAPERLESS/state/jobs`
- Gemini-Vorschläge: `/media/BlueDisc3/PAPERLESS/state/metadata/proposals`

**Wichtig:** Der verbindliche Pfad der Google-Drive-Automatisierung lautet `/home/pi/docker/paperless/paperless_gdrive`. Nicht versehentlich `/home/pi/docker/paperless/paperless_gdrive_v7` verwenden.

Die Umgebung verwendet Docker, Paperless-ngx, PostgreSQL, Valkey und rclone. Als Gemini-Modell wird derzeit `gemini-3.5-flash-lite` verwendet.

## 3. Gewünschter Gesamtprozess

Der vorgesehene Ablauf lautet:

1. Eine neue Datei aus `gdrive:SCAN` erkennen.
2. Die Datei in den lokalen Scanpool übernehmen.
3. Das Dokument an Paperless-ngx übergeben.
4. Gemini analysiert den Inhalt und schlägt Metadaten vor.
5. Die Vorschläge anhand definierter Qualitätskriterien validieren.
6. Bei geeigneten Vorschlägen die Metadaten automatisch in Paperless übernehmen.
7. Dateinamen anhand der bestehenden Namensregeln erzeugen.
8. Das Dokument nach `gdrive:PAPERLESS/Hauptkategorie/Korrespondent/` archivieren.
9. Den Upload durch einen Vergleich der Dateigrößen überprüfen.
10. Erst nach bestätigtem Upload die ursprüngliche Datei in `gdrive:SCAN` löschen und die Löschung überprüfen.
11. Anschließend die lokale Quelldatei löschen.
12. Den Job mit nachvollziehbarem Status abschließen.

Unsichere oder fehlerhafte Fälle sollen in Quarantäne verbleiben und über die Weboberfläche geprüft werden können.

## 4. Hauptkategorien

Die bestätigten 13 Hauptkategorien sind:

- Wohnen
- Finanzen
- Versicherungen
- Gesundheit
- Beruf
- Behörden
- Verträge
- Einkäufe
- Bildung
- Mobilität
- Familie
- Freizeit
- Sonstiges

Weitere Tags beschreiben den Dokumenttyp oder den konkreten Inhalt. Beispiele sind `Rechnung`, `Handwerker`, `Kündigung` oder `Mitgliedschaft`.

Die gewünschte Archivstruktur ist:

`gdrive:PAPERLESS/Hauptkategorie/Korrespondent/Dateiname.pdf`

Wenn kein verlässlicher Korrespondent ermittelt werden kann, soll `SONSTIGES` als Verzeichnisname verwendet werden.

Dokumentdatum und Korrespondent dürfen nicht erfunden werden. Wenn kein zuverlässiges Datum vorliegt, muss die bestehende Dateinamensregel greifen, ohne ein Datum zu erfinden.

## 5. Gemini-Metadatenprojekt

Projektpfad:

`/home/pi/docker/paperless/paperless_metadata`

Wichtige Komponenten:

- `scripts/01_analyze.sh`: analysiert Dokumente und erstellt Gemini-Vorschläge.
- `scripts/03_apply_proposals.sh`: validiert und übernimmt Vorschläge in Paperless.
- `config/classification_prompt.txt`: enthält die Klassifizierungsregeln.
- `state/proposals/`: enthält die Analysevorschläge im Projektverzeichnis.
- Die zentral verwendeten Vorschläge der Drive-Automatisierung liegen unter `/media/BlueDisc3/PAPERLESS/state/metadata/proposals/`.

Das Analyse-Skript arbeitet zunächst ohne Änderungen an Paperless. Änderungen werden durch das Apply-Skript mit `--apply` ausdrücklich ausgelöst.

Die Vorschläge enthalten relevante Felder wie:

- `.proposal.primary_tag`
- `.proposal.additional_tags`
- `.proposal.correspondent`
- `.proposal.document_date`
- `.proposal.confidence`
- `.proposal.requires_review`
- `.proposal.review_decision`
- `.proposal.validation_warnings`

Die Angaben liegen unter `.proposal`, nicht auf der obersten Ebene des JSON-Objekts.

Ein Vorschlag kann zusätzlich Informationen zu manueller Prüfung und Übernahme enthalten, etwa `.manual_review.approved_at` und `.applied`.

## 6. Zentrales Archivierungsskript

Datei:

`/home/pi/docker/paperless/paperless_gdrive/scripts/03_archive_to_gdrive.sh`

Die Funktion `metadata_process_job()` integriert die Gemini-Metadaten in den Archivierungsablauf.

Der bestehende Code:
- prüft, ob ein Vorschlag vorhanden ist;
- startet gegebenenfalls `01_analyze.sh`;
- kontrolliert die Gültigkeit des Vorschlags;
- ruft `03_apply_proposals.sh --id ... --apply` auf, wenn die Übernahme noch aussteht;
- liest die Metadaten aus Paperless;
- bestimmt Hauptkategorie, Korrespondent und Archivdateinamen;
- setzt die Jobinformationen für die anschließende Archivierung.

Der Dateiname wird aus Dokumentdatum, Kategorie, Korrespondent und Titel erzeugt. Die Dokument-ID wird zur eindeutigen Zuordnung ergänzt.

Das Archivierungsskript verwendet Jobstatuswerte wie:
- `PAPERLESS_DONE`
- `ARCHIVE_PROCESSING`
- `ARCHIVE_FAILED`
- `COMPLETE`
- `QUARANTINE`
- `GEMINI_FAILED`

Die konkreten Statusübergänge müssen bei Änderungen am bestehenden Code berücksichtigt werden.

## 7. Sicherheitsregeln für die Archivierung

Die bestehenden Sicherheitsprüfungen dürfen nicht geschwächt werden.

Der Upload erfolgt mit rclone. Danach werden lokale und entfernte Dateigröße verglichen. Nur bei erfolgreicher Verifikation wird `ARCHIVE_VERIFIED=true` gesetzt.

Anschließend wird die ursprüngliche Datei in Google Drive gelöscht und die Löschung überprüft. Erst danach wird die lokale Quelldatei entfernt.

Wichtige Jobfelder:
- `ARCHIVE_TARGET`
- `ARCHIVE_FILE`
- `ARCHIVE_VERIFIED`
- `GDRIVE_SOURCE_DELETED`
- `LOCAL_SOURCE_DELETED`
- `STATUS`
- `ERROR_TYPE`
- `ERROR_MESSAGE`
- `COMPLETED_AT`

Eine erfolgreiche Archivierung muss unter anderem durch folgende Werte nachvollziehbar sein:

- `ARCHIVE_VERIFIED=true`
- `GDRIVE_SOURCE_DELETED=true`
- `LOCAL_SOURCE_DELETED=true`
- `STATUS=COMPLETE`

Bei Fehlern darf keine ungesicherte Löschung erfolgen.

## 8. Erfolgreicher produktiver End-to-End-Test mit Dokument 687

Am 16.10.2026 wurde der vollständige produktive Ablauf für Dokument 687 ausdrücklich freigegeben und erfolgreich abgeschlossen.

Job-ID:

`e05a5c8c-2a1c-4a14-a874-f0d8137f1b15`

Die ursprüngliche Datei in Google Drive war:

`gdrive:SCAN/Zuletzt am 16.10.2026, 13:25:26 geprüft.pdf`

Die lokale Scanpool-Datei war:

`/media/BlueDisc3/PAPERLESS/scanpool/Zuletzt am 16.10.2026, 13-25-26 geprüft.pdf`

Gemini schlug folgende Metadaten vor:
- Dokument-ID: `687`
- Hauptkategorie: `Wohnen`
- zusätzliche Tags: `Rechnung`, `Handwerker`
- Korrespondent: `André Peters`
- Dokumentdatum: `2012-10-08`
- Konfidenz: `0.95`
- `requires_review=false`
- `review_decision=no_check_needed`
- keine Validierungswarnungen

Der Archivpfad lautete:

`gdrive:PAPERLESS/Wohnen/André_Peters/20121008_Wohnen_André_Peters_Zuletzt_am_16.10.2026,_13-25-26_geprüft_ID-687.pdf`

Der Test verlief erfolgreich:
1. Vorschlag wurde übernommen.
2. Metadaten wurden in Paperless angewendet.
3. Archivdateiname und Zielverzeichnis wurden erzeugt.
4. Datei wurde nach Google Drive hochgeladen.
5. Lokale und entfernte Dateigröße wurden erfolgreich verglichen: jeweils `1.510.433` Byte.
6. Die ursprüngliche Drive-Datei wurde gelöscht und die Löschung überprüft.
7. Die lokale Quelldatei wurde gelöscht.
8. Der Job wurde mit Status `COMPLETE` abgeschlossen.

Endstatus:
- `ARCHIVE_VERIFIED=true`
- `GDRIVE_SOURCE_DELETED=true`
- `LOCAL_SOURCE_DELETED=true`
- `STATUS=COMPLETE`
- `ERROR_TYPE` leer
- `ERROR_MESSAGE` leer
- `COMPLETED_AT=2026-10-16T15:06:19+02:00`

**Wichtige Einschränkung:** Dieser Test wurde mit einem ausdrücklich manuell freigegebenen Dokument durchgeführt. Er bestätigt den produktiven Ende-zu-Ende-Ablauf, aber noch nicht die automatische Verarbeitung ohne manuelle Freigabe.

Dokument 687 ist bereits abgeschlossen. Die Quelldateien wurden gelöscht und dürfen nicht erneut als Test verwendet werden.

## 9. Wichtigste offene Aufgabe: Automatische Freigabe sicherer Vorschläge

Derzeit verlangt `metadata_process_job()` im Skript `03_archive_to_gdrive.sh` einen Zeitstempel in:

`.manual_review.approved_at`

Fehlt dieser Zeitstempel, wird der Job in Quarantäne gestellt. Damit werden auch sichere Vorschläge ohne manuelle Freigabe blockiert.

Der bestehende Code prüft außerdem bereits:
- `proposal.requires_review == false`
- `proposal.review_decision == "no_check_needed"`
- leere `proposal.validation_warnings`
- vorhandene `proposal.primary_tag`

Die manuelle Freigabe soll künftig nur für Dokumente erforderlich sein, die tatsächlich eine manuelle Prüfung benötigen.

### Gewünschte automatische Verarbeitung

Ein Dokument darf ohne manuelle Freigabe weiterlaufen, wenn:
- ein vollständiger, gültiger Vorschlag vorhanden ist;
- eine gültige Hauptkategorie gesetzt ist;
- die Konfidenz ausreichend hoch ist;
- keine Validierungswarnungen vorliegen;
- `requires_review=false` gilt;
- `review_decision=no_check_needed` gilt;
- die notwendigen Metadaten plausibel sind.

### Weiterhin Quarantäne

Eine manuelle Prüfung bleibt notwendig, wenn:
- die Konfidenz zu niedrig oder nicht vorhanden ist;
- die Hauptkategorie fehlt oder ungültig ist;
- Validierungswarnungen vorhanden sind;
- Angaben widersprüchlich oder unvollständig sind;
- Gemini eine Prüfung verlangt;
- die Analyse, Validierung oder Übernahme technisch fehlschlägt.

Eine Konfidenzgrenze von beispielsweise `0.90` ist ein möglicher Ausgangspunkt, aber noch keine endgültig bestätigte Projektentscheidung. Zunächst soll geprüft werden, ob es bereits einen entsprechenden Konfigurationswert oder weitere relevante Qualitätsregeln gibt.

## 10. Nächste Schritte

Bitte arbeite in dieser Reihenfolge weiter:

1. Den aktuellen Code rund um `metadata_process_job()` in `scripts/03_archive_to_gdrive.sh` prüfen, insbesondere die Prüfung von `.manual_review.approved_at`.
2. Die vorhandene Konfiguration und weitere Skripte nach bereits existierenden Konfidenzgrenzen oder Regeln für automatische Freigaben durchsuchen.
3. Vor Änderungen eine Sicherung des aktuellen Skripts erstellen.
4. Die kleinstmögliche Änderung vorbereiten, damit sichere Vorschläge ohne manuelle Freigabe verarbeitet werden können.
5. Den Diff überprüfen und sicherstellen, dass die bestehende Quarantänelogik für unsichere Fälle erhalten bleibt.
6. Ein anderes, noch nicht verarbeitetes Dokument auswählen, dessen Quelle noch existiert.
7. Zunächst die Metadatenentscheidung und Statusübergänge kontrolliert testen.
8. Den vollständigen produktiven Ablauf nur mit entsprechender Freigabe testen.
9. Dokumentieren, ob sichere Dokumente automatisch durchlaufen und unsichere weiterhin in Quarantäne landen.

Das Ziel ist ein zuverlässiger automatischer Ablauf mit möglichst wenigen manuellen Prüfungen. Es soll kein unnötiger Neuaufbau stattfinden.

## 11. Arbeitsweise

Bitte:
- pragmatisch und schrittweise vorgehen;
- zunächst den tatsächlichen Code prüfen, statt Annahmen zu treffen;
- bestehende Skripte möglichst gezielt ändern;
- konkrete Shell-Befehle bereitstellen, die auf dem Raspberry Pi ausgeführt werden können;
- vor produktiven Änderungen Backups und nachvollziehbare Diffs verwenden;
- keine Pfade oder Dateiinhalte erfinden;
- die Quarantänelogik für unsichere Dokumente erhalten;
- die Upload-Verifikation und Löschsicherung niemals umgehen;
- keine produktiven Änderungen oder Löschungen ohne entsprechende Freigabe durchführen.

**Beginne im neuen Chat mit der gezielten Prüfung der aktuellen Freigabeprüfung in `03_archive_to_gdrive.sh`.** Die erste Aufgabe ist, die vorhandene Logik und Konfiguration zu lesen und anschließend eine möglichst kleine, sichere Änderung für die automatische Verarbeitung geeigneter Vorschläge vorzubereiten.
