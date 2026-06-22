#!/usr/bin/env python3
"""
review-results.py — Summarise and review OMB benchmark result JSON files.

Usage:
    python3 scripts/review-results.py                    # all files in results/
    python3 scripts/review-results.py results/foo.json   # specific file(s)
    python3 scripts/review-results.py --compare          # side-by-side table
"""

import json
import sys
import os
import statistics
from pathlib import Path
from datetime import datetime

RESULTS_DIR = Path(__file__).parent.parent / "results"

# ── thresholds used for the review / pass-fail assessment ──────────────────
THRESHOLDS = {
    "publish_error_rate_max":   1.0,    # errors/s
    "backlog_max_pct":          60.0,   # % of samples where backlog > 0
    "p99_publish_latency_ms":   500.0,  # ms
    "p99_e2e_latency_ms":       500.0,  # ms
    "consume_rate_min_pct":     95.0,   # consume rate must be >= X% of publish rate
}


def load(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def avg(lst):
    return statistics.mean(lst) if lst else 0.0


def pct_nonzero(lst):
    return 100.0 * sum(1 for x in lst if x > 0) / len(lst) if lst else 0.0


def throughput_mb(rate_msgs_s, msg_size_bytes):
    return rate_msgs_s * msg_size_bytes / 1_048_576


def assess(d: dict) -> list[tuple[str, bool, str]]:
    """Return list of (check_name, passed, detail) tuples."""
    checks = []

    # Publish error rate
    err = avg(d.get("publishErrorRate", [0]))
    checks.append((
        "Publish error rate",
        err <= THRESHOLDS["publish_error_rate_max"],
        f"{err:.2f} err/s  (limit {THRESHOLDS['publish_error_rate_max']})"
    ))

    # Consumer keeps up (backlog stays near zero)
    backlog_pct = pct_nonzero(d.get("backlog", []))
    checks.append((
        "Consumer backlog",
        backlog_pct <= THRESHOLDS["backlog_max_pct"],
        f"non-zero in {backlog_pct:.1f}% of samples  (limit {THRESHOLDS['backlog_max_pct']}%)"
    ))

    # Consume rate vs publish rate
    pub = avg(d.get("publishRate", [1]))
    con = avg(d.get("consumeRate", [0]))
    con_pct = 100.0 * con / pub if pub else 0
    checks.append((
        "Consume / publish ratio",
        con_pct >= THRESHOLDS["consume_rate_min_pct"],
        f"{con_pct:.1f}%  (limit ≥{THRESHOLDS['consume_rate_min_pct']}%)"
    ))

    # p99 publish latency
    p99_pub = d.get("aggregatedPublishLatency99pct", 0)
    checks.append((
        "p99 publish latency",
        p99_pub <= THRESHOLDS["p99_publish_latency_ms"],
        f"{p99_pub:.1f} ms  (limit {THRESHOLDS['p99_publish_latency_ms']} ms)"
    ))

    # p99 end-to-end latency
    p99_e2e = d.get("aggregatedEndToEndLatency99pct", 0)
    checks.append((
        "p99 end-to-end latency",
        p99_e2e <= THRESHOLDS["p99_e2e_latency_ms"],
        f"{p99_e2e:.1f} ms  (limit {THRESHOLDS['p99_e2e_latency_ms']} ms)"
    ))

    return checks


def print_report(path: Path, d: dict):
    msg_size   = d.get("messageSize", 0)
    pub_rates  = d.get("publishRate", [])
    con_rates  = d.get("consumeRate", [])
    backlogs   = d.get("backlog", [])
    err_rates  = d.get("publishErrorRate", [0])

    avg_pub    = avg(pub_rates)
    avg_con    = avg(con_rates)
    avg_err    = avg(err_rates)
    peak_pub   = max(pub_rates) if pub_rates else 0
    avg_mb     = throughput_mb(avg_pub, msg_size)
    peak_mb    = throughput_mb(peak_pub, msg_size)

    print()
    print("═" * 70)
    print(f"  {d.get('workload', path.stem)}")
    print(f"  {path.name}")
    print("═" * 70)

    # ── Config ──────────────────────────────────────────────────────────────
    print()
    print("  CONFIG")
    print(f"    Driver:            {d.get('driver', '-')}")
    print(f"    Message size:      {msg_size:,} B")
    print(f"    Topics:            {d.get('topics', '-')}  ×  "
          f"{d.get('partitions', '-')} partitions")
    print(f"    Producers/topic:   {d.get('producersPerTopic', '-')}")
    print(f"    Consumers/topic:   {d.get('consumersPerTopic', '-')}")
    print(f"    Samples collected: {len(pub_rates)}")

    # ── Throughput ───────────────────────────────────────────────────────────
    print()
    print("  THROUGHPUT")
    print(f"    Avg publish rate:  {avg_pub:>10,.0f} msg/s  ({avg_mb:.2f} MB/s)")
    print(f"    Peak publish rate: {peak_pub:>10,.0f} msg/s  ({peak_mb:.2f} MB/s)")
    print(f"    Avg consume rate:  {avg_con:>10,.0f} msg/s")
    print(f"    Avg error rate:    {avg_err:>10.2f} err/s")
    print(f"    Backlog non-zero:  {pct_nonzero(backlogs):.1f}% of samples")

    # ── Publish latency (aggregated over whole test) ─────────────────────────
    print()
    print("  PUBLISH LATENCY  (ms — aggregated)")
    for label, key in [
        ("avg",    "aggregatedPublishLatencyAvg"),
        ("p50",    "aggregatedPublishLatency50pct"),
        ("p75",    "aggregatedPublishLatency75pct"),
        ("p95",    "aggregatedPublishLatency95pct"),
        ("p99",    "aggregatedPublishLatency99pct"),
        ("p99.9",  "aggregatedPublishLatency999pct"),
        ("p99.99", "aggregatedPublishLatency9999pct"),
        ("max",    "aggregatedPublishLatencyMax"),
    ]:
        val = d.get(key, 0)
        bar = "█" * min(int(val / 5), 40)
        print(f"    {label:<8}  {val:>8.2f}  {bar}")

    # ── End-to-end latency ───────────────────────────────────────────────────
    print()
    print("  END-TO-END LATENCY  (ms — aggregated)")
    for label, key in [
        ("avg",    "aggregatedEndToEndLatencyAvg"),
        ("p50",    "aggregatedEndToEndLatency50pct"),
        ("p75",    "aggregatedEndToEndLatency75pct"),
        ("p95",    "aggregatedEndToEndLatency95pct"),
        ("p99",    "aggregatedEndToEndLatency99pct"),
        ("p99.9",  "aggregatedEndToEndLatency999pct"),
        ("p99.99", "aggregatedEndToEndLatency9999pct"),
        ("max",    "aggregatedEndToEndLatencyMax"),
    ]:
        val = d.get(key, 0)
        bar = "█" * min(int(val / 5), 40)
        print(f"    {label:<8}  {val:>8.2f}  {bar}")

    # ── Publish delay latency ────────────────────────────────────────────────
    print()
    print("  PUBLISH DELAY LATENCY  (us — time in send buffer before network)")
    for label, key in [
        ("avg",   "aggregatedPublishDelayLatencyAvg"),
        ("p50",   "aggregatedPublishDelayLatency50pct"),
        ("p99",   "aggregatedPublishDelayLatency99pct"),
        ("p99.9", "aggregatedPublishDelayLatency999pct"),
        ("max",   "aggregatedPublishDelayLatencyMax"),
    ]:
        val = d.get(key, 0)
        print(f"    {label:<8}  {val:>10.0f} µs  ({val/1000:.2f} ms)")

    # ── Assessment ───────────────────────────────────────────────────────────
    checks = assess(d)
    passed = sum(1 for _, ok, _ in checks if ok)
    print()
    print(f"  ASSESSMENT  ({passed}/{len(checks)} checks passed)")
    for name, ok, detail in checks:
        icon = "✓" if ok else "✗"
        print(f"    [{icon}] {name:<30}  {detail}")

    overall = "PASS" if passed == len(checks) else "FAIL"
    print()
    print(f"  Overall: {overall}")
    print()


def print_comparison(results: list[tuple[Path, dict]]):
    """Print a side-by-side summary table."""
    cols = [d.get("workload", p.stem) for p, d in results]
    width = max(len(c) for c in cols)

    def row(label, vals):
        print(f"  {label:<38}", end="")
        for v in vals:
            print(f"  {str(v):>{width}}", end="")
        print()

    print()
    print("═" * (40 + (width + 2) * len(results)))
    print("  COMPARISON TABLE")
    print("═" * (40 + (width + 2) * len(results)))
    row("Workload", cols)
    print()

    def fmtvals(key, fmt=".0f", scale=1):
        return [format(d.get(key, 0) * scale, fmt) for _, d in results]

    row("Avg publish rate (msg/s)",    [f"{avg(d.get('publishRate',[0])):,.0f}" for _, d in results])
    row("Avg publish rate (MB/s)",     [f"{throughput_mb(avg(d.get('publishRate',[0])), d.get('messageSize',0)):.2f}" for _, d in results])
    row("Avg error rate (err/s)",      [f"{avg(d.get('publishErrorRate',[0])):.2f}" for _, d in results])
    row("Backlog non-zero (%)",         [f"{pct_nonzero(d.get('backlog',[])):.1f}" for _, d in results])
    print()
    row("Pub latency avg (ms)",        fmtvals("aggregatedPublishLatencyAvg", ".2f"))
    row("Pub latency p50 (ms)",        fmtvals("aggregatedPublishLatency50pct", ".2f"))
    row("Pub latency p99 (ms)",        fmtvals("aggregatedPublishLatency99pct", ".2f"))
    row("Pub latency p99.9 (ms)",      fmtvals("aggregatedPublishLatency999pct", ".2f"))
    row("Pub latency max (ms)",        fmtvals("aggregatedPublishLatencyMax", ".2f"))
    print()
    row("E2E latency avg (ms)",        fmtvals("aggregatedEndToEndLatencyAvg", ".2f"))
    row("E2E latency p50 (ms)",        fmtvals("aggregatedEndToEndLatency50pct", ".2f"))
    row("E2E latency p99 (ms)",        fmtvals("aggregatedEndToEndLatency99pct", ".2f"))
    row("E2E latency max (ms)",        fmtvals("aggregatedEndToEndLatencyMax", ".2f"))
    print()
    checks_row = []
    for _, d in results:
        checks = assess(d)
        passed = sum(1 for _, ok, _ in checks if ok)
        checks_row.append(f"{passed}/{len(checks)}")
    row("Checks passed",               checks_row)
    overall_row = []
    for _, d in results:
        checks = assess(d)
        overall_row.append("PASS" if all(ok for _, ok, _ in checks) else "FAIL")
    row("Overall",                     overall_row)
    print()


def main():
    args = sys.argv[1:]
    compare = "--compare" in args
    paths_args = [a for a in args if not a.startswith("--")]

    if paths_args:
        paths = [Path(p) for p in paths_args]
    else:
        paths = sorted(RESULTS_DIR.glob("*.json"))

    if not paths:
        print(f"No result files found in {RESULTS_DIR}")
        sys.exit(1)

    results = []
    for p in paths:
        if not p.exists():
            print(f"[WARN] Not found: {p}", file=sys.stderr)
            continue
        results.append((p, load(p)))

    for p, d in results:
        print_report(p, d)

    if compare or len(results) > 1:
        print_comparison(results)


if __name__ == "__main__":
    main()
