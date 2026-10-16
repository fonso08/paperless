#!/usr/bin/env bash
# Nur Auswertung: verändert keine Vorschläge und keine Paperless-Daten.
set -euo pipefail

shopt -s nullglob
files=(state/proposals/*.json)

if ((${#files[@]} == 0)); then
  echo "Keine Vorschläge gefunden."
  exit 0
fi

jq -s -r '
  def safe:
    gsub("ä";"ae") | gsub("ö";"oe") | gsub("ü";"ue")
    | gsub("Ä";"Ae") | gsub("Ö";"Oe") | gsub("Ü";"Ue")
    | gsub("ß";"ss")
    | gsub("&";"und")
    | gsub("[^A-Za-z0-9._-]+";"-")
    | gsub("-+";"-")
    | gsub("^[._-]+|[._-]+$";"");

  map(
    . as $p
    | ($p.existing.original_file_name // "") as $original
    | ($p.existing.archived_file_name // "") as $archived
    | (if $original != "" then $original else $archived end) as $source
    | (if ($source | contains("."))
       then ($source | capture("\\.(?<ext>[^.]+)$").ext)
       else "pdf" end) as $ext

    | ($p.proposal.document_date // "") as $proposed_date
    | (if (($p.analysis.ocr_char_count // 0) == 0)
          and ($proposed_date == ($p.existing.created // ""))
       then ""
       else $proposed_date
       end) as $date

    | (if ($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
       then ($date | gsub("-";""))
       else "" end) as $datepart

    | (($p.proposal.primary_tag // "") | safe) as $category
    | (($p.proposal.correspondent
        // $p.proposal.correspondent_suggestion // "") | safe) as $corr
    | (($p.proposal.title
        // $p.proposal.document_title // "") | safe) as $title

    | ([$datepart, $category]
        | map(select(length > 0)) | join("_")) as $prefix

    | ($p.document_id | tostring) as $id

    | (if $corr != "" then
         ([$prefix, $corr]
          | map(select(length > 0)) | join("_")) + "." + $ext
       elif $source != "" then
         (if $prefix != "" then $prefix + "_" else "" end) + $source
       else
         (if $prefix != "" then $prefix else "Dokument_" + $id end)
           + "." + $ext
       end) as $filename

    | ($filename | sub("\\.[^.]+$"; "")) as $stem
    | ($filename | capture("\\.(?<out_ext>[^.]+)$").out_ext // $ext) as $out_ext

    | {
        id: $id,
        tag: ($p.proposal.primary_tag // ""),
        conf: ($p.proposal.confidence // 0),
        chars: ($p.analysis.ocr_char_count // 0),
        review: (if $p.proposal.requires_review then "true" else "false" end),
        stem: $stem,
        ext: $out_ext,
        filename: $filename,
        prefix: $prefix,
        corr: $corr,
        title: $title,
        key: ($filename | ascii_downcase),
        result: (
          if ($p.analysis.ocr_char_count // 0) < 100 then
            "PRÜFEN: OCR < 100"
          elif ($p.proposal.confidence // 0) < 0.9 then
            "PRÜFEN: Konfidenz < 0.9"
          elif ($p.proposal.primary_tag // "") == "" then
            "PRÜFEN: Kategorie fehlt"
          else
            "KEINE MARKIERUNG (Test)"
          end
        )
      }
  )

  # Ursprüngliche Namenskonflikte zählen
  | (reduce .[] as $r ({}; .[$r.key] = ((.[$r.key] // 0) + 1))) as $counts

  # Bei Konflikt Titel an Korrespondent anhängen
  | map(
      . + {dupe_count: $counts[.key]}
      | if .dupe_count > 1 then
          if (.corr != "" and .title != "") then
            . + {
              filename: (
                ([
                  .prefix,
                  .corr,
                  .title
                ] | map(select(length > 0)) | join("_"))
                + "." + .ext
              ),
              conflict: (
                "KONFLIKT (" + (.dupe_count | tostring)
                + "x; Titel ergänzt)"
              )
            }
          else
            . + {
              filename: (.stem + "_" + .id + "." + .ext),
              conflict: (
                "KONFLIKT (" + (.dupe_count | tostring)
                + "x; ID als Rückfall)"
              )
            }
          end
        else
          . + {conflict: "NEIN"}
        end
    )

  # Erneut prüfen, ob die neuen Namen noch doppelt vorkommen
  | (reduce .[] as $r (
      {};
      .[$r.filename | ascii_downcase] =
        ((.[$r.filename | ascii_downcase] // 0) + 1)
    )) as $final_counts

  # Falls weiterhin Konflikte bestehen, Dokument-ID ergänzen
  | map(
      . as $r
      | if ($final_counts[$r.filename | ascii_downcase] // 0) > 1 then
          . + {
            filename: (
              ($r.filename | sub("\\.[^.]+$"; ""))
              + "_" + $r.id + "."
              + ($r.filename | capture("\\.(?<e>[^.]+)$").e)
            ),
            conflict: (
              ($r.conflict // "KONFLIKT")
              + "; ID ergänzt"
            )
          }
        else
          .
        end
    )

  | .[]
  | [
      .id,
      .tag,
      (.conf | tostring),
      (.chars | tostring),
      .review,
      .result,
      (.conflict // "NEIN"),
      .filename
    ]
  | @tsv
' "${files[@]}" |
while IFS=$'\t' read -r id tag conf chars review result conflict filename; do
  printf '%-6s %-25s %-5s %-9s %-10s %-24s %-38s %s\n' \
    "$id" "$tag" "$conf" "$chars" "$review" "$result" "$conflict" "$filename"
done
