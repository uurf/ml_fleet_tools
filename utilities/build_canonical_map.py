#!/usr/bin/env python3
"""
Build the canonical serial -> device# map from the PHYSICAL fleet scans plus the
device<->serial record (the union of the tracking sheets, deduped).

The scans are ground truth for WHICH devices exist; the device<->serial CSV is
just the lookup for each device's number. Output is dashboard-loadable
(Device,Serial,... — fleet_dashboard.html reads the first two columns) and a
set of reconciliation buckets so the human-keyed gaps are visible.

Usage:
    build_canonical_map.py RED_SCAN BLUE_SCAN DEVICE_SERIAL_CSV [OUT_CSV]

  RED_SCAN / BLUE_SCAN : one serial per line, e.g. produced by
        ML_SHOW=KAGAMI ML_DEV_TEST=1 ./ml_status.sh --csv \\
          | awk -F, 'NR>1 && $2=="true" && $3!="" {print $3}' | sort -u > red.txt
  DEVICE_SERIAL_CSV    : header + "Device,Serial" rows (e.g. device-serial-fixed.csv)
  OUT_CSV              : optional; defaults to canonical_device_serial.csv
"""
import sys, csv

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
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    red  = read_serials(sys.argv[1])
    blue = read_serials(sys.argv[2])
    csvpath = sys.argv[3]
    out = sys.argv[4] if len(sys.argv) > 4 else "canonical_device_serial.csv"

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

    def section(title, items, fmt):
        print("\n--- %s : %d ---" % (title, len(items)))
        for it in items:
            print("  " + fmt(it))

    print("=== canonical map written: %s (%d devices) ===" % (out, len(rows)))
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
