# Projektübergabe: Paperless-ngx, Gemini-Metadaten und Google-Drive-Automatisierung

**Stand: 27. Oktober 2026**

## 1. Projektziel

Die bestehende Google-Drive-Automatisierung für Paperless-ngx soll mit der Gemini-Metadatenanalyse, automatischen Kategorisierung, Tag-Erkennung, Dateiumbenennung und Archivierung zusammenarbeiten.

Ziel ist ein möglichst automatischer und zuverlässiger Prozess. Nur Dokumente mit unsicheren, unvollständigen, widersprüchlichen oder technisch fehlerhaften Metadaten sollen manuell geprüft werden müssen.

Der gesamte Ablauf muss nachvollziehbar bleiben. Quelldateien dürfen erst gelöscht werden, wenn der Upload nach Google Drive erfolgreich abgeschlossen und verifiziert wurde und die ursprüngliche Drive-Datei nachweislich gelöscht werden konnte.

Zusätzlich gibt es eine Quarantäne-Weboberfläche, über die unsichere Metadatenvorschläge manuell bearbeitet und freigegeben werden können.

Ein weiterer Bestandteil ist die Behandlung von Dokumenten mit dem Tag `noLLM`. Diese Dokumente dürfen nicht an Gemini übergeben werden, sollen aber trotzdem in den vorgesehenen Prüf- und Archivierungsprozess integriert werden.

**Grundprinzipien:**
- Bestehende Skripte möglichst gezielt erweitern.
- Zunächst den tatsächlichen Code untersuchen, bevor Änderungen vorgenommen werden.
- Keine automatischen Freigaben bei unsicheren oder unvollständigen Metadaten.
- Keine Änderungen an Paperless ohne den dafür vorgesehenen Freigabeprozess.
- Keine produktiven Löschungen ohne ausdrückliche Freigabe und erfolgreiche Sicherheitsprüfungen.

## 2. Systemumgebung und verbindliche Pfade

### Raspberry Pi

- Hostname: `rasp2`
- Paperless-URL: `http://rasp2:1888`
- Quarantäne-Weboberfläche: `http://rasp2:1889`

### Projektverzeichnisse

Google-Drive-Automatisierung:

`/home/pi/docker/paperless/paperless_gdrive`

Gemini-Metadatenprojekt:

`/home/pi/docker/paperless/paperless_metadata`

Quarantäne-Webanwendung:

`/home/pi/docker/paperless/quarantine_web`

### Weitere wichtige Pfade

Paperless-Datenverzeichnis:

`/media/BlueDisc3/PAPERLESS`

Scanpool:

`/media/BlueDisc3/PAPERLESS/scanpool`

Job-Dateien:

`/media/BlueDisc3/PAPERLESS/state/jobs`

Zentrale Metadatenvorschläge:

`/media/BlueDisc3/PAPERLESS/state/metadata/proposals`

Die Metadatenanalyse verwendet außerdem ein projektinternes Verzeichnis:

`/home/pi/docker/paperless/paperless_metadata/state/proposals`

**Wichtig:** Der verbindliche Pfad der Google-Drive-Automatisierung lautet `/home/pi/docker/paperless/paperless_gdrive`. Nicht versehentlich `/home/pi/docker/paperless/paperless_gdrive_v7` verwenden.

Die Umgebung verwendet Docker, Paperless-ngx, PostgreSQL, Valkey und rclone. Als Gemini-Modell wird derzeit `gemini-3.5-flash-lite` verwendet.

## 3. Gewünschter Gesamtprozess

Der vorgesehene Ablauf ist:

1. Neue Dateien in `gdrive:SCAN` erkennen.
2. Dateien in den lokalen Scanpool übernehmen.
3. Dokumente an Paperless-ngx übergeben.
4. Prüfen, ob das Dokument mit `noLLM` markiert ist.
5. Bei normalen Dokumenten Gemini zur Analyse verwenden, sofern noch kein gültiger Vorschlag vorhanden ist.
6. Bei `noLLM` keine Gemini-Analyse durchführen und gegebenenfalls einen Platzhalter für die manuelle Prüfung erzeugen.
7. Metadatenvorschläge anhand definierter Qualitätskriterien validieren.
8. Geeignete Vorschläge nach den festgelegten Freigaberegeln übernehmen.
9. Unsichere Fälle in Quarantäne stellen.
10. Dateinamen anhand der bestehenden Namensregeln erzeugen.
11. Dokumente nach `gdrive:PAPERLESS/Hauptkategorie/Korrespondent/` archivieren.
12. Den Upload durch einen Vergleich der Dateigrößen verifizieren.
13. Erst nach bestätigtem Upload die ursprüngliche Datei in `gdrive:SCAN` löschen und die Löschung überprüfen.
14. Anschließend die lokale Quelldatei löschen.
15. Den Job mit einem nachvollziehbaren Status abschließen.

Bei technischen Fehlern, ungültigen Vorschlägen oder erforderlicher manueller Prüfung darf der Ablauf nicht unkontrolliert fortgesetzt werden.

## 4. Hauptkategorien und Archivstruktur

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

Weitere Tags beschreiben Dokumenttyp oder Inhalt, beispielsweise Rechnung, Handwerker, Kündigung oder Mitgliedschaft.

Die gewünschte Archivstruktur lautet:

`gdrive:PAPERLESS/Hauptkategorie/Korrespondent/Dateiname.pdf`

Wenn kein verlässlicher Korrespondent ermittelt werden kann, soll `SONSTIGES` als Verzeichnisname verwendet werden.

Dokumentdatum und Korrespondent dürfen nicht erfunden werden. Wenn kein zuverlässiges Datum vorliegt, muss die bestehende Dateinamensregel greifen, ohne ein Datum zu erfinden.

## 5. Gemini-Metadatenprojekt

Projektpfad:

`/home/pi/docker/paperless/paperless_metadata`

Wichtige Komponenten:

- `scripts/01_analyze.sh`: Analysiert Dokumente und erstellt Vorschläge.
- `scripts/03_apply_proposals.sh`: Validiert und übernimmt Vorschläge in Paperless.
- `config/classification_prompt.txt`: Enthält die Klassifizierungsregeln.
- `state/proposals/`: Enthält die projektinternen Analysevorschläge.

Die zentrale Ablage der Vorschläge für die Drive-Automatisierung befindet sich unter:

`/media/BlueDisc3/PAPERLESS/state/metadata/proposals/`

Das Analyse-Skript arbeitet grundsätzlich ohne Änderungen an Paperless. Das Apply-Skript nimmt Änderungen erst bei ausdrücklicher Verwendung von `--apply` vor.

### Aufbau der Vorschläge

Relevante Felder befinden sich unter `.proposal`, insbesondere:

- `.proposal.primary_tag`
- `.proposal.additional_tags`
- `.proposal.correspondent`
- `.proposal.document_date`
- `.proposal.confidence`
- `.proposal.requires_review`
- `.proposal.review_decision`
- `.proposal.validation_warnings`

Weitere Felder können den Analyseprovider, das Modell, den Analysezeitpunkt und den Übernahmestatus dokumentieren.

Die manuelle Freigabe wird unter anderem über `.manual_review.approved_at` dokumentiert.

**Wichtig:** Die Felder unter `.proposal` liegen im JSON-Objekt verschachtelt. Bei der Verarbeitung darf nicht versehentlich angenommen werden, dass `primary_tag` oder `requires_review` auf der obersten JSON-Ebene stehen.

## 6. Neue Funktion: Dokumente mit `noLLM`

Dokumente mit dem Tag `noLLM` sollen nicht an Gemini gesendet werden.

Der Tag kennzeichnet Dokumente, die ausdrücklich ohne LLM-Analyse behandelt werden sollen. Das Fehlen einer Gemini-Analyse darf nicht dazu führen, dass diese Dokumente unberücksichtigt bleiben.

### Gewünschtes Verhalten

1. `01_analyze.sh` erkennt den Tag `noLLM`.
2. Für diese Dokumente wird keine Gemini-Anfrage ausgelöst.
3. Existiert bereits ein gültiger Vorschlag, darf dieser nicht unnötig überschrieben werden.
4. Fehlt ein Vorschlag, soll ein Platzhalter für die manuelle Bearbeitung erzeugt werden.
5. Der Platzhalter muss eindeutig als manuell zu bearbeitender Vorschlag erkennbar sein.
6. Ein Platzhalter darf nicht als gültiger, automatisch freigegebener Gemini-Vorschlag behandelt werden.
7. Die erforderlichen Job- und Vorschlagsdateien müssen für die nachfolgenden Prozesse vorhanden sein.
8. Die weitere Verarbeitung erfolgt über die vorgesehenen Freigabe- und Quarantäneregeln.

### Beispiel: Platzhalter für Dokument 1076

Am 27. Oktober 2026 wurde folgender Vorschlag für Dokument 1076 vorgelegt:

Datei:

`/media/BlueDisc3/PAPERLESS/state/metadata/proposals/1076.json`

Wesentliche Inhalte:

- `document_id`: `1076`
- Titel: `scan`
- Originaldateiname: `scan.pdf`
- Dokumentdatum: `2026-10-27`
- Provider: `none`
- Modell: `manual-noLLM`
- `requires_review`: `true`
- `review_decision`: `manual_check`
- Warnung: `Tag noLLM: keine Gemini-Analyse; manuelle Bearbeitung erforderlich`
- `applied`: `false`

Der Platzhalter enthält bewusst keine automatisch bestimmte Hauptkategorie. Die fehlende Hauptkategorie muss durch die manuelle Bearbeitung ergänzt werden.

Dieser Vorschlag ist **kein automatisch freigegebener Vorschlag**. Er darf nicht allein deshalb angewendet oder archiviert werden, weil die JSON-Datei vorhanden ist.

### Noch offene Frage

Dokument 1076 wurde in der Quarantäne-Weboberfläche zunächst nicht angezeigt.

Die Ursache ist noch nicht abschließend geklärt. Der Vorschlag ist vorhanden, aber das Vorhandensein der JSON-Datei allein garantiert nicht, dass die Weboberfläche das Dokument in ihrer Liste darstellt.

Deshalb muss zuerst die tatsächliche Filter- und Ladefunktion der Webanwendung geprüft werden. Eine künstlich eingetragene Hauptkategorie oder eine andere Änderung, die das Dokument lediglich sichtbar macht, ist keine geeignete Lösung, solange dadurch falsche Metadaten oder eine ungewollte Freigabe entstehen könnten.

Die bisherige Arbeit konzentriert sich auf `01_analyze.sh` und die Anzeige in der Quarantäne-Weboberfläche. `fix_nollm_optional_tag.sh` ist ausdrücklich nicht Bestandteil des aktuellen Änderungsumfangs.

## 7. Zentrales Archivierungsskript und Jobverarbeitung

Das Archivierungsskript integriert die Metadatenanalyse in den Drive-Prozess.

Der aktuell verbindliche Projektpfad ist:

`/home/pi/docker/paperless/paperless_gdrive`

Vor Änderungen muss geprüft werden, welches Archivierungsskript tatsächlich produktiv verwendet wird. In älteren Projektbeschreibungen wurde folgender Dateiname genannt:

`/home/pi/docker/paperless/paperless_gdrive/scripts/03_archive_to_gdrive.sh`

Im aktuellen Projektverlauf existieren außerdem Skripte mit abweichenden Dateinamen. Deshalb darf nicht ohne Prüfung angenommen werden, dass der ältere Dateiname noch der aktive Einstiegspunkt ist.

Die Metadatenverarbeitung übernimmt grundsätzlich folgende Aufgaben:

- Vorhandensein eines Vorschlags prüfen.
- Gegebenenfalls die Analyse starten.
- Vorschlag validieren.
- Erforderliche Übernahme in Paperless auslösen.
- Metadaten aus Paperless lesen.
- Hauptkategorie und Korrespondent bestimmen.
- Archivdateinamen erzeugen.
- Jobstatus und Archivierungsinformationen aktualisieren.
- Bei Unsicherheit in Quarantäne wechseln.

Die konkreten Statusübergänge müssen vor Änderungen am produktiven Code geprüft werden.

### Relevante Jobstatuswerte

Im Projekt kommen unter anderem folgende Statuswerte vor:

- `PAPERLESS_DONE`
- `ARCHIVE_PROCESSING`
- `ARCHIVE_FAILED`
- `COMPLETE`
- `QUARANTINE`
- `GEMINI_FAILED`
- `REVIEW_APPROVED`

Die genaue Bedeutung und die zulässigen Übergänge sind anhand der aktuell verwendeten Skripte zu prüfen.

## 8. Neue Funktion: Manuelle Quarantäneprüfung über die Weboberfläche

Die Quarantäne-Webanwendung befindet sich unter:

`/home/pi/docker/paperless/quarantine_web`

Die Weboberfläche ist unter folgender Adresse vorgesehen:

`http://rasp2:1889`

Die zentrale Datei ist:

`/home/pi/docker/paperless/quarantine_web/app.py`

Die Anwendung soll Dokumente anzeigen, die manuell geprüft werden müssen. Die verantwortliche Person kann Metadaten korrigieren und einen Vorschlag ausdrücklich freigeben.

### Bekannte Funktionen im Code

Die bisherige Codeprüfung hat folgende Anhaltspunkte ergeben:

- Zeile 30: Definition des Vorschlagsverzeichnisses `PROPOSALS`.
- Zeile 41: Verweis auf `scripts/03_apply_proposals.sh`.
- Zeile 178: Prüfung auf Jobstatus `QUARANTINE`.
- Zeile 404: Erneute Prüfung des Quarantänestatus.
- Zeile 414: Erzeugung eines Eintrags mit einer Kategorie aus `proposal.get('primary_tag', '')`.
- Zeilen 649–653: Erzeugung beziehungsweise Aktualisierung eines Vorschlags mit `requires_review=False`.
- Zeilen 668–685: Prüfung des Jobstatus und Eintragung der manuellen Freigabe; dabei wird auch `REVIEW_APPROVED` gesetzt.
- Zeilen 726–741: Anzeige von `requires_review` und Eingabefeld für die Hauptkategorie.
- Zeilen 810–863: Validierung und Verarbeitung eines Freigabevorgangs.
- Zeile 972: Anzeige der Hauptkategorie.

Diese Zeilenangaben stammen aus einer vorliegenden `grep`-Ausgabe. Sie ersetzen keine Prüfung des vollständigen aktuellen Codes und müssen bei der nächsten Analyse im Zusammenhang betrachtet werden.

### Geplantes Freigabeverhalten

Bei einer manuellen Freigabe sollen:

1. die Metadaten auf Vollständigkeit und Gültigkeit geprüft werden;
2. die Hauptkategorie und gegebenenfalls weitere Metadaten ergänzt werden;
3. die vorgesehenen Freigabefelder gesetzt werden;
4. die Freigabe in `.manual_review.approved_at` dokumentiert werden;
5. der Jobstatus nachvollziehbar aktualisiert werden;
6. die regulären Apply- und Archivierungsprozesse weiterarbeiten können.

Die manuelle Freigabe darf nicht die Sicherheitsprüfungen für Upload, Verifikation und Löschung umgehen.

### Offene Diagnose: Dokument 1076 wird nicht angezeigt

Der nächste Schritt ist die gezielte Untersuchung der relevanten Abschnitte in `app.py`, insbesondere:

- etwa Zeilen 160–190: Ermittlung der Quarantänejobs;
- etwa Zeilen 390–425: Zusammenstellung der angezeigten Dokumente;
- etwa Zeilen 630–690: Verarbeitung einer manuellen Freigabe;
- etwa Zeilen 800–875: Validierung und Freigabevorgang.

Dabei ist zu klären:

- Ob die Weboberfläche ausschließlich Jobs mit `STATUS=QUARANTINE` anzeigt.
- Wie die JSON-Vorschläge geladen und ausgewertet werden.
- Ob die Weboberfläche den verschachtelten Aufbau des Vorschlags korrekt berücksichtigt.
- Ob ein Vorschlag ohne `primary_tag` angezeigt werden kann.
- Ob Dokument 1076 einen zugehörigen Job besitzt und dieser tatsächlich den Status `QUARANTINE` hat.
- Ob die Anwendung den Vorschlag wegen eines fehlenden Feldes ausfiltert oder bei der Darstellung überspringt.

Erst nach dieser Prüfung soll eine gezielte Korrektur vorbereitet werden.

**Wichtig:** Die Diagnose darf nicht durch das Setzen erfundener Metadaten oder durch eine automatische Freigabe umgangen werden.

## 9. Regeln für die automatische Verarbeitung sicherer Vorschläge

Die automatische Freigabe geeigneter Gemini-Vorschläge bleibt eine wichtige offene Aufgabe.

Der bestehende Archivierungsablauf prüft unter anderem:

- `.manual_review.approved_at`
- `proposal.requires_review`
- `proposal.review_decision`
- `proposal.validation_warnings`
- `proposal.primary_tag`

Bisher werden Jobs ohne dokumentierte manuelle Freigabe teilweise in Quarantäne gestellt. Dadurch können auch sichere Vorschläge blockiert werden, obwohl sie grundsätzlich automatisch verarbeitet werden könnten.

### Gewünschtes Verhalten für sichere Vorschläge

Ein Dokument soll ohne manuelle Freigabe weiterverarbeitet werden können, wenn:

- ein vollständiger, gültiger Vorschlag vorhanden ist;
- eine gültige Hauptkategorie gesetzt ist;
- die Konfidenz ausreichend hoch ist;
- keine Validierungswarnungen vorliegen;
- `requires_review=false` gilt;
- `review_decision=no_check_needed` gilt;
- die notwendigen Metadaten plausibel und widerspruchsfrei sind.

### Fälle, die weiterhin in Quarantäne gehören

Eine manuelle Prüfung bleibt erforderlich, wenn:

- die Konfidenz zu niedrig oder nicht vorhanden ist;
- die Hauptkategorie fehlt oder ungültig ist;
- Validierungswarnungen vorhanden sind;
- Angaben widersprüchlich oder unvollständig sind;
- Gemini eine manuelle Prüfung verlangt;
- Analyse, Validierung oder Übernahme technisch fehlschlagen;
- ein `noLLM`-Platzhalter noch nicht manuell vervollständigt und freigegeben wurde.

Eine Konfidenzgrenze von beispielsweise `0.90` ist ein möglicher Ausgangspunkt, aber keine bestätigte Projektentscheidung. Vor einer Implementierung müssen bestehende Konfigurationen und Qualitätsregeln geprüft werden.

Die automatische Freigabe darf nicht dadurch realisiert werden, dass bei allen Dokumenten pauschal ein Zeitstempel für die manuelle Freigabe gesetzt wird.

## 10. Sicherheitsregeln für die Archivierung

Die bestehenden Sicherheitsprüfungen dürfen nicht geschwächt werden.

Der Upload erfolgt mit rclone. Danach werden die lokale und die entfernte Dateigröße verglichen. Nur bei erfolgreicher Verifikation wird `ARCHIVE_VERIFIED=true` gesetzt.

Anschließend wird die ursprüngliche Datei in Google Drive gelöscht und die Löschung überprüft. Erst danach darf die lokale Quelldatei entfernt werden.

### Wichtige Jobfelder

- `ARCHIVE_TARGET`
- `ARCHIVE_FILE`
- `ARCHIVE_VERIFIED`
- `GDRIVE_SOURCE_DELETED`
- `LOCAL_SOURCE_DELETED`
- `STATUS`
- `ERROR_TYPE`
- `ERROR_MESSAGE`
- `COMPLETED_AT`

Eine erfolgreich abgeschlossene Archivierung muss unter anderem durch folgende Werte nachvollziehbar sein:

- `ARCHIVE_VERIFIED=true`
- `GDRIVE_SOURCE_DELETED=true`
- `LOCAL_SOURCE_DELETED=true`
- `STATUS=COMPLETE`

Bei Fehlern darf keine ungesicherte Löschung erfolgen.

## 11. Erfolgreicher End-to-End-Test mit Dokument 687

Am 16. Oktober 2026 wurde der vollständige produktive Ablauf für Dokument 687 ausdrücklich freigegeben und erfolgreich abgeschlossen.

Job-ID:

`e05a5c8c-2a1c-4a14-a874-f0d8137f1b15`

Ursprüngliche Datei in Google Drive:

`gdrive:SCAN/Zuletzt am 16.10.2026, 13:25:26 geprüft.pdf`

Lokale Scanpool-Datei:

`/media/BlueDisc3/PAPERLESS/scanpool/Zuletzt am 16.10.2026, 13-25-26 geprüft.pdf`

### Gemini-Vorschlag

- Dokument-ID: `687`
- Hauptkategorie: `Wohnen`
- Zusätzliche Tags: `Rechnung`, `Handwerker`
- Korrespondent: `André Peters`
- Dokumentdatum: `2012-10-08`
- Konfidenz: `0.95`
- `requires_review=false`
- `review_decision=no_check_needed`
- Keine Validierungswarnungen

Archivpfad:

`gdrive:PAPERLESS/Wohnen/André_Peters/20121008_Wohnen_André_Peters_Zuletzt_am_16.10.2026,_13-25-26_geprüft_ID-687.pdf`

### Testergebnis

- Vorschlag wurde übernommen.
- Metadaten wurden in Paperless angewendet.
- Archivdateiname und Zielverzeichnis wurden erzeugt.
- Datei wurde nach Google Drive hochgeladen.
- Lokale und entfernte Dateigröße wurden erfolgreich verglichen: jeweils `1.510.433 Byte`.
- Die ursprüngliche Drive-Datei wurde gelöscht und die Löschung überprüft.
- Die lokale Quelldatei wurde gelöscht.
- Der Job wurde mit `COMPLETE` abgeschlossen.

Endstatus:

- `ARCHIVE_VERIFIED=true`
- `GDRIVE_SOURCE_DELETED=true`
- `LOCAL_SOURCE_DELETED=true`
- `STATUS=COMPLETE`
- `ERROR_TYPE` leer
- `ERROR_MESSAGE` leer
- `COMPLETED_AT=2026-10-16T15:06:19+02:00`

Dieser Test bestätigt den produktiven Ende-zu-Ende-Ablauf für ein ausdrücklich freigegebenes Dokument. Er beweist noch nicht, dass sichere Dokumente bereits ohne manuelle Freigabe automatisch verarbeitet werden.

**Dokument 687 ist abgeschlossen. Die Quelldateien wurden gelöscht und dürfen nicht erneut als Test verwendet werden.**

## 12. Nächste Schritte

Die weitere Arbeit soll in dieser Reihenfolge erfolgen.

### Schritt 1: Anzeigeproblem von Dokument 1076 untersuchen

Zunächst den tatsächlichen Code der Quarantäne-Weboberfläche lesen.

Besonders relevant sind:

- die Filterung nach Jobstatus;
- das Laden der Vorschlagsdateien;
- die Verwendung von `primary_tag`;
- die Behandlung fehlender Metadaten;
- die Voraussetzungen für die Darstellung eines Quarantäneeintrags.

Zusätzlich müssen die Jobdatei und der aktuelle Status von Dokument 1076 geprüft werden.

Bis zur Klärung keine Änderungen vornehmen, die den Vorschlag automatisch freigeben oder mit erfundenen Metadaten ergänzen.

### Schritt 2: `noLLM`-Verhalten in `01_analyze.sh` prüfen

Datei:

`/home/pi/docker/paperless/paperless_metadata/scripts/01_analyze.sh`

Prüfen, ob:

- `noLLM` zuverlässig erkannt wird;
- keine Gemini-Anfrage für solche Dokumente erfolgt;
- vorhandene gültige Vorschläge erhalten bleiben;
- fehlende Vorschläge als manuelle Platzhalter erzeugt werden;
- Platzhalter nicht automatisch freigegeben werden;
- die Vorschlagsdateien für nachfolgende Prozesse korrekt abgelegt werden.

Das Skript zunächst nur untersuchen. Änderungen erst nach Sicherung und nachvollziehbarem Diff vorbereiten.

`fix_nollm_optional_tag.sh` bleibt vorerst außerhalb des Änderungsumfangs.

### Schritt 3: Automatische Freigabe sicherer Gemini-Vorschläge untersuchen

Das tatsächlich produktiv verwendete Archivierungsskript ermitteln und dessen Freigabelogik prüfen.

Anschließend die vorhandenen Konfigurationen und Skripte nach bereits definierten Konfidenzgrenzen und Qualitätsregeln durchsuchen.

Vor Änderungen ein Backup anlegen und die kleinstmögliche Anpassung vorbereiten.

### Schritt 4: Kontrollierte Tests durchführen

Ein noch nicht verarbeitetes Dokument auswählen, dessen Quelldatei weiterhin vorhanden ist.

Zuerst die Metadatenentscheidung und die Statusübergänge kontrolliert testen. Dabei prüfen:

- sichere Vorschläge;
- unsichere Vorschläge;
- fehlende oder ungültige Metadaten;
- `noLLM`-Platzhalter;
- manuelle Freigabe über die Weboberfläche.

Den vollständigen produktiven Ablauf nur mit ausdrücklicher Freigabe testen.

### Schritt 5: Ergebnis dokumentieren

Nach den Tests festhalten:

- ob sichere Dokumente automatisch weiterverarbeitet werden;
- ob unsichere Dokumente zuverlässig in Quarantäne bleiben;
- ob `noLLM`-Dokumente ohne Gemini-Anfrage verarbeitet werden;
- ob Platzhalter in der Weboberfläche sichtbar sind;
- ob manuelle Korrektur und Freigabe funktionieren;
- ob Upload-Verifikation und Löschsicherung unverändert greifen.

## 13. Verbindliche Arbeitsweise

Bei allen weiteren Arbeiten gelten folgende Regeln:

1. Pragmatisch und schrittweise vorgehen.
2. Zuerst den tatsächlichen Code und die aktuelle Konfiguration prüfen.
3. Keine Annahmen über aktive Dateinamen, Statusübergänge oder JSON-Strukturen treffen.
4. Bestehende Skripte möglichst gezielt ändern.
5. Vor produktiven Änderungen Backups anlegen.
6. Änderungen anhand nachvollziehbarer Diffs überprüfen.
7. Konkrete Shell-Befehle für die Ausführung auf `rasp2` bereitstellen.
8. Die Quarantänelogik für unsichere Fälle erhalten.
9. `noLLM`-Dokumente niemals ungefragt an Gemini übergeben.
10. Platzhalter nicht als gültige, automatisch freigegebene Vorschläge behandeln.
11. Upload-Verifikation und Löschsicherung niemals umgehen.
12. Keine produktiven Änderungen oder Löschungen ohne entsprechende Freigabe durchführen.
13. Abgeschlossene Testdokumente nicht erneut als Testquellen verwenden.
14. Keine Änderungen an nicht ausdrücklich freigegebenen Komponenten vornehmen.

## 14. Ausgangspunkt für die nächste Arbeitssitzung

Die unmittelbar nächste Aufgabe ist die **gezielte Prüfung der Quarantäne-Weboberfläche, um zu erklären, warum Dokument 1076 trotz vorhandener noLLM-Platzhalterdatei nicht angezeigt wird**.

Danach soll die Behandlung von `noLLM` in `01_analyze.sh` überprüft und gegebenenfalls gezielt korrigiert werden.

Die automatische Freigabe sicherer Gemini-Vorschläge bleibt eine separate Aufgabe. Sie soll erst nach Prüfung des tatsächlichen produktiven Archivierungsskripts und der vorhandenen Konfiguration vorbereitet werden.

Ziel bleibt ein zuverlässiger, nachvollziehbarer Automatisierungsprozess mit möglichst wenigen manuellen Prüfungen, ohne die Sicherheit der Metadatenübernahme und Archivierung zu beeinträchtigen.
