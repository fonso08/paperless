# Architekturgrundsätze und Statusdefinition

## 1. Paperless ist die maßgebliche Datenquelle

Paperless-ngx ist die führende Datenquelle für Dokumente und deren Metadaten.

Jobdateien, Proposals und weitere Workflow-Dateien sind ausschließlich Hilfsdaten. Sie dürfen nicht zu einer zweiten maßgeblichen Datenhaltung werden.

Wenn Jobdateien oder Proposals verloren gehen, müssen sich erforderliche Informationen soweit möglich aus Paperless, Google Drive und der vorhandenen Verarbeitung rekonstruieren lassen.

## 2. Jobs und Proposals sind Hilfsdaten

Jobdateien steuern die laufende Dokumentenverarbeitung und ermöglichen Wiederholungen nach Fehlern.

Proposals enthalten Vorschläge zur Metadatenverarbeitung. Änderungen an Paperless dürfen erst nach den vorgesehenen Prüfungen und Freigaben erfolgen.

Erfolgreich abgeschlossene Jobs dürfen gelöscht werden, sobald keine weiteren Verarbeitungsschritte von ihnen abhängen.

## 3. Die Archivierung ist unabhängig

Ein separater Archivierungsprozess vergleicht regelmäßig den tatsächlichen Dokumentenbestand in Paperless mit den erwarteten Dateien im Google-Drive-Archiv.

Die Archivierung muss unabhängig von Jobdateien und Proposals funktionieren.

Der tatsächliche Archivierungsstatus wird durch Abfragen mit `rclone` ermittelt. Ein Jobstatus allein ist kein Beleg dafür, dass eine Datei im Archiv vorhanden ist.

Fehlende Archivdateien werden erkannt und nachträglich archiviert. Die Archivierung darf nicht davon abhängen, ob ein ursprünglicher Verarbeitungsjob noch existiert.

## 4. Status `COMPLETE`

Für einen Google-Drive-Import wird `COMPLETE` erst gesetzt, wenn alle erforderlichen Schritte der Dokumentenverarbeitung erfolgreich abgeschlossen sind:

1. Die Metadatenverarbeitung wurde erfolgreich durchgeführt und die Metadaten wurden in Paperless gespeichert und überprüft.
2. Die Existenz des Dokuments wurde über die Paperless-API bestätigt.
3. Die ursprüngliche Google-Drive-Quelldatei wurde gelöscht.
4. Die Löschung der Quelldatei wurde überprüft.

`COMPLETE` bestätigt den erfolgreichen Abschluss der Dokumentenverarbeitung einschließlich Quellenbereinigung.

**`COMPLETE` bestätigt nicht, dass die separate Archivierung bereits abgeschlossen ist.**

## 5. Fehler und Wiederaufnahme

Schlägt ein erforderlicher Verarbeitungsschritt fehl, darf der Job nicht vorzeitig auf `COMPLETE` gesetzt werden.

Insbesondere gilt:

- Ist die Existenz des Dokuments in Paperless nicht bestätigt, darf die Google-Drive-Quelle nicht gelöscht werden.
- Kann die Google-Drive-Quelle nicht sicher gelöscht oder die Löschung nicht bestätigt werden, bleibt der Job für eine Wiederholung erhalten.
- Fehler bei der Archivierung werden unabhängig von `COMPLETE` durch den Archivierungsprozess behandelt.
- Wiederholungen müssen bereits erfolgreich abgeschlossene Schritte berücksichtigen und dürfen keine unnötigen oder unsicheren Löschungen auslösen.

## 6. Direktimporte und Scans

Direktimporte aus Paperless und lokale Scans ohne Google-Drive-Quelle benötigen keine Google-Drive-Quellenbereinigung.

Paperless-Originaldateien dürfen durch die Quellenbereinigung nicht gelöscht werden.

Für diese Importarten gelten die jeweiligen Schutzregeln; der Status `COMPLETE` darf nicht pauschal eine Löschung einer nicht vorhandenen oder geschützten Quelle voraussetzen.

## 7. Migration und Wiederherstellung

Für die Migration wird zunächst davon ausgegangen, dass die vorhandenen Jobs abgeschlossen sind und keine Zwischenzustände existieren.

Werden dennoch unvollständige Zustände gefunden, müssen diese anhand des tatsächlichen Paperless-Zustands geprüft und gegebenenfalls erneut verarbeitet werden.

Der Google-Drive-Archivbestand wird unabhängig davon mit `rclone` abgeglichen. Fehlende Archivdateien können dadurch auch nach dem Löschen abgeschlossener Jobs erkannt werden.

## 8. Statusübersicht

| Status | Bedeutung |
|---|---|
| `PAPERLESS_SUBMITTED` | Dokument wurde an Paperless übergeben. |
| `PAPERLESS_PROCESSING` | Paperless verarbeitet das Dokument. |
| `GEMINI_PENDING` | Metadatenverarbeitung mit Gemini steht aus. |
| `GEMINI_FAILED` | Gemini-Verarbeitung ist fehlgeschlagen; Wiederholung oder Fehlerbehebung erforderlich. |
| `GEMINI_SKIPPED` | Gemini wird übersprungen, beispielsweise bei `noLLM`; die erforderliche Freigabe kann weiterhin ausstehen. |
| `REVIEW_APPROVED` | Vorschlag wurde zur Übernahme freigegeben. |
| `QUARANTINE` | Dokument wartet auf eine explizite Freigabe. |
| `PAPERLESS_DONE` | Dokumentenverarbeitung in Paperless einschließlich der vorgesehenen Metadatenverarbeitung ist abgeschlossen; weitere Verarbeitungsschritte können ausstehen. |
| `ARCHIVE_PROCESSING` | Der Job befindet sich in einem Archivierungs- beziehungsweise Wiederaufnahmezustand. |
| `ARCHIVE_FAILED` | Ein Archivierungsschritt ist fehlgeschlagen. |
| `PAPERLESS_FAILED` | Die Paperless-Verarbeitung ist fehlgeschlagen. |
| `DUPLICATE` | Paperless hat ein Duplikat erkannt; der Duplikatpfad wird gesondert behandelt. |
| `COMPLETE` | Dokumentenverarbeitung einschließlich erforderlicher Quellenbereinigung ist erfolgreich abgeschlossen; keine Aussage über den unabhängigen Archivierungsstatus. |

Die Statuswerte beschreiben den Verarbeitungszustand eines Jobs. Sie ersetzen keine Prüfung des tatsächlichen Dokumenten- oder Archivbestands.

## 9. Verantwortlichkeiten

Die Architektur besteht aus **zwei logisch getrennten Prozessen**:

### Prozess 1: Dokumentenverarbeitung einschließlich Quellenbereinigung

Das zuständige Job-Script überwacht die Paperless-Verarbeitung, übernimmt freigegebene Metadaten, prüft den Erfolg und bestätigt die Existenz des Dokuments über die Paperless-API.

Anschließend löscht es die ursprüngliche Google-Drive-Quelldatei und verifiziert die Löschung. Erst nach erfolgreichem Abschluss aller erforderlichen Schritte wird der Google-Drive-Job auf `COMPLETE` gesetzt.

### Prozess 2: Unabhängige Archivierung

Ein separater Prozess gleicht die in Paperless vorhandenen Dokumente regelmäßig mit dem erwarteten Google-Drive-Archivbestand ab. Fehlende Archivdateien werden bei Bedarf nachträglich archiviert.

Dieser Prozess ist unabhängig von Jobdateien und Proposals. Der tatsächliche Archivbestand wird durch Abfragen mit `rclone` ermittelt.

**Die Quellenbereinigung ist ausdrücklich Bestandteil der Dokumentenverarbeitung und kein dritter eigenständiger Prozess.**
