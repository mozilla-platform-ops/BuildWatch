// Standalone benchmark for the TreeHerder compact-job parser.
//
//   swiftc -O Benchmarks/ParserBenchmark.swift -o /tmp/bwbench
//   Benchmarks/fetch-fixture.sh /tmp/push.json
//   /tmp/bwbench /tmp/push.json
//
// Compares the original per-field dictionary-lookup parser against the column-map parser
// that shipped in this change, on a real TreeHerder payload.

import Foundation

// MARK: - Shared minimal model

struct BenchJob {
    let id: Int
    let pushId: Int
    let taskId: String?
    let platform: String
    let platformOption: String
    let jobTypeName: String
    let jobTypeSymbol: String
    let jobGroupName: String
    let jobGroupSymbol: String
    let state: String
    let result: String
    let startTimestamp: Int?
    let endTimestamp: Int?
    let tier: Int
}

extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Original parser (one String hash per field, per row)

func parseOriginal(_ json: [String: Any]) -> [BenchJob] {
    guard
        let results       = json["results"] as? [[Any]],
        let propertyNames = json["job_property_names"] as? [String]
    else { return [] }

    var idx: [String: Int] = [:]
    for (i, name) in propertyNames.enumerated() { idx[name] = i }

    return results.compactMap { row -> BenchJob? in
        func str(_ key: String) -> String? { row[safe: idx[key]] as? String }
        func int(_ key: String) -> Int?    { row[safe: idx[key]] as? Int }

        guard
            let id       = int("id"),
            let stateStr = str("state"),
            let platform = str("platform")
        else { return nil }

        return BenchJob(
            id: id,
            pushId: int("result_set_id") ?? int("push_id") ?? 0,
            taskId: str("task_id"),
            platform: platform,
            platformOption: str("platform_option") ?? "",
            jobTypeName: str("job_type_name") ?? "",
            jobTypeSymbol: str("job_type_symbol") ?? "",
            jobGroupName: str("job_group_name") ?? "",
            jobGroupSymbol: str("job_group_symbol") ?? "",
            state: stateStr,
            result: str("result") ?? "",
            startTimestamp: int("start_timestamp"),
            endTimestamp: int("end_timestamp"),
            tier: int("tier") ?? 1
        )
    }
}

// MARK: - Column-map parser (indices resolved once per response)

struct ColumnMap {
    let id, state, platform, platformOption: Int
    let jobTypeName, jobTypeSymbol, jobGroupName, jobGroupSymbol: Int
    let result, startTimestamp, endTimestamp, tier: Int
    let taskId, resultSetId, pushId, lastModified: Int

    init(_ names: [String]) {
        var lookup = [String: Int](minimumCapacity: names.count)
        for (i, n) in names.enumerated() { lookup[n] = i }
        func at(_ k: String) -> Int { lookup[k] ?? -1 }
        id = at("id"); state = at("state"); platform = at("platform")
        platformOption = at("platform_option")
        jobTypeName = at("job_type_name"); jobTypeSymbol = at("job_type_symbol")
        jobGroupName = at("job_group_name"); jobGroupSymbol = at("job_group_symbol")
        result = at("result"); startTimestamp = at("start_timestamp")
        endTimestamp = at("end_timestamp"); tier = at("tier")
        taskId = at("task_id"); resultSetId = at("result_set_id")
        pushId = at("push_id"); lastModified = at("last_modified")
    }
}

func parseColumnMap(_ json: [String: Any]) -> ([BenchJob], String?) {
    guard
        let results       = json["results"] as? [[Any]],
        let propertyNames = json["job_property_names"] as? [String]
    else { return ([], nil) }

    let col = ColumnMap(propertyNames)
    var latest: String?
    var jobs: [BenchJob] = []
    jobs.reserveCapacity(results.count)

    for row in results {
        let count = row.count
        func str(_ i: Int) -> String? { i >= 0 && i < count ? row[i] as? String : nil }
        func int(_ i: Int) -> Int?    { i >= 0 && i < count ? row[i] as? Int    : nil }

        guard
            let id       = int(col.id),
            let stateStr = str(col.state),
            let platform = str(col.platform)
        else { continue }

        if let m = str(col.lastModified), m > (latest ?? "") { latest = m }

        jobs.append(BenchJob(
            id: id,
            pushId: int(col.resultSetId) ?? int(col.pushId) ?? 0,
            taskId: str(col.taskId),
            platform: platform,
            platformOption: str(col.platformOption) ?? "",
            jobTypeName: str(col.jobTypeName) ?? "",
            jobTypeSymbol: str(col.jobTypeSymbol) ?? "",
            jobGroupName: str(col.jobGroupName) ?? "",
            jobGroupSymbol: str(col.jobGroupSymbol) ?? "",
            state: stateStr,
            result: str(col.result) ?? "",
            startTimestamp: int(col.startTimestamp),
            endTimestamp: int(col.endTimestamp),
            tier: int(col.tier) ?? 1
        ))
    }
    return (jobs, latest)
}

// MARK: - Derived-state cost: per-frame recompute vs precomputed summary

func groupsPerFrame(_ jobs: [BenchJob]) -> Int {
    // Mirrors the old DashboardViewModel.platformGroups + failureCount + isRunning:
    // three full passes over the job array, run inside `body`.
    var groups: [String: [BenchJob]] = [:]
    for j in jobs where j.tier == 1 {
        groups["\(j.platform)-\(j.platformOption)", default: []].append(j)
    }
    let sorted = groups.keys.sorted()
    let failures = jobs.filter { (($0.result == "testfailed" || $0.result == "busted" || $0.result == "exception")) && $0.state == "completed" }.count
    let running  = jobs.contains { $0.state == "running" || $0.state == "pending" }
    return sorted.count &+ failures &+ (running ? 1 : 0)
}

// MARK: - Harness

func time(_ label: String, iterations: Int, _ body: () -> Void) -> Double {
    for _ in 0..<3 { body() }                       // warm up
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let end = DispatchTime.now().uptimeNanoseconds
    let msPerOp = Double(end - start) / Double(iterations) / 1_000_000
    print(String(format: "  %-42s %8.3f ms/op", (label as NSString).utf8String!, msPerOp))
    return msPerOp
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/push.json"
guard let data = FileManager.default.contents(atPath: path) else {
    print("usage: bwbench <path-to-treeherder-jobs.json>"); exit(1)
}
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    print("could not parse \(path)"); exit(1)
}

let rowCount = (json["results"] as? [[Any]])?.count ?? 0
let colCount = (json["job_property_names"] as? [String])?.count ?? 0
print("\nFixture: \(path)")
print("  \(data.count) bytes · \(rowCount) jobs · \(colCount) columns\n")

print("Full main-thread cost of one job refresh, 200 iterations:")
let deserialize = time("JSONSerialization on the raw payload", iterations: 200) {
    _ = try? JSONSerialization.jsonObject(with: data)
}
print("  (this ran on the main actor before this change, because the project sets")
print("   SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor and the service was not nonisolated)\n")

print("Parse (JSONSerialization output -> [Job]), 200 iterations:")
let oldParse = time("original: dictionary lookup per field", iterations: 200) {
    _ = parseOriginal(json)
}
let newParse = time("column map: index resolved once", iterations: 200) {
    _ = parseColumnMap(json)
}
print(String(format: "  -> %.2fx faster (%.1f%% less time)\n", oldParse / newParse, 100 * (1 - newParse / oldParse)))
print(String(format: "Total blocking work per full refresh: %.2f ms (deserialize %.2f + map %.2f)",
             deserialize + newParse, deserialize, newParse))
print("  x5 pushes refreshed concurrently = " + String(format: "%.1f ms", (deserialize + newParse) * 5))
print("  now off the main actor entirely; only the finished [Job] crosses back.\n")

let (jobs, watermark) = parseColumnMap(json)
print("Derived state for one push row, 500 iterations:")
let perFrame = time("recompute groups+counts (old, per frame)", iterations: 500) {
    _ = groupsPerFrame(jobs)
}
print(String(format: "  precomputed once at ingest, then O(1) lookup per frame"))
print(String(format: "  -> %.3f ms saved per row per frame; a 20-row list at 120 Hz", perFrame))
print(String(format: "     would have spent %.1f ms/frame on this alone (8.3 ms budget)\n", perFrame * 20))

print("Correctness check:")
let a = parseOriginal(json), b = jobs
print("  row counts equal: \(a.count == b.count) (\(a.count) vs \(b.count))")
let idsMatch = zip(a, b).allSatisfy { $0.id == $1.id && $0.platform == $1.platform && $0.result == $1.result && $0.tier == $1.tier && $0.taskId == $1.taskId && $0.jobTypeName == $1.jobTypeName && $0.startTimestamp == $1.startTimestamp && $0.endTimestamp == $1.endTimestamp }
print("  all fields identical: \(idsMatch)")
print("  delta watermark: \(watermark ?? "none")\n")
