#!/usr/bin/env bash
# ml_registry_sync.sh — bulk-populate the canonical device→show registry from a
# status read of the ACTIVE show. This is the "build the canonical serial→show
# inventory" step: run scan + `ml_status --json` for a show, then point this at
# the JSON to upsert every reachable device's serial→show into the registry.
#
#   ML_SHOW=KAGAMI ./utilities/ml_registry_sync.sh --from-json ~/Desktop/red.json
#   ML_SHOW=KAGAMI ./utilities/ml_registry_sync.sh --from-json red.json --dry-run
#
# Flags:
#   --from-json <file>   status JSON produced by `ml_status --json` (required)
#   --dry-run            print what would be upserted; POST nothing
#   --map <csv>          serial↔device# map (default: asset_serial_list.csv)
#
# Each online device → POST {serial, show, device, status:active,
# source:canonical-scan} to SHOW_REGISTRY_URL. Keyed on serial; safe to re-run
# (upsert). Offline/error rows and rows without a serial are skipped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/require_bash5.sh
source "$SCRIPT_DIR/lib/require_bash5.sh"
# shellcheck source=lib/show_config.sh
source "$SCRIPT_DIR/lib/show_config.sh"

JSON_FILE=""
DRY="0"
MAP="$SCRIPT_DIR/asset_serial_list.csv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-json) JSON_FILE="$2"; shift 2 ;;
    --dry-run)   DRY="1"; shift ;;
    --map)       MAP="$2"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$JSON_FILE" ]] && { echo "Need --from-json <file> (run ml_status --json first)" >&2; exit 2; }
[[ -f "$JSON_FILE" ]] || { echo "No such file: $JSON_FILE" >&2; exit 2; }
[[ -z "${SHOW_REGISTRY_URL:-}" ]] && { echo "SHOW_REGISTRY_URL not set — nothing to sync to." >&2; exit 2; }

show_banner
echo "  Registry sync → ${ML_SHOW}  ${DRY:+}$([[ "$DRY" == 1 ]] && echo '(DRY RUN)')"
echo "  Source: $JSON_FILE   Map: $([[ -f "$MAP" ]] && basename "$MAP" || echo 'none')"
echo ""

JSON_FILE="$JSON_FILE" MAP="$MAP" SHOW="$ML_SHOW" REG_URL="$SHOW_REGISTRY_URL" DRY="$DRY" \
python3 - <<'PY'
import json, os, sys, csv, urllib.request, time
jf=os.environ["JSON_FILE"]; mapf=os.environ["MAP"]; show=os.environ["SHOW"]
url=os.environ["REG_URL"]; dry=os.environ["DRY"]=="1"

# serial(upper) -> device#  from the map csv (header-detected columns)
s2d={}
if os.path.exists(mapf):
    with open(mapf, newline="") as f:
        rows=list(csv.reader(f))
    if rows:
        hdr=[c.strip().lower() for c in rows[0]]
        def find(keys):
            for i,h in enumerate(hdr):
                if any(k in h for k in keys): return i
            return None
        ci_ser=find(["serial"]); ci_dev=find(["device","#","asset"])
        body=rows[1:] if (ci_ser is not None) else rows
        if ci_ser is None: ci_ser, ci_dev = (1,0)  # fallback: assume "device,serial"
        for r in body:
            if len(r)<=max(ci_ser, ci_dev or 0): continue
            ser=r[ci_ser].strip().upper()
            dev=r[ci_dev].strip() if ci_dev is not None and len(r)>ci_dev else ""
            if ser: s2d[ser]=dev

devices=json.load(open(jf))
ins=upd=fail=skip=0; fails=[]
todo=[x for x in devices if x.get("online") is not False and not x.get("error") and x.get("hw_serial")]
print(f"  {len(todo)} device(s) to upsert into '{show}'\n")
for i,x in enumerate(todo,1):
    serial=x["hw_serial"].strip()
    dev=s2d.get(serial.upper(), x.get("device_number","") or "")
    if dry:
        print(f"  [{i:>3}/{len(todo)}] WOULD upsert  {serial:<14} → {show}  device {dev or '?'}")
        continue
    data=json.dumps({"serial":serial,"show":show,"device":dev,
                     "status":"active","source":"canonical-scan"}).encode()
    req=urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
    try:
        r=json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
        act=r.get("action","?")
        if act=="inserted": ins+=1
        elif act=="updated": upd+=1
        else: fail+=1; fails.append((serial, r))
        if i%20==0 or i==len(todo): print(f"  [{i:>3}/{len(todo)}] … inserted={ins} updated={upd} fail={fail}")
    except Exception as e:
        fail+=1; fails.append((serial, str(e)))
        print(f"  [{i:>3}/{len(todo)}] FAIL {serial}: {e}")
    time.sleep(0.05)

print()
if dry:
    print(f"  DRY RUN — {len(todo)} would be upserted (nothing posted).")
else:
    print(f"  Done: inserted={ins}  updated={upd}  failed={fail}  (of {len(todo)})")
    for s,e in fails[:10]: print(f"    ✗ {s}: {e}")
    sys.exit(1 if fail else 0)
PY
