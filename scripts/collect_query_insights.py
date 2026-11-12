#!/usr/bin/env python3
"""
Collect Cloud SQL Query Insights data around the nightly CPU spike (~22:00 Asia/Bangkok)
for the last N days, and rank queries by CPU-ish time.

Data source: Cloud Monitoring metrics exported by Query Insights (PostgreSQL)
  cloudsql.googleapis.com/database/postgresql/insights/perquery/execution_time  (us, cumulative)
  cloudsql.googleapis.com/database/postgresql/insights/perquery/io_time         (us, cumulative)
  cloudsql.googleapis.com/database/postgresql/insights/perquery/lock_time       (us, cumulative)
  cloudsql.googleapis.com/database/postgresql/insights/perquery/row_count       (count, cumulative)
plus instance CPU utilisation to confirm when the spike actually happens.

Auth: uses `gcloud auth print-access-token` (needs roles/monitoring.viewer on the project).

Usage:
  python3 scripts/collect_query_insights.py --project cjx-app-pos \
      [--instance <instance-id>] [--days 7] [--start 21:30] [--end 23:00] [--tz Asia/Bangkok]

Outputs (in ./reports/):
  cpu_spike_by_day.csv        peak CPU per day inside the window
  query_insights_window.csv   per (day, query) totals
  query_insights_summary.md   top queries across all days, ready to take to the DB
"""
import argparse
import csv
import datetime as dt
import os
import subprocess
import sys
from collections import defaultdict
from zoneinfo import ZoneInfo

import requests

API = "https://monitoring.googleapis.com/v3/projects/{p}/timeSeries"
PQ = "cloudsql.googleapis.com/database/postgresql/insights/perquery/"
METRICS = ["execution_time", "io_time", "lock_time", "row_count"]
GROUP_BY = [
    "metric.label.query_hash",
    "metric.label.querystring",
    "metric.label.user",
    "resource.label.database",
    "resource.label.resource_id",
]


def token():
    return subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()


def rfc3339(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_ts(sess, project, flt, start, end, aligner, period_s, reducer=None, group_by=None):
    params = {
        "filter": flt,
        "interval.startTime": rfc3339(start),
        "interval.endTime": rfc3339(end),
        "aggregation.alignmentPeriod": f"{period_s}s",
        "aggregation.perSeriesAligner": aligner,
        "view": "FULL",
        "pageSize": 100000,
    }
    if reducer:
        params["aggregation.crossSeriesReducer"] = reducer
        params["aggregation.groupByFields"] = group_by or []
    out = []
    while True:
        r = sess.get(API.format(p=project), params=params, timeout=120)
        if r.status_code != 200:
            raise SystemExit(f"Monitoring API error {r.status_code}: {r.text[:500]}")
        js = r.json()
        out.extend(js.get("timeSeries", []))
        if not js.get("nextPageToken"):
            return out
        params["pageToken"] = js["nextPageToken"]


def pval(p):
    v = p["value"]
    return float(v.get("int64Value", v.get("doubleValue", 0)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="cjx-app-pos")
    ap.add_argument("--instance", help="Cloud SQL instance id (default: all instances in project)")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--start", default="21:30", help="window start, local time HH:MM")
    ap.add_argument("--end", default="23:00", help="window end, local time HH:MM")
    ap.add_argument("--tz", default="Asia/Bangkok")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--out", default="reports")
    a = ap.parse_args()

    tz = ZoneInfo(a.tz)
    sh, sm = map(int, a.start.split(":"))
    eh, em = map(int, a.end.split(":"))
    today = dt.datetime.now(tz).date()
    windows = []
    for d in range(a.days, 0, -1):
        day = today - dt.timedelta(days=d)
        s = dt.datetime(day.year, day.month, day.day, sh, sm, tzinfo=tz)
        e = dt.datetime(day.year, day.month, day.day, eh, em, tzinfo=tz)
        windows.append((day, s, e))
    # include today's window if it already finished
    s = dt.datetime(today.year, today.month, today.day, sh, sm, tzinfo=tz)
    e = dt.datetime(today.year, today.month, today.day, eh, em, tzinfo=tz)
    if e < dt.datetime.now(tz):
        windows.append((today, s, e))

    inst_filter = ""
    if a.instance:
        inst_filter = f' AND resource.label.database_id = "{a.project}:{a.instance}"'
    inst_filter_db = ""
    if a.instance:
        inst_filter_db = f' AND resource.label.resource_id = "{a.project}:{a.instance}"'

    sess = requests.Session()
    sess.headers["Authorization"] = f"Bearer {token()}"
    os.makedirs(a.out, exist_ok=True)

    # 1) Confirm the CPU spike per day (1-min max)
    cpu_rows = []
    for day, s, e in windows:
        ts = list_ts(sess, a.project,
                     'metric.type = "cloudsql.googleapis.com/database/cpu/utilization"'
                     ' AND resource.type = "cloudsql_database"' + inst_filter,
                     s, e, "ALIGN_MAX", 60)
        for series in ts:
            inst = series["resource"]["labels"].get("database_id")
            pts = sorted(series["points"], key=lambda p: p["interval"]["endTime"])
            if not pts:
                continue
            peak = max(pts, key=pval)
            peak_t = dt.datetime.fromisoformat(peak["interval"]["endTime"].replace("Z", "+00:00")).astimezone(tz)
            above = [p for p in pts if pval(p) >= 0.8]
            cpu_rows.append({
                "day": day.isoformat(), "instance": inst,
                "peak_cpu_pct": round(pval(peak) * 100, 1),
                "peak_at_local": peak_t.strftime("%H:%M"),
                "minutes_cpu_ge_80pct": len(above),
            })
    with open(os.path.join(a.out, "cpu_spike_by_day.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["day", "instance", "peak_cpu_pct", "peak_at_local", "minutes_cpu_ge_80pct"])
        w.writeheader()
        w.writerows(cpu_rows)

    # 2) Per-query totals per day inside the window
    per_day = defaultdict(lambda: defaultdict(float))  # (day, key) -> metric -> value
    meta = {}
    for day, s, e in windows:
        period = int((e - s).total_seconds())
        for m in METRICS:
            ts = list_ts(sess, a.project,
                         f'metric.type = "{PQ}{m}" AND resource.type = "cloudsql_instance_database"' + inst_filter_db,
                         s, e, "ALIGN_DELTA", period, "REDUCE_SUM", GROUP_BY)
            for series in ts:
                # labels from groupBy come back in metric/resource labels
                ml = series.get("metric", {}).get("labels", {})
                rl = series.get("resource", {}).get("labels", {})
                key = (ml.get("query_hash", ""), rl.get("database", ""), ml.get("user", ""), rl.get("resource_id", ""))
                meta.setdefault(key, ml.get("querystring", ""))
                per_day[(day.isoformat(), key)][m] += sum(pval(p) for p in series["points"])

    rows = []
    for (day, key), v in per_day.items():
        ex = v["execution_time"] / 1e6
        io = v["io_time"] / 1e6
        lk = v["lock_time"] / 1e6
        rows.append({
            "day": day, "instance": key[3], "database": key[1], "user": key[2], "query_hash": key[0],
            "exec_s": round(ex, 2), "io_s": round(io, 2), "lock_s": round(lk, 2),
            "cpu_est_s": round(max(ex - io - lk, 0), 2), "rows": int(v["row_count"]),
            "query": meta.get(key, "").replace("\n", " "),
        })
    rows.sort(key=lambda r: (r["day"], -r["cpu_est_s"]))
    with open(os.path.join(a.out, "query_insights_window.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["day"])
        w.writeheader()
        w.writerows(rows)

    # 3) Rank across days
    agg = defaultdict(lambda: {"cpu": 0.0, "exec": 0.0, "io": 0.0, "rows": 0, "days": set(), "daily": {}})
    for r in rows:
        k = (r["query_hash"], r["database"], r["user"], r["instance"])
        g = agg[k]
        g["cpu"] += r["cpu_est_s"]; g["exec"] += r["exec_s"]; g["io"] += r["io_s"]; g["rows"] += r["rows"]
        g["days"].add(r["day"]); g["daily"][r["day"]] = r["cpu_est_s"]
    total_cpu = sum(g["cpu"] for g in agg.values()) or 1
    ranked = sorted(agg.items(), key=lambda kv: -kv[1]["cpu"])[: a.top]
    day_list = [d.isoformat() for d, _, _ in windows]

    md = [f"# Query Insights – CPU window {a.start}-{a.end} ({a.tz}), {day_list[0]} .. {day_list[-1]}", "",
          "## CPU peak per day", "", "| day | instance | peak CPU % | peak at | minutes ≥80% |", "|---|---|---|---|---|"]
    for c in cpu_rows:
        md.append(f"| {c['day']} | {c['instance']} | {c['peak_cpu_pct']} | {c['peak_at_local']} | {c['minutes_cpu_ge_80pct']} |")
    md += ["", f"## Top {a.top} queries by estimated CPU time (exec − io − lock), summed over all windows", "",
           "| # | query_hash | db | user | CPU est (s) | % of window CPU | exec (s) | io (s) | rows | days seen |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for i, (k, g) in enumerate(ranked, 1):
        md.append(f"| {i} | `{k[0]}` | {k[1]} | {k[2]} | {g['cpu']:.1f} | {100*g['cpu']/total_cpu:.1f}% | "
                  f"{g['exec']:.1f} | {g['io']:.1f} | {g['rows']} | {len(g['days'])}/{len(day_list)} |")
    md += ["", "## Query text", ""]
    for i, (k, g) in enumerate(ranked, 1):
        daily = ", ".join(f"{d[5:]}={g['daily'].get(d, 0):.0f}s" for d in day_list)
        md += [f"### {i}. `{k[0]}` ({k[1]} / {k[2]})", f"Daily CPU est: {daily}", "", "```sql", meta.get(k, ""), "```", ""]
    with open(os.path.join(a.out, "query_insights_summary.md"), "w") as f:
        f.write("\n".join(md))
    print("\n".join(md[: 12 + len(cpu_rows) + a.top]))
    print(f"\nWrote {a.out}/cpu_spike_by_day.csv, query_insights_window.csv, query_insights_summary.md")


if __name__ == "__main__":
    sys.exit(main())
