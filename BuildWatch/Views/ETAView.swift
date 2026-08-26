import SwiftUI

// MARK: - Hero card

/// The ETA, as the first thing you see on a push.
///
/// Leads with the number that is actually reliable — when 90% of the jobs will be in — and
/// keeps the full finish as a softer secondary, because the last job is the one part of a
/// try push that genuinely cannot be pinned down. See `PushETA` for the measurements behind
/// that split.
struct PushETACard: View {
    let eta: PushETA
    let summary: PushSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var trackHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch eta.confidence {
            case .firm:
                headline
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ETATimelineTrack(
                        eta: eta,
                        summary: summary,
                        now: context.date,
                        height: trackHeight,
                        animates: !reduceMotion
                    )
                }
                footer

            case .blockedOnBuild:
                // Show the build's finish, not the push's. The build's is sharp and the
                // push's is not, and "nothing can start until this lands" is the actual
                // answer to why the screen looks frozen.
                if let build = eta.blockingBuild { buildHeadline(build) }
                JobCountTrack(summary: summary, height: trackHeight, animates: !reduceMotion)
                estimatingFooter

            case .estimating:
                // No clock times anywhere in this branch. Showing a "most results by"
                // marker while also saying "estimating" would be claiming the number we
                // just declined to make.
                estimatingHeadline
                JobCountTrack(summary: summary, height: trackHeight, animates: !reduceMotion)
                estimatingFooter
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Headline

    private var headline: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let remaining = eta.mostResultsBy.timeIntervalSince(context.date)

            VStack(alignment: .leading, spacing: 2) {
                Text("MOST RESULTS IN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(remaining <= 30 ? "any moment" : remaining.etaCountdown)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(StatusPalette.running)

                    if remaining > 30 {
                        Text("by \(eta.mostResultsBy.clockTime)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut, value: Int(remaining / 60))
        }
    }

    private func buildHeadline(_ build: PushETA.BlockingBuild) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let remaining = build.releasesAt.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: 3) {
                Text("TESTS START IN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(remaining <= 30 ? "any moment" : remaining.etaCountdown)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(StatusPalette.busted)
                    Image(systemName: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(StatusPalette.busted.opacity(0.7))
                }

                Text("building · \(build.currentStage)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if build.blockedJobs > 0 {
                    Text("\(build.blockedJobs) job\(build.blockedJobs == 1 ? "" : "s") waiting on it")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut, value: Int(remaining / 60))
        }
    }

    /// Before the first jobs in each pool start there is nothing to go on — an estimate made
    /// in that window is off by roughly 113 minutes, so it isn't offered.
    private var estimatingHeadline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ESTIMATING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 8) {
                Text("Waiting for jobs to start")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                PulsingDots()
            }
        }
    }

    /// What is knowable before the estimate is: how much has landed, and how long it's been.
    private var estimatingFooter: some View {
        let resolved = summary.successCount + summary.failureCount
        let total = summary.totalCount + summary.lowerTierTotal
        return HStack(spacing: 4) {
            Text("\(resolved) of \(total) jobs done")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(eta.pushedAt.shortTimeAgo()) elapsed")
                .foregroundStyle(.tertiary)
        }
        .font(.caption.monospacedDigit())
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            if let longPole = eta.longPole {
                Label {
                    HStack(spacing: 4) {
                        Text(longPole).fontWeight(.medium)
                        if eta.longPoleRemaining > 0 {
                            Text("· \(eta.longPoleRemaining) left").foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "tortoise")
                }
                .font(.caption)
                .foregroundStyle(StatusPalette.busted)
                .lineLimit(2)
            }

            Spacer(minLength: 0)

            if eta.confidence != .estimating {
                Text("all done ~\(eta.allDoneBy.etaShortClock)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    private var accessibilityLabel: String {
        if eta.confidence == .estimating {
            return "Estimating completion time, waiting for jobs to start"
        }
        if let build = eta.blockingBuild, eta.confidence == .blockedOnBuild {
            return "Tests start in about \(build.releasesAt.timeIntervalSinceNow.etaSpoken), "
                + "currently building \(build.currentStage), "
                + "\(build.blockedJobs) jobs waiting"
        }
        var parts = [
            "Most results in \(eta.mostResultsBy.timeIntervalSinceNow.etaSpoken), by \(eta.mostResultsBy.clockTime)",
            "all jobs done around \(eta.allDoneBy.clockTime)",
        ]
        if let longPole = eta.longPole {
            parts.append("\(longPole) is the long pole, \(eta.longPoleRemaining) jobs left")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Timeline track

/// Push → now → done, as one bar.
///
/// The filled span is the push's actual outcome so far, split green/red/blue by what the
/// jobs did, so the bar carries the counts and the timing in one object instead of two. The
/// faint remainder is what's left, and the notch is `mostResultsBy` — which is why the notch
/// usually sits well short of the end.
private struct ETATimelineTrack: View {
    let eta: PushETA
    let summary: PushSummary
    let now: Date
    let height: CGFloat
    let animates: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                let elapsed = eta.progress(asOf: now)
                let notch = eta.mostResultsFraction()

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .systemGray5))

                    // Outcome so far, in proportion.
                    let filled = max(height, width * elapsed)
                    HStack(spacing: 0) {
                        ForEach(segments, id: \.0) { _, color, share in
                            Rectangle().fill(color).frame(width: filled * share)
                        }
                    }
                    .frame(width: filled, alignment: .leading)
                    .clipShape(Capsule())

                    // Where most of the answers land.
                    Capsule()
                        .fill(.background)
                        .frame(width: 2.5, height: height + 5)
                        .offset(x: min(width - 2.5, width * notch))
                        .opacity(notch < 0.99 ? 1 : 0)
                }
                .animation(animates ? .easeInOut(duration: 0.5) : nil, value: elapsed)
            }
            .frame(height: height)

            HStack(spacing: 4) {
                Text(eta.pushedAt.clockTime)
                Spacer()
                Text("most results")
                    .foregroundStyle(StatusPalette.running)
                Spacer()
                Text(eta.allDoneBy.clockTime)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    /// Resolved-so-far, split by outcome. Shares sum to 1, so the filled span reads as the
    /// push's actual result mix rather than an undifferentiated blue bar.
    private var segments: [(String, Color, Double)] {
        let counts: [(String, Color, Int)] = [
            ("pass", StatusPalette.success, summary.successCount),
            ("fail", StatusPalette.failed,  summary.failureCount),
            ("run",  StatusPalette.running, summary.runningCount),
        ].filter { $0.2 > 0 }
        let total = counts.reduce(0) { $0 + $1.2 }
        guard total > 0 else { return [("run", StatusPalette.running, 1)] }
        return counts.map { ($0.0, $0.1, Double($0.2) / Double(total)) }
    }
}

// MARK: - Job-count track

/// Progress by job count rather than by time — used while there is no trustworthy ETA, so
/// the card still shows something true.
private struct JobCountTrack: View {
    let summary: PushSummary
    let height: CGFloat
    let animates: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(1, summary.totalCount + summary.lowerTierTotal)
            let done = Double(summary.successCount + summary.failureCount) / Double(total)
            let running = Double(summary.runningCount) / Double(total)

            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .systemGray5))
                HStack(spacing: 0) {
                    Rectangle().fill(StatusPalette.success)
                        .frame(width: width * done * successShare)
                    Rectangle().fill(StatusPalette.failed)
                        .frame(width: width * done * (1 - successShare))
                    Rectangle().fill(StatusPalette.running)
                        .frame(width: width * running)
                }
                .clipShape(Capsule())
            }
            .animation(animates ? .easeInOut(duration: 0.5) : nil, value: done + running)
        }
        .frame(height: height)
    }

    private var successShare: Double {
        let resolved = summary.successCount + summary.failureCount
        return resolved == 0 ? 1 : Double(summary.successCount) / Double(resolved)
    }
}

// MARK: - Compact pill

/// The same estimate, shrunk to fit a list row beside the status dots.
struct ETAPill: View {
    let eta: PushETA

    var body: some View {
        switch eta.confidence {
        case .estimating:
            EmptyView()
        case .blockedOnBuild:
            if let build = eta.blockingBuild {
                pill(target: build.releasesAt, icon: "hammer.fill", tint: StatusPalette.busted)
            }
        case .firm:
            pill(target: eta.mostResultsBy, icon: "clock", tint: StatusPalette.running)
        }
    }

    private func pill(target: Date, icon: String, tint: Color) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = target.timeIntervalSince(context.date)
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(remaining <= 60 ? "now" : remaining.etaCountdown)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
        }
        .accessibilityHidden(true)   // the row speaks this as part of one phrase
    }
}

// MARK: - Pulsing dots

/// Reuses the push list's loading idiom so "estimating" reads as the same kind of waiting.
private struct PulsingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(uiColor: .systemGray3))
                    .frame(width: 4, height: 4)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.7).repeatForever().delay(Double(index) * 0.15),
                        value: pulse
                    )
            }
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Formatting

extension TimeInterval {
    /// `"2h 15m"`, `"45m"`, `"< 1m"` — tight enough for a countdown that ticks.
    var etaCountdown: String {
        let minutes = Int((self / 60).rounded(.down))
        if minutes < 1 { return "< 1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Spelled out, for VoiceOver.
    var etaSpoken: String {
        let minutes = Int((self / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        var text = "\(hours) hour\(hours == 1 ? "" : "s")"
        if rest > 0 { text += " \(rest) minute\(rest == 1 ? "" : "s")" }
        return text
    }
}

extension Date {
    /// `15:48` or `3:48 PM`, per the reader's locale.
    var clockTime: String {
        formatted(date: .omitted, time: .shortened)
    }

    /// Same, but says the day when the estimate runs past midnight — a backed-up hardware
    /// pool really can push a try job into tomorrow, and "3:48 AM" alone reads as a bug.
    var etaShortClock: String {
        Calendar.current.isDateInToday(self)
            ? clockTime
            : "\(formatted(.dateTime.weekday(.abbreviated))) \(clockTime)"
    }
}
