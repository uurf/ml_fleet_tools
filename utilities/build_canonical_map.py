#!/usr/bin/env python3
"""
Build the canonical serial -> device# map from the PHYSICAL fleet scans plus the
device<->serial record (the union of the tracking sheets, deduped).

The scans are ground truth for WHICH devices exist; the device<->serial CSV is
just the lookup for each device's number.

Writes the canonical per-show inventory files the dashboard loads — one per
fleet, Device,Serial (fleet_dashboard.html reads the first two columns):
    inventory/<RED_SHOW>.csv    inventory/<BLUE_SHOW>.csv
plus a combined CSV (Device,Serial,Fleet) and reconciliation buckets so the
human-keyed gaps are visible.

Usage:
    build_canonical_map.py RED_SCAN BLUE_SCAN DEVICE_SERIAL_CSV [OUT_CSV] \\
        [--red-show KAGAMI] [--blue-show KAGAMI_BLUE] [--inventory-dir DIR]

  RED_SCAN / BLUE_SCAN : one serial per line, e.g. produced by
        ML_SHOW=KAGAMI ML_DEV_TEST=1 ./ml_status.sh --csv \\
          | awk -F, 'NR>1 && $2=="true" && $3!="" {print $3}' | sort -u > red.txt
  DEVICE_SERIAL_CSV    : header + "Device,Serial" rows (e.g. device-serial-fixed.csv)
  OUT_CSV              : combined output; defaults to canonical_device_serial.csv
  --red-show/--blue-show : show ids for the per-show inventory filenames
                           (default KAGAMI / KAGAMI_BLUE)
  --inventory-dir      : where to write inventory/<show>.csv (default ./inventory)
"""
import sys, csv, os, argparse

def norm(s):
    return (s or "").strip().rstrip("\r").upper()

def read_serials(path):
    out = []
    with open(path) as f:
        for line in f:
            s = norm(line)
            if s:
                out.append(s)
    return out

def main():
    ap = argparse.ArgumentParser(usage=__doc__, add_help=True)
    ap.add_argument("red_scan"); ap.add_argument("blue_scan")
    ap.add_argument("device_serial_csv")
    ap.add_argument("out_csv", nargs="?", default="canonical_device_serial.csv")
    ap.add_argument("--red-show", default="KAGAMI")
    ap.add_argument("--blue-show", default="KAGAMI_BLUE")
    ap.add_argument("--inventory-dir", default="inventory")
    a = ap.parse_args()
    red  = read_serials(a.red_scan)
    blue = read_serials(a.blue_scan)
    csvpath = a.device_serial_csv
    out = a.out_csv

    # serial -> device# (blank device# = on record but unnumbered)
    rec = {}
    with open(csvpath, newline="") as f:
        r = csv.reader(f)
        next(r, None)  # header
        for row in r:
            if len(row) < 2:
                continue
            dev, ser = row[0].strip(), norm(row[1])
            if ser:
                rec[ser] = dev

    red_set, blue_set = set(red), set(blue)
    scanned = red_set | blue_set
    cross = sorted(red_set & blue_set)

    rows, unnumbered, norecord = [], [], []
    for fleet, serials in (("RED", red), ("BLUE", blue)):
        for s in sorted(set(serials)):
            dev = rec.get(s)
            if dev is None:
                rows.append(("", s, fleet)); norecord.append((s, fleet))
            else:
                rows.append((dev, s, fleet))
                if dev == "":
                    unnumbered.append((s, fleet))
    on_record_not_scanned = sorted(s for s in rec if s not in scanned)

    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Device", "Serial", "Fleet"])
        w.writerows(rows)

    # Per-show inventory files (Device,Serial) — what each show's dashboard loads.
    os.makedirs(a.inventory_dir, exist_ok=True)
    inv_paths = {}
    for fleet, show in (("RED", a.red_show), ("BLUE", a.blue_show)):
        p = os.path.join(a.inventory_dir, show + ".csv")
        inv_paths[fleet] = p
        with open(p, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["Device", "Serial"])
            for dev, ser, fl in rows:
                if fl == fleet:
                    w.writerow([dev, ser])

    def section(title, items, fmt):
        print("\n--- %s : %d ---" % (title, len(items)))
        for it in items:
            print("  " + fmt(it))

    print("=== combined map: %s (%d devices) ===" % (out, len(rows)))
    print("=== per-show inventory ===")
    print("  %-22s %s (%d)" % (a.red_show, inv_paths["RED"], len(red_set)))
    print("  %-22s %s (%d)" % (a.blue_show, inv_paths["BLUE"], len(blue_set)))
    print("RED scanned: %d   BLUE scanned: %d   distinct: %d"
          % (len(red_set), len(blue_set), len(scanned)))
    section("CROSS-FLEET (in BOTH scans — a device on the wrong network!)",
            cross, lambda s: s)
    section("scanned but UNNUMBERED (on record, blank device#)",
            unnumbered, lambda t: "%s (%s)" % t)
    section("scanned but NOT on record (no device# anywhere — assign one)",
            norecord, lambda t: "%s (%s)" % t)
    section("on record but NOT scanned (powered off / missing — informational)",
            on_record_not_scanned, lambda s: "%s -> device %s" % (s, rec[s]))

if __name__ == "__main__":
    main()
