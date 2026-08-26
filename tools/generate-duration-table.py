#!/usr/bin/env python3
"""Rebuild BuildWatch/Resources/JobDurations.json from real try pushes.

The ETA's accuracy rests on this table: the same estimator built only from a push's own
completed jobs lands within +/-25% just 12% of the time, versus 63% with the table.

Run it when job definitions have drifted enough that the miss rate matters -- every few
months is plenty, since a job's run time has a median coefficient of variation of 5%.

    python3 tools/generate-duration-table.py --days 3 -o BuildWatch/Resources/JobDurations.json

Reads only public, unauthenticated TreeHerder endpoints. Takes ~15 minutes and makes a few
hundred requests against a shared public service, so it sleeps between them.
"""
import argparse, collections, json, random, re, statistics, sys, time, urllib.request

BASE = "https://treeherder.mozilla.org/api/project/try"
UA = {"User-Agent": "BuildWatch-table-builder/1.0 (+https://github.com/mozilla-platform-ops/BuildWatch)"}

# Anything longer than this is a hung job, not a duration worth learning from.
MAX_JOB_MINUTES = 720
# An entry needs at least this many observations before its median means anything.
MIN_OBSERVATIONS = 2
# Keep an exact per-job-type entry only when it differs from its chunk family by more than
# this -- chunks of one suite run near-identically, so most exact entries are redundant.
# Pruning on this cut the table from 286 KB to 137 KB with no loss of accuracy.
FAMILY_TOLERANCE = 0.10


def get(url, attempts=4):
    for attempt in range(attempts):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120))
        except Exception as exc:  # noqa: BLE001 - transient network, retry
            print(f"  retry {attempt}: {type(exc).__name__}", file=sys.stderr)
            time.sleep(4)
    return None


def recent_pushes(days):
    """Walk back `days` of try pushes.

    Paginated with `id__lt`, never `?page=` or `?offset=`: TreeHerder's push endpoint
    silently ignores both and re-serves page one, which duplicates rows without erroring.
    """
    newest = get(f"{BASE}/push/?count=1")["results"][0]
    cutoff = newest["push_timestamp"] - days * 86400
    cursor, out, seen = newest["id"], [], set()
    while True:
        batch = get(f"{BASE}/push/?count=100&id__lt={cursor}")
        if not batch or not batch["results"]:
            break
        for push in batch["results"]:
            if push["id"] not in seen:
                seen.add(push["id"])
                out.append(push)
        cursor = min(p["id"] for p in batch["results"])
        if min(p["push_timestamp"] for p in batch["results"]) < cutoff:
            break
    return out


def family_key(job_type_name):
    return re.sub(r"-\d+$", "", job_type_name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=3)
    ap.add_argument("--pushes", type=int, default=400, help="how many pushes to sample")
    ap.add_argument("-o", "--out", default="BuildWatch/Resources/JobDurations.json")
    args = ap.parse_args()

    pushes = recent_pushes(args.days)
    print(f"{len(pushes)} pushes in the last {args.days} days", file=sys.stderr)
    random.seed(7)
    sample = random.sample(pushes, min(args.pushes, len(pushes)))

    exact, family, platform, everything = (
        collections.defaultdict(list), collections.defaultdict(list),
        collections.defaultdict(list), [],
    )
    for i, push in enumerate(sample):
        payload = get(f"{BASE}/jobs/?push_id={push['id']}&count=2000&return_type=list")
        if not payload or not payload.get("job_property_names"):
            continue
        # A response of exactly 2000 rows is TreeHerder's cap, not a job count -- the rest
        # are silently dropped, so the push is unusable rather than merely incomplete.
        if len(payload["results"]) >= 2000:
            continue
        col = {name: n for n, name in enumerate(payload["job_property_names"])}
        for row in payload["results"]:
            start, end = row[col["start_timestamp"]], row[col["end_timestamp"]]
            if not start or not end or end <= start:
                continue
            minutes = (end - start) / 60
            if minutes <= 0 or minutes > MAX_JOB_MINUTES:
                continue
            name = row[col["job_type_name"]]
            exact[name].append(minutes)
            family[family_key(name)].append(minutes)
            platform[f'{row[col["platform"]]}|{row[col["platform_option"]]}'].append(minutes)
            everything.append(minutes)
        if i % 25 == 0:
            print(f"  {i}/{len(sample)} pushes, {len(everything)} jobs", file=sys.stderr)
        time.sleep(0.15)

    if not everything:
        sys.exit("no jobs collected")

    med = lambda vs: round(statistics.median(vs), 1)  # noqa: E731
    fam_table = {k: med(v) for k, v in family.items() if len(v) >= MIN_OBSERVATIONS}
    exact_table = {}
    for name, values in exact.items():
        if len(values) < MIN_OBSERVATIONS:
            continue
        value = med(values)
        inherited = fam_table.get(family_key(name))
        if inherited is None or abs(value - inherited) > max(1.0, FAMILY_TOLERANCE * inherited):
            exact_table[name] = value

    table = {
        "generated": time.strftime("%Y-%m-%d"),
        "jobsSampled": len(everything),
        "global": med(everything),
        "exact": exact_table,
        "family": fam_table,
        "platform": {k: med(v) for k, v in platform.items() if len(v) >= 3},
    }
    blob = json.dumps(table, separators=(",", ":"), sort_keys=True)
    with open(args.out, "w") as fh:
        fh.write(blob)
    print(
        f"wrote {args.out}: {len(exact_table)} exact, {len(fam_table)} family, "
        f"{len(table['platform'])} platform, {len(blob) // 1024} KB",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
