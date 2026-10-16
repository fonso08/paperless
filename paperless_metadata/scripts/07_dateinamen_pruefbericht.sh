#!/usr/bin/env bash
set -euo pipefail
cd /home/pi/docker/paperless/paperless_metadata
mkdir -p state/reports

OUT="state/reports/dateinamen_pruefbericht_korrigiert_$(date +%Y%m%d_%H%M%S).csv"

python3 - "$OUT" <<'PY'
import csv, json, re, sys, unicodedata
from pathlib import Path
from collections import Counter

out = Path(sys.argv[1])
records = []

def safe(value):
    value = str(value or "").strip().replace("&", " und ")
    for a, b in [("ä","ae"),("Ä","Ae"),("ö","oe"),("Ö","Oe"),
                 ("ü","ue"),("Ü","Ue"),("ß","ss")]:
        value = value.replace(a, b)
    value = unicodedata.normalize("NFKD", value)
    value = "".join(c for c in value if not unicodedata.combining(c))
    value = re.sub(r'[^A-Za-z0-9._ -]', "-", value)
    value = re.sub(r"[\s-]+", "-", value)
    return value.strip(" .-_") or ""

def make_name(datepart, category, correspondent, title, ext, docid=None):
    parts = [
        str(datepart or "").strip(" ._-"),
        str(category or "").strip(" ._-"),
        str(correspondent or "").strip(" ._-"),
        str(title or "").strip(" ._-"),
    ]
    suffix = f"_ID{docid}" if docid is not None else ""

    # Redundante Datumspräfixe im Titel entfernen, auch nach "Kopie von".
    title_value = parts[3]
    title_value = re.sub(
        r"^(?:Kopie-von-|Kopie-von-|Kopie-von-)?"
        r"\d{4}[-_. ]?\d{2}[-_. ]?\d{2}[-_ .]+",
        "",
        title_value,
        flags=re.IGNORECASE,
    )
    title_value = re.sub(
        r"^Kopie-von-\d{8}[-_ ]*",
        "",
        title_value,
        flags=re.IGNORECASE,
    )
    parts[3] = title_value.strip(" ._-")

    def render():
        return "_".join(x for x in parts if x) + suffix + ext

    # Kürze möglichst an Wortgrenzen. Kennungen und letzte Titelwörter
    # werden nicht mehr durch ein künstliches Zusammenfügen vermischt.
    def shorten(value, limit):
        if len(value) <= limit:
            return value
        if limit <= 0:
            return ""
        candidate = value[:limit + 1]
        cut = max(candidate.rfind("-"), candidate.rfind("_"),
                  candidate.rfind(" "))
        if cut >= limit // 2:
            candidate = candidate[:cut]
        else:
            candidate = value[:limit]
        return candidate.rstrip(" ._-")

    # Nur bei Platzmangel kürzen; Titel zuerst, dann Korrespondent,
    # Kategorie und zuletzt das Datum.
    for index in (3, 2, 1, 0):
        if len(render()) <= 80:
            break
        excess = len(render()) - 80
        new_length = max(0, len(parts[index]) - excess)

        # Bei langen Titeln mit strukturierten Kennungen versuchen wir,
        # wichtige Dokumentenart-Begriffe am Ende zu erhalten.
        if index == 3 and new_length >= 16:
            value = parts[index]
            important = re.search(
                r"(?i)(Leistungsabrechnung|Heil-undKostenplan|"
                r"Heil-und-Kostenplan|Abbuchungsmitteilung|"
                r"Wartungsnachweis|Anlagenzertifikat|Briefwechsel)$",
                value,
            )
            if important and len(important.group(1)) < new_length:
                ending = important.group(1)
                prefix = value[:value.rfind(ending)].rstrip(" ._-")
                prefix_limit = new_length - len(ending) - 1
                parts[index] = (
                    shorten(prefix, prefix_limit) + "_" + ending
                ).strip(" ._-")
            else:
                parts[index] = shorten(value, new_length)
        else:
            parts[index] = shorten(parts[index], new_length)

    # Fallback: nötigenfalls Titel vollständig weglassen, statt die
    # Grenze zu überschreiten oder die Endung abzuschneiden.
    if len(render()) > 80:
        parts[3] = ""
    for index in (2, 1, 0):
        if len(render()) <= 80:
            break
        parts[index] = shorten(
            parts[index], max(0, len(parts[index]) - (len(render()) - 80))
        )

    if len(render()) > 80:
        raise ValueError(f"Dateiname kann nicht auf 80 Zeichen begrenzt werden: {render()}")

    return render()

for path in Path("state/proposals").glob("*.json"):
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
        e, p = d.get("existing") or {}, d.get("proposal") or {}
        docid = str(d.get("document_id", path.stem))
        current = e.get("original_file_name") or e.get("archived_file_name") or ""
        ext = Path(current).suffix.lower() or ".pdf"
        title = safe(e.get("title") or Path(current).stem or f"Dokument-{docid}")
        category = safe(p.get("primary_tag") or "Unsortiert")
        corr = safe(p.get("correspondent") or p.get("correspondent_suggestion")
                    or e.get("correspondent") or "")
        date = str(p.get("document_date") or e.get("created") or "")
        m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", date)
        datepart = "".join(m.groups()) if m else "OHNE-DATUM"
        warnings = []
        if not m: warnings.append("Datum fehlt/ungueltig")
        if not p.get("primary_tag"): warnings.append("Kategorie fehlt")
        if not title: warnings.append("Titel fehlt")
        if not corr: warnings.append("Korrespondent ausgelassen")
        name = make_name(datepart, category, corr, title, ext)
        records.append({
            "id": docid, "current": current, "date": date,
            "datepart": datepart, "category": p.get("primary_tag") or "",
            "corr": p.get("correspondent") or p.get("correspondent_suggestion") or "",
            "title": e.get("title") or "",
            "name": name, "ext": ext, "warnings": warnings, "conflict": ""
        })
    except Exception as exc:
        print(f"FEHLER in {path}: {exc}")

# Doppelte Vorschläge erhalten eine ID; jeder Name wird erneut auf 80 Zeichen begrenzt.
counts = Counter(r["name"].casefold() for r in records)

for r in records:
    if counts[r["name"].casefold()] > 1:
        r["name"] = make_name(
            r["datepart"], safe(r["category"]), safe(r["corr"]),
            safe(r["title"]), r["ext"], r["id"]
        )
        r["conflict"] = "ID ergänzt"

# Abschließende Eindeutigkeitsprüfung.
seen = set()
for r in records:
    if r["name"].casefold() in seen:
        raise SystemExit(
            f"ABBRUCH: Auch nach ID-Ergänzung doppelt: {r['name']}"
        )
    if len(r["name"]) > 80:
        raise SystemExit(
            f"ABBRUCH: Dateiname länger als 80 Zeichen, ID {r['id']}: {r['name']}"
        )
    seen.add(r["name"].casefold())

cols = [
    ("Dokument-ID","id"), ("Aktueller Dateiname","current"),
    ("Analysiertes Datum","date"), ("Datum JJJJMMTT","datepart"),
    ("Kategorie","category"), ("Korrespondent","corr"),
    ("Dokumenttitel","title"), ("Vorgeschlagener Dateiname","name"),
    ("Konfliktprüfung","conflict"), ("Prüfhinweise","warnings")
]
with out.open("w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f, delimiter=";")
    w.writerow([x[0] for x in cols])
    for r in sorted(records, key=lambda x: int(x["id"]) if x["id"].isdigit() else 0):
        w.writerow(["; ".join(r[k]) if isinstance(r[k], list) else r[k]
                    for _, k in cols])

print(f"Report: {out}")
print(f"Dokumente: {len(records)}")
print(f"Konflikte mit ID-Ergänzung: {sum(bool(r['conflict']) for r in records)}")
print(f"Dateinamen über 80 Zeichen: {sum(len(r['name']) > 80 for r in records)}")
print("Dateiendungen werden aus den aktuellen Dateinamen übernommen.")
PY
