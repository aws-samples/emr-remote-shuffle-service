#!/usr/bin/env python3
"""Compare two spark-sql-perf TPC-DS result locations query by query.

usage: compare.py s3://.../results/norss-<ts> s3://.../results/celeborn-<ts> [out.csv]
"""
import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def load(prefix: str) -> dict:
    """Return {query: seconds} from the part-*.json files under an S3 prefix."""
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["aws", "s3", "cp", prefix.rstrip("/") + "/", d, "--recursive",
                        "--exclude", "*", "--include", "*part-*.json", "--quiet"], check=True)
        times = {}
        for f in Path(d).rglob("part-*.json"):
            for line in f.read_text().splitlines():
                rec = json.loads(line)
                for r in rec.get("results", []):
                    if r.get("failure"):
                        times[r["name"]] = None
                    else:
                        t = r["parsingTime"] + r["analysisTime"] + r["optimizationTime"] \
                            + r["planningTime"] + r["executionTime"]
                        times[r["name"]] = t / 1000.0
        return times


def main():
    base, rss = load(sys.argv[1]), load(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else None
    rows, tb, tr = [], 0.0, 0.0
    for q in sorted(set(base) | set(rss), key=lambda n: (len(n.split("-")[0]), n)):
        b, r = base.get(q), rss.get(q)
        if b is not None and r is not None:
            tb, tr = tb + b, tr + r
        rows.append((q, b, r, (b / r) if b and r else None))

    print(f"{'query':<14}{'no-RSS (s)':>12}{'Celeborn (s)':>14}{'speedup':>10}")
    for q, b, r, s in rows:
        fmt = lambda v: f"{v:.1f}" if v is not None else "FAIL/NA"
        print(f"{q:<14}{fmt(b):>12}{fmt(r):>14}{(f'{s:.2f}x' if s else '-'):>10}")
    both = [x for x in rows if x[3]]
    print(f"\nqueries compared: {len(both)} / {len(rows)}")
    print(f"total  no-RSS {tb:.0f}s   Celeborn {tr:.0f}s   speedup {tb / tr:.2f}x  "
          f"({(tr - tb) / tb * 100:+.1f}% runtime)")
    wins = sum(1 for x in both if x[3] > 1.05)
    losses = sum(1 for x in both if x[3] < 0.95)
    print(f"Celeborn >5% faster: {wins}   >5% slower: {losses}   within 5%: {len(both) - wins - losses}")
    top = sorted(both, key=lambda x: x[1] - x[2], reverse=True)
    print("biggest absolute gains: " + ", ".join(f"{q} ({b - r:+.0f}s)" for q, b, r, _ in top[:5]))
    print("biggest absolute losses: " + ", ".join(f"{q} ({b - r:+.0f}s)" for q, b, r, _ in top[-5:][::-1]))
    if out:
        with open(out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["query", "norss_s", "celeborn_s", "speedup"])
            w.writerows(rows)


if __name__ == "__main__":
    main()
