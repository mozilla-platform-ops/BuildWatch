import Foundation

/// When a try push will be done.
///
/// ## Why there are two numbers
///
/// A try push does not finish smoothly. Measured across a 907-job push: 90% of its jobs
/// were done at 47 minutes and the *last* one at 144. The tail is not slow work, it is
/// waiting — those final jobs ran for 12–25 minutes after queueing for 95–117. So a single
/// "done at" time is dominated by whichever worker pool happens to be backed up, and one
/// unlucky pool can stretch a push past ten hours.
///
/// Splitting it makes both numbers honest. Backtested by replaying 77 completed pushes at
/// nine points each:
///
/// | | median error | within ±25% | within ±50% | runs over by >30 min |
/// |---|---|---|---|---|
/// | `mostResultsBy` (90% of jobs) | **2 min** | **63%** | **88%** | **1%** |
/// | `allDoneBy` (last job) | 13 min | 39% | 62% | 32% |
///
/// `mostResultsBy` is the number to lead with — it answers "when will I know if this is
/// green", it is nearly unbiased, and it almost never overruns. `allDoneBy` is real but
/// soft, which is why the UI renders it as an approximation rather than a clock time.
///
/// ## How
///
/// Per worker pool, the jobs that have already started tell you what the ones that haven't
/// will wait: on one push, 76 jobs in `macosx1500-aarch64-shippable` had a p25, median and
/// p90 queue wait of 140.7, 140.7 and 144.6 minutes, because they are all gated on the same
/// build and released together. Add the expected run time from `JobDurationTable`, take the
/// projected finish of every unresolved job, and read off the 90th percentile and the max.
///
/// Naive alternatives were measured and rejected: extrapolating from percent-complete has a
/// median error of 84–165 minutes and a −50 to −105 minute bias, because the completion
/// curve is nowhere near linear.
nonisolated struct PushETA: Sendable, Equatable {

    /// When 90% of this push's jobs will have resolved. The headline number.
    let mostResultsBy: Date

    /// When the last job will resolve. Approximate by nature — see the type comment.
    let allDoneBy: Date

    /// The worker pool holding everything up, if one clearly is.
    let longPole: String?

    /// Unresolved jobs in `longPole`.
    let longPoleRemaining: Int

    /// When the push started, so the UI can draw elapsed against remaining.
    let pushedAt: Date

    let confidence: Confidence

    /// Set only when `confidence == .blockedOnBuild`.
    let blockingBuild: BlockingBuild?

    /// How much of the push we can actually see the shape of yet.
    ///
    /// The estimate only works once a pool has *someone* in it who has started — that is
    /// what reveals the pool's queue wait. Early on it doesn't: median pool coverage is 20%
    /// at 15 minutes in and 35% at 20, and estimates made in that window are wrong by
    /// around 113 minutes. So the UI shows nothing rather than something wrong.
    /// Three states, because there are three genuinely different situations and only one of
    /// them supports a countdown.
    ///
    /// A flat "rough estimate" band was tried and dropped. Below the firm bar the push ETA
    /// lands within ±50% only about half the time, and a range wide enough to be honest —
    /// 77% coverage — has to span 6×, i.e. "somewhere between one hour and six". That is not
    /// worth a hero slot. But the reason those pushes are unpredictable turned out to be
    /// specific and fixable: they are nearly all waiting on a build, and *build* finish
    /// times are sharp. So instead of a vague push ETA, that case shows the precise thing.
    enum Confidence: Sendable {
        /// Nothing to go on yet. Show progress, not a time. Only ~6% of the window.
        case estimating
        /// The push is gated on a build that is still running. Show the build's finish
        /// instead of the push's: measured over 4,438 running builds, the predicted end is
        /// within 5 minutes 71% of the time and within 10 minutes 80%.
        case blockedOnBuild
        /// Enough pools have started that the push ETA holds up: within ±25% of the true
        /// remaining time 70% of the time, and it overruns by more than half an hour in 1%
        /// of cases.
        case firm
    }

    /// The build chain everything is queued behind, when that is the whole story.
    struct BlockingBuild: Sendable, Equatable {
        /// The stage running right now — what to show the reader, because it is the part
        /// that is actually happening.
        let currentStage: String
        /// When the *last* stage of the chain is expected to land, which is when tests are
        /// released. Later than the running stage's own finish whenever stages remain.
        let releasesAt: Date
        /// Jobs that cannot start until then.
        let blockedJobs: Int
    }

    /// `allDoneBy` underestimates: with no correction the true finish is 1.9× the predicted
    /// remaining time at the median. Scaling the remaining span by 1.25 brings that to 1.5×
    /// and lifts within-±50% accuracy from 55% to 62%, while still overshooting by more than
    /// 2× in only 2% of cases. Erring long is the right direction for an ETA.
    private static let tailCalibration: Double = 1.25

    /// The estimate is only trustworthy once this share of the unresolved jobs sit in pools
    /// where something has already started — that is what reveals the pool's queue wait.
    ///
    /// 0.60 is where the accuracy cliff is. Coarsening the pool key to reach the bar sooner
    /// was tried and rejected: it lifts how often an ETA is shown from 28% to 32% of the
    /// window but drops within-±25% accuracy from 67% to 59% and takes overruns from 1% to
    /// 6%, because a pool key that ignores the build variant stops modelling the dependency
    /// that actually gates the wait.
    ///
    /// The bar is not as restrictive as it sounds: 83% of pushes clear it, at a median of 30
    /// minutes in, and then stay clear for a median 72% of what's left.
    private static let firmCoverage = 0.60

    /// The decision task has to land before there is anything to estimate.
    private static let minimumElapsed: TimeInterval = 8 * 60

    // MARK: - Estimation

    /// Returns `nil` when the push has no unresolved jobs — a finished push has no ETA.
    init?(jobs: [Job], pushedAt: Date, now: Date = Date(), table: JobDurationTable = .shared) {
        guard !jobs.isEmpty else { return nil }

        var resolvedEnds: [Date] = []
        var unresolved: [Job] = []
        var waitsByPool: [String: [TimeInterval]] = [:]

        for job in jobs {
            if job.state == .completed, let end = job.endDate {
                resolvedEnds.append(end)
            } else {
                unresolved.append(job)
            }
            // A start stamp is an observation of that pool's queue whether the job has
            // since finished or not, so completed jobs feed the wait table too.
            if let wait = job.queueWait {
                waitsByPool[job.poolKey, default: []].append(wait)
            }
        }

        guard !unresolved.isEmpty else { return nil }

        let poolWaits = waitsByPool.mapValues { Self.median($0) }
        let globalWait = poolWaits.isEmpty ? 0 : Self.median(Array(poolWaits.values))

        // A job in a pool nothing has started in is usually not idly queued — it is
        // waiting on a build. Finding that build turns "no idea" into a real release time:
        // one live push had 32 of its 37 unresolved jobs sitting in `unscheduled` behind a
        // single running macOS build, with no pool observation to go on at all.
        let gate = Self.buildGate(
            unresolved, poolWaits: poolWaits, globalWait: globalWait, now: now, table: table
        )

        var projected: [Date] = resolvedEnds
        projected.reserveCapacity(jobs.count)

        var worstEnd = Date.distantPast
        var worstPool: Job?
        var observedPools = 0

        for job in unresolved {
            let end: Date
            if let start = job.startDate {
                // Already running: the only unknown left is how long it runs.
                end = start.addingTimeInterval(table.expectedRunTime(for: job))
            } else {
                guard let submitted = job.submitDate else { continue }
                if let known = poolWaits[job.poolKey] {
                    observedPools += 1
                    // Never predict a wait shorter than the wait already served.
                    let wait = max(known, now.timeIntervalSince(submitted))
                    end = submitted
                        .addingTimeInterval(wait)
                        .addingTimeInterval(table.expectedRunTime(for: job))
                } else if let gate {
                    // Released when the build chain lands, then a normal queue wait on top.
                    end = max(gate.releasesAt, now)
                        .addingTimeInterval(globalWait)
                        .addingTimeInterval(table.expectedRunTime(for: job))
                } else {
                    let wait = max(globalWait, now.timeIntervalSince(submitted))
                    end = submitted
                        .addingTimeInterval(wait)
                        .addingTimeInterval(table.expectedRunTime(for: job))
                }
            }
            projected.append(end)
            if end > worstEnd {
                worstEnd = end
                worstPool = job
            }
        }

        guard projected.count > resolvedEnds.count else { return nil }

        projected.sort()
        let p90 = projected[min(projected.count - 1, Int(Double(projected.count) * 0.9))]
        let last = projected[projected.count - 1]

        self.pushedAt = pushedAt
        self.mostResultsBy = max(now, p90)
        self.allDoneBy = max(
            self.mostResultsBy,
            now.addingTimeInterval(max(0, last.timeIntervalSince(now)) * Self.tailCalibration)
        )

        let coverage = Double(observedPools) / Double(unresolved.count)
        let elapsed = now.timeIntervalSince(pushedAt)
        if elapsed >= Self.minimumElapsed && coverage >= Self.firmCoverage {
            confidence = .firm
            blockingBuild = nil
        } else if let gate, gate.releasesAt > now {
            confidence = .blockedOnBuild
            blockingBuild = BlockingBuild(
                currentStage: gate.currentStage,
                releasesAt: gate.releasesAt,
                blockedJobs: unresolved.count { $0.startDate == nil && poolWaits[$0.poolKey] == nil }
            )
        } else {
            confidence = .estimating
            blockingBuild = nil
        }

        // Only name a long pole when it is genuinely holding things up — otherwise the
        // callout is noise. The true long-pole pool is in this estimator's top three 86%
        // of the time but top *one* only 51%, so it is offered as a hint, not a fact.
        if let worstPool, worstEnd > self.mostResultsBy.addingTimeInterval(5 * 60) {
            longPole = worstPool.platformDisplay
            longPoleRemaining = unresolved.count { $0.poolKey == worstPool.poolKey }
        } else {
            longPole = nil
            longPoleRemaining = 0
        }
    }

    // MARK: - Display helpers

    /// Fraction of the estimated total wall time already elapsed, for the progress track.
    func progress(asOf now: Date = Date()) -> Double {
        let total = allDoneBy.timeIntervalSince(pushedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(pushedAt) / total))
    }

    /// Where `mostResultsBy` sits along that same track, so the UI can mark it.
    func mostResultsFraction() -> Double {
        let total = allDoneBy.timeIntervalSince(pushedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, mostResultsBy.timeIntervalSince(pushedAt) / total))
    }

    /// Walks the build chain stage by stage to find when tests are released.
    ///
    /// Each stage can only start once every earlier stage has landed, so the frontier is
    /// carried forward: a running stage is projected from its own start, and a stage that
    /// hasn't started is projected from the frontier plus a normal queue wait. Chaining
    /// rather than reading only the running stage shrinks the no-estimate dead zone from 13%
    /// of the window to 10% and lifts the gated tier's within-±50% accuracy from 54% to 58%,
    /// while leaving the firm tier untouched.
    private static func buildGate(
        _ unresolved: [Job], poolWaits: [String: TimeInterval], globalWait: TimeInterval,
        now: Date, table: JobDurationTable
    ) -> (releasesAt: Date, currentStage: String)? {
        var frontier: Date?
        var runningStage: (Date, String)?

        for stage in 0...3 {
            var ends: [Date] = []
            for job in unresolved where job.buildStage == stage {
                let run = table.expectedRunTime(for: job)
                if let start = job.startDate {
                    let end = start.addingTimeInterval(run)
                    ends.append(end)
                    // Prefer the latest-finishing running stage as the one to name.
                    if runningStage == nil || end > runningStage!.0 {
                        runningStage = (end, job.jobTypeName)
                    }
                } else if let frontier {
                    ends.append(frontier.addingTimeInterval(globalWait).addingTimeInterval(run))
                } else if let known = poolWaits[job.poolKey], let submitted = job.submitDate {
                    ends.append(
                        submitted
                            .addingTimeInterval(max(known, now.timeIntervalSince(submitted)))
                            .addingTimeInterval(run)
                    )
                }
            }
            if let stageEnd = ends.max() {
                frontier = max(frontier ?? stageEnd, stageEnd)
            }
        }

        guard let frontier, let runningStage else { return nil }
        return (frontier, runningStage.1)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
