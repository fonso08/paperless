#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$BASE_DIR/config/tag_catalog.json"
PROPOSALS="$BASE_DIR/state/proposals"

# Voraussetzungen prüfen
if [[ ! -f "$CATALOG" ]]; then
  echo "FEHLER: Tag-Verzeichnis fehlt: $CATALOG" >&2
  exit 1
fi

if [[ ! -d "$PROPOSALS" ]]; then
  echo "FEHLER: Vorschlagsverzeichnis fehlt: $PROPOSALS" >&2
  exit 1
fi

# Vorhandene Vorschlagsdateien ermitteln
shopt -s nullglob
files=("$PROPOSALS"/*.json)

if ((${#files[@]} == 0)); then
  echo "Keine JSON-Vorschläge gefunden: $PROPOSALS" >&2
  exit 1
fi

# Vorschläge prüfen und Dateinamen berechnen
jq -r -s --slurpfile catalog "$CATALOG" '
  ($catalog[0]) as $c
  |
  (
    [
      "ID",
      "Hauptkategorie",
      "Zusatz-Tags",
      "Korrespondent",
      "Dateiname",
      "Status",
      "Prüfung"
    ] | @tsv
  ),
  (
    .[]
    | . as $file
    | ($file.proposal // {}) as $p
    | ($p.primary_tag // "(fehlt)") as $main

    # Hauptkategorie validieren
    | (
        if ($c.main_categories | index($main)) then
          "OK"
        elif (($c.legacy_main_category_mapping // {}) | has($main)) then
          "ALT: Mapping vorhanden"
        else
          "UNBEKANNT"
        end
      ) as $status

    # Korrespondent: vorhandener Eintrag oder erkannter Vorschlag
    | ($p.correspondent_suggestion // $p.correspondent // "") as $sender

    # Für den Dateinamen den ersten Namensbestandteil verwenden
    | (
        if ($sender | length) > 0 then
          ($sender | split(" ")[0])
        else
          ""
        end
      ) as $short_sender

    # Datum ins Format JJJJMMTT umwandeln
    | (($p.document_date // "") | gsub("-"; "")) as $date

    # Hauptkategorie für den Dateinamen vereinheitlichen
    | (
        $main
        | gsub(" & "; "-")
        | gsub("[^[:alnum:]-]"; "")
      ) as $safe_main

    # Dateiendung aus dem bisherigen Originaldateinamen übernehmen
    | (
        ($file.existing.original_file_name // "")
        | split("/")
        | last
        | split(".")
        | if length > 1 then last else "" end
      ) as $ext

    # Dateinamen nur erzeugen, wenn alle erforderlichen Angaben vorliegen
    | (
        if ($date | test("^[0-9]{8}$"))
           and ($safe_main | length) > 0
           and ($short_sender | length) > 0
           and ($ext | test("^[[:alnum:]]+$"))
        then
          "\($date)\($safe_main)-\($short_sender).\($ext)"
        else
          "(Prüfung erforderlich)"
        end
      ) as $filename

    # Prüfungshinweis
    | (
        if ($p.requires_review // true) then
          "Manuell prüfen"
        else
          "Prüfung nicht markiert"
        end
      ) as $review

    # Tabellenzeile
    | [
        ($file.document_id | tostring),
        $main,
        (($p.additional_tags // []) | join(", ")),
        (if $sender == "" then "(offen)" else $sender end),
        $filename,
        $status,
        $review
      ]
    | @tsv
  )
' "${files[@]}"
