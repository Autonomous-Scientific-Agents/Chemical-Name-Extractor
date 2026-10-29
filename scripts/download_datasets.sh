#!/usr/bin/env bash
# Download open chemical-name datasets for the Chemical Name Extractor.
#
# Resumable: partial files are kept as *.part and continued with `curl -C -`
# on the next run; finished files are skipped. Safe to Ctrl-C and re-run.
#
# Usage:
#   ./download_datasets.sh [--dest DIR] [--force] [--verify] [source ...]
#
# Sources (default: all): pubchem chebi chembl unichem drugbank unii comptox
#
#   --dest DIR   where to put data (default: ./data next to this script)
#   --force      run even if the free-disk-space check fails
#   --verify     run `gzip -t` / `unzip -t` on finished archives (slow for PubChem)
#
# License-restricted sources (full DrugBank XML, CAS, Reaxys, etc.) are
# intentionally not downloaded. Works with macOS bash 3.2 and Linux bash.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$SCRIPT_DIR/data"
FORCE=0
VERIFY=0
SOURCES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) SOURCES="$SOURCES $1"; shift ;;
  esac
done
[ -z "$SOURCES" ] && SOURCES="pubchem chebi chembl unichem drugbank unii comptox"

mkdir -p "$DEST"
LOG="$DEST/download.log"
FAILED=""
UA="ChemicalNameExtractor-downloader/1.0 (research use)"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# ---------------------------------------------------------------- disk check
# Approximate compressed download sizes in GB (rounded up).
est_gb() {
  case "$1" in
    pubchem) echo 14 ;;   # Synonym-filtered, Title, SMILES, InChI-Key
    chebi) echo 2 ;;
    chembl) echo 7 ;;     # SQLite tarball + chemreps
    unichem) echo 20 ;;   # structure + reference table dumps
    drugbank) echo 1 ;;
    unii) echo 1 ;;
    comptox) echo 3 ;;
    *) echo 0 ;;
  esac
}

need=0
for s in $SOURCES; do need=$((need + $(est_gb "$s"))); done
need=$((need + need / 5 + 2))   # 20% headroom + 2 GB
free_gb=$(( $(df -Pk "$DEST" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
log "Destination: $DEST"
log "Sources: $SOURCES"
log "Free space: ${free_gb} GB, estimated need: ${need} GB (compressed; plan ~3x more to decompress later)"
if [ "$free_gb" -lt "$need" ]; then
  if [ "$FORCE" -eq 1 ]; then
    log "WARNING: not enough free space, continuing because of --force"
  else
    log "ERROR: not enough free space. Free some space, pick fewer sources, or pass --force."
    exit 1
  fi
fi

# ------------------------------------------------------------------ helpers
remote_size() {
  # Content-Length of the final response after redirects, or empty.
  curl -sSIL -A "$UA" --max-time 60 "$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}'
}

local_size() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

verify_file() {
  [ "$VERIFY" -eq 1 ] || return 0
  case "$1" in
    *.gz) log "  verifying $(basename "$1")"; gzip -t "$1" ;;
    *.zip) log "  verifying $(basename "$1")"; unzip -tq "$1" >/dev/null ;;
    *) return 0 ;;
  esac
}

# fetch URL OUTFILE: resumable download; returns non-zero on failure.
fetch() {
  url="$1"; out="$2"; part="$out.part"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ]; then
    log "  skip (done) $(basename "$out")"
    return 0
  fi
  rsize=$(remote_size "$url")
  if [ -n "$rsize" ] && [ "$(local_size "$part")" = "$rsize" ]; then
    mv "$part" "$out"; log "  finished earlier: $(basename "$out")"; return 0
  fi
  log "  GET $url"
  attempt=1
  while [ $attempt -le 5 ]; do
    curl -fL -A "$UA" -C - --retry 5 --retry-delay 10 --retry-connrefused \
         --connect-timeout 30 --speed-time 120 --speed-limit 1024 \
         --progress-bar -o "$part" "$url"
    rc=$?
    if [ $rc -eq 0 ]; then break; fi
    # 33 / 416: server can't resume -> already complete or no range support.
    if [ $rc -eq 33 ] || { [ -n "$rsize" ] && [ "$(local_size "$part")" = "$rsize" ]; }; then
      [ "$(local_size "$part")" = "$rsize" ] && { rc=0; break; }
      log "  server refused resume, restarting $(basename "$out")"; rm -f "$part"
      attempt=$((attempt + 1)); continue
    fi
    if [ $rc -eq 22 ] && [ "$(local_size "$part")" = "0" ]; then
      rm -f "$part"; log "  HTTP error for $url"; return 1
    fi
    log "  curl exit $rc, retry $attempt/5 in 30s"
    attempt=$((attempt + 1)); sleep 30
  done
  [ $rc -eq 0 ] || return 1
  if [ -n "$rsize" ] && [ "$(local_size "$part")" != "$rsize" ]; then
    log "  size mismatch for $(basename "$out") (got $(local_size "$part"), expected $rsize); re-run to resume"
    return 1
  fi
  mv "$part" "$out"
  verify_file "$out" || { log "  integrity check FAILED: $out"; mv "$out" "$out.bad"; return 1; }
  log "  done $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# fetch_first OUTFILE URL1 URL2 ...: first URL that works wins.
fetch_first() {
  out="$1"; shift
  [ -f "$out" ] && { log "  skip (done) $(basename "$out")"; return 0; }
  for u in "$@"; do
    fetch "$u" "$out" && return 0
  done
  return 1
}

# list_links URL REGEX: print file names in an HTTP directory listing matching REGEX.
list_links() {
  curl -fsSL -A "$UA" --max-time 120 "$1" 2>/dev/null \
    | grep -oE 'href="[^"]+"' | sed 's/^href="//; s/"$//' \
    | grep -E "$2" | sort -u
}

fail() { FAILED="$FAILED $1"; log "FAILED: $1"; }

# ------------------------------------------------------------------ sources
dl_pubchem() {
  base="https://ftp.ncbi.nlm.nih.gov/pubchem/Compound/Extras"
  d="$DEST/pubchem"
  for f in CID-Synonym-filtered.gz CID-Title.gz CID-InChI-Key.gz CID-SMILES.gz; do
    fetch "$base/$f" "$d/$f" || fail "pubchem/$f"
  done
}

dl_chebi() {
  b="https://ftp.ebi.ac.uk/pub/databases/chebi"
  d="$DEST/chebi"
  # ChEBI moved flat files to flat_files/ in 2025; fall back to the legacy layout.
  for f in names.tsv.gz compounds.tsv.gz database_accession.tsv.gz; do
    fetch_first "$d/$f" "$b/flat_files/$f" "$b/Flat_file_tab_delimited/$f" || fail "chebi/$f"
  done
  fetch_first "$d/structures.tsv.gz" "$b/flat_files/structures.tsv.gz" \
    "$b/Flat_file_tab_delimited/structures.csv.gz" || fail "chebi/structures"
  fetch_first "$d/chebi.sdf.gz" "$b/SDF/chebi.sdf.gz" "$b/SDF/ChEBI_complete.sdf.gz" \
    || fail "chebi/sdf"
  fetch_first "$d/chebi.obo.gz" "$b/ontology/chebi.obo.gz" || fail "chebi/obo"
}

dl_chembl() {
  b="https://ftp.ebi.ac.uk/pub/databases/chembl/ChEMBLdb/latest"
  d="$DEST/chembl"
  sqlite=$(list_links "$b/" '^chembl_[0-9]+_sqlite\.tar\.gz$' | tail -1)
  chemreps=$(list_links "$b/" '^chembl_[0-9]+_chemreps\.txt\.gz$' | tail -1)
  if [ -z "$sqlite" ]; then fail "chembl (could not list $b/)"; return; fi
  log "  ChEMBL release: ${sqlite%%_sqlite*}"
  fetch "$b/checksums.txt" "$d/checksums.txt" || true
  fetch "$b/$chemreps" "$d/$chemreps" || fail "chembl/$chemreps"
  fetch "$b/$sqlite" "$d/$sqlite" || { fail "chembl/$sqlite"; return; }
  if [ -f "$d/checksums.txt" ]; then
    want=$(grep -E "[[:space:]]\*?$sqlite\$" "$d/checksums.txt" | awk '{print $1}')
    if [ -n "$want" ]; then
      log "  checking sha256 of $sqlite"
      if command -v sha256sum >/dev/null; then got=$(sha256sum "$d/$sqlite" | awk '{print $1}')
      else got=$(shasum -a 256 "$d/$sqlite" | awk '{print $1}'); fi
      if [ "$got" = "$want" ]; then log "  sha256 OK"
      else mv "$d/$sqlite" "$d/$sqlite.bad"; fail "chembl sha256 mismatch (moved to .bad)"; fi
    fi
  fi
}

dl_unichem() {
  b="https://ftp.ebi.ac.uk/pub/databases/chembl/UniChem/data/table_dumps"
  d="$DEST/unichem"
  # source = list of databases, structure = UCI -> InChI/InChIKey,
  # reference = UCI -> source compound IDs (the cross-reference table, largest).
  for f in source.tsv.gz structure.tsv.gz reference.tsv.gz; do
    fetch "$b/$f" "$d/$f" || fail "unichem/$f"
  done
}

dl_drugbank() {
  # Open vocabulary (CC0): DrugBank IDs, names, synonyms, CAS, UNII, InChIKey.
  # The full DrugBank database needs a license and is not downloaded.
  d="$DEST/drugbank"
  fetch_first "$d/drugbank_all_vocabulary.csv.zip" \
    "https://go.drugbank.com/releases/latest/downloads/all-drugbank-vocabulary" \
    || fail "drugbank vocabulary (download manually from https://go.drugbank.com/releases/latest#open-data)"
  fetch_first "$d/drugbank_all_open_structures.sdf.zip" \
    "https://go.drugbank.com/releases/latest/downloads/all-open-structures" \
    || log "  (optional) DrugBank open structures not available, skipping"
}

dl_unii() {
  # FDA GSRS UNII lists: names/synonyms and records with InChIKey/SMILES. Public domain.
  b="https://precision.fda.gov/uniisearch/archive/latest"
  d="$DEST/unii"
  fetch "$b/UNII_Data.zip" "$d/UNII_Data.zip" || fail "unii/UNII_Data.zip"
  fetch "$b/UNIIs.zip" "$d/UNIIs.zip" || log "  (optional) UNIIs.zip not available, skipping"
}

dl_comptox() {
  # EPA DSSTox / CompTox Dashboard bulk files. The folder layout changes between
  # releases, so find the newest synonym and identifier files in the listing.
  b="https://gaftp.epa.gov/COMPTOX/Sustainable_Chemistry_Data/Chemistry_Dashboard"
  d="$DEST/comptox"
  found=0
  for sub in "" $(list_links "$b/" '^[0-9]{4}[^/]*/$' | sort | tail -3 | tr '\n' ' '); do
    for f in $(list_links "$b/$sub" '[Ss]ynonym|[Ii]dentifier|DSSTox.*\.(zip|csv|tsv|xlsx|gz)$'); do
      case "$f" in */|\?*|/*) continue ;; esac
      fetch "$b/$sub$f" "$d/${sub%/}${sub:+_}$f" && found=1 || fail "comptox/$sub$f"
    done
  done
  if [ $found -eq 0 ]; then
    fail "comptox (no files found; download DSSTox synonyms/identifiers manually from https://www.epa.gov/comptox-tools/downloadable-computational-toxicology-data)"
  fi
}

# --------------------------------------------------------------------- main
for s in $SOURCES; do
  case "$s" in
    pubchem|chebi|chembl|unichem|drugbank|unii|comptox)
      log "=== $s ==="; "dl_$s" ;;
    *) log "unknown source: $s (skipping)" ;;
  esac
done

log "=== summary ==="
du -sh "$DEST"/* 2>/dev/null | tee -a "$LOG"
if [ -n "$FAILED" ]; then
  log "Some items failed:$FAILED"
  log "Re-run the same command to resume; anything already finished is skipped."
  exit 2
fi
log "All downloads finished."
