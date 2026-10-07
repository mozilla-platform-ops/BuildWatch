import SwiftUI

/// Treeherder's simple-view ring (`Ring.jsx`): a circle of ticks, each one standing for a
/// share of the push's jobs and coloured by their state.
struct TickRing<Center: View>: View {
    let status: [String: Int]?
    var ticks = 90
    var size: CGFloat = 240
    /// Stroke width in the ring's 200-unit coordinate space, as in the SVG.
    var weight: CGFloat = 3
    @ViewBuilder var center: () -> Center

    @State private var appeared = Date()
    @State private var introDone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kinds: [String] {
        guard let status else { return Array(repeating: "loading", count: ticks) }
        return Ticks.allocate(status, ticks: ticks)
    }

    var body: some View {
        let kinds = kinds
        let waves = !reduceMotion && kinds.contains { $0 == "running" || $0 == "loading" }

        TimelineView(.animation(paused: !waves && (introDone || reduceMotion))) { context in
            Canvas { canvas, area in
                draw(kinds, in: &canvas, size: area, at: context.date.timeIntervalSince(appeared))
            }
        }
        .frame(width: size, height: size)
        .overlay { center() }
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            introDone = true
        }
    }

    private func draw(_ kinds: [String], in canvas: inout GraphicsContext, size: CGSize, at t: TimeInterval) {
        let scale = size.width / 200
        let outer: CGFloat = 96
        let inner = outer - max(14, 1200 / CGFloat(ticks) / 2)
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)

        for (i, kind) in kinds.enumerated() {
            let angle = Double(i) / Double(ticks) * 2 * .pi - .pi / 2
            let (cos, sin) = (CGFloat(Foundation.cos(angle)), CGFloat(Foundation.sin(angle)))

            // Tick-in: each tick pops from 20% to full size, 700ms around the ring.
            var grow: CGFloat = 1
            var alpha = Ticks.baseOpacity(kind)
            if !reduceMotion {
                let local = (t - Double(i) * 0.7 / Double(ticks)) / 0.45
                let p = CGFloat(min(max(local, 0), 1))
                grow = 0.2 + 0.8 * Ticks.overshoot(p)
                alpha *= Double(p)
                if kind == "running" || kind == "loading" {
                    // The wave: opacity 1 → 0.25 → 1 every 2.4s, lagging round the ring.
                    let phase = (t - Double(i) / Double(ticks) * 2.4) / 2.4
                    alpha = Double(p) * (0.625 + 0.375 * Foundation.cos(2 * .pi * phase))
                }
            }

            let half = (outer - inner) / 2 * grow
            let centre = (outer + inner) / 2
            var line = Path()
            line.move(to: CGPoint(x: mid.x + cos * (centre - half) * scale, y: mid.y + sin * (centre - half) * scale))
            line.addLine(to: CGPoint(x: mid.x + cos * (centre + half) * scale, y: mid.y + sin * (centre + half) * scale))
            canvas.stroke(
                line,
                with: .color(Ticks.color(kind).opacity(alpha)),
                style: StrokeStyle(lineWidth: weight * scale * grow, lineCap: .round)
            )
        }
    }
}

/// What each tick stands for, and its colour.
nonisolated enum Ticks {

    /// `cubic-bezier(0.3, 1.4, 0.5, 1)`: overshoots a little, then settles.
    static func overshoot(_ p: CGFloat) -> CGFloat {
        let s: CGFloat = 1.6
        let q = p - 1
        return 1 + q * q * ((s + 1) * q + s)
    }

    static func baseOpacity(_ kind: String) -> Double {
        kind == "pending" || kind == "loading" ? 0.35 : 1
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "testfailed":  SV.testfailed
        case "busted":      SV.busted
        case "exception":   SV.exception
        case "success":     SV.success
        case "retry":       SV.retry
        case "usercancel":  SV.usercancel
        case "superseded":  SV.superseded
        case "running":     SV.running
        case "unscheduled": SV.unscheduled
        case "pending", "loading": SV.pending
        default:            SV.other
        }
    }

    private static let order = [
        "testfailed", "busted", "exception", "success", "retry", "usercancel", "superseded",
        "other", "running", "pending", "unscheduled",
    ]

    /// Shares the ticks out by job count, giving every state present at least one tick, and
    /// the leftovers to the largest remainders: `allocateTicks` in `Ring.jsx`.
    static func allocate(_ status: [String: Int], ticks: Int) -> [String] {
        var counts = Dictionary(uniqueKeysWithValues: order.map { ($0, status[$0] ?? 0) })
        let named = order.prefix(7).reduce(0) { $0 + counts[$1, default: 0] }
        counts["other"] = max(0, SimpleView.finishedCount(status) - named)

        let parts = order.map { ($0, counts[$0] ?? 0) }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return Array(repeating: "pending", count: ticks) }

        let nonEmpty = parts.filter { $0.1 > 0 }
        let spare = Double(ticks - nonEmpty.count)
        var shares = nonEmpty.map { kind, count in
            let exact = Double(count) / Double(total) * spare
            return (kind: kind, n: 1 + Int(exact), rest: exact.truncatingRemainder(dividingBy: 1))
        }
        var left = ticks - shares.reduce(0) { $0 + $1.n }
        for index in shares.indices.sorted(by: { shares[$0].rest > shares[$1].rest }) {
            guard left > 0 else { break }
            shares[index].n += 1
            left -= 1
        }
        return shares.flatMap { Array(repeating: $0.kind, count: $0.n) }
    }
}

extension TickRing where Center == EmptyView {
    init(status: [String: Int]?, ticks: Int = 90, size: CGFloat = 240, weight: CGFloat = 3) {
        self.init(status: status, ticks: ticks, size: size, weight: weight) { EmptyView() }
    }
}

/// Counts up to its value over 0.9s, like the web's `useCountUp`.
struct CountUp: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}
