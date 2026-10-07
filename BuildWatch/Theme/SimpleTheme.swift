import SwiftUI

/// The look of Treeherder's simple view (`ui/css/simple-view.css`), as SwiftUI values.
///
/// Every colour here is one Treeherder already ships: Bootstrap 5.3's body tokens with
/// Treeherder's `#337ab7` link colour, the `--th-*` bar colours, and the `--status-*` job
/// colours from `treeherder-job-buttons.css`. Dark mode follows Bootstrap's
/// `data-bs-theme="dark"` values, and the simple view's `color-mix()` dark status shades
/// are precomputed below.
nonisolated enum SV {

    // MARK: Page

    static let bg       = pair(light: 0xFFFFFF, dark: 0x212529)
    static let surface  = bg
    static let ink      = pair(light: 0x212529, dark: 0xDEE2E6)
    static let muted    = pair(light: 0x212529, dark: 0xDEE2E6, alpha: 0.75)
    static let hairline = pair(light: 0xDEE2E6, dark: 0x495057)
    static let wash     = pair(light: 0xF8F9FA, dark: 0x2B3035)
    static let skeleton = pair(light: 0xE9ECEF, dark: 0x343A40)
    static let link     = pair(light: 0x337AB7, dark: 0x6EA8FE)
    static let danger   = Color(rgb: 0xDC3545)

    // MARK: Bars

    static let topbar       = Color(rgb: 0x222222)
    static let topbarBorder = Color.black
    static let contextbar   = Color(rgb: 0x354048)
    static let infoBg       = pair(light: 0xD1ECF1, dark: 0x032830)
    static let infoInk      = pair(light: 0x0C5460, dark: 0x6EDFF6)
    static let warning      = Color(rgb: 0xFFC107)

    // MARK: Job status

    static let testfailed  = Color(rgb: 0xDD6602)
    static let busted      = Color(rgb: 0xB74C4C)
    static let exception   = Color(rgb: 0x9A7DA6)
    static let usercancel  = Color(rgb: 0xCF2B9F)
    static let superseded  = Color(rgb: 0x3F77C6)
    static let other       = Color(rgb: 0x8A6D3B)
    static let unscheduled = Color(rgb: 0x26D7B6)
    static let pending     = Color(rgb: 0x757575)
    static let success     = pair(light: 0x0F883D, dark: 0x429E66)
    static let successText = pair(light: 0x017722, dark: 0x67AD7A)
    static let running     = pair(light: 0x000000, dark: 0xDEE2E6)
    static let retry       = pair(light: 0x283AA2, dark: 0x737FC3)
    static let failureText = pair(light: 0xB45303, dark: 0xE48535)

    static let radius: CGFloat = 8
    static let maxWidth: CGFloat = 640

    private static func pair(light: Int, dark: Int, alpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light, alpha: alpha)
        })
    }
}

/// How a verdict or a push row reads: the `sv-tone-*` classes.
nonisolated enum Tone {
    case good, bad, running, quiet

    var color: Color {
        switch self {
        case .good:    SV.success
        case .bad:     SV.testfailed
        case .running: SV.running
        case .quiet:   SV.hairline
        }
    }

    var text: Color {
        switch self {
        case .good:    SV.successText
        case .bad:     SV.failureText
        case .running: SV.ink
        case .quiet:   SV.muted
        }
    }
}

extension Color {
    nonisolated init(rgb: Int) {
        self.init(uiColor: UIColor(rgb: rgb, alpha: 1))
    }
}

extension UIColor {
    nonisolated convenience init(rgb: Int, alpha: CGFloat) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8)  & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Type

/// The simple view's pixel sizes, scaled with Dynamic Type.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let monospaced: Bool

    init(size: CGFloat, weight: Font.Weight, monospaced: Bool) {
        let style: Font.TextStyle = switch size {
        case 28...: .title
        case 20..<28: .title3
        case 16..<20: .body
        case 14..<16: .subheadline
        case 12..<14: .footnote
        default: .caption
        }
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.monospaced = monospaced
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: monospaced ? .monospaced : .default))
    }
}

extension View {
    func svFont(_ size: CGFloat, _ weight: Font.Weight = .regular, monospaced: Bool = false) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, monospaced: monospaced))
    }

    /// `.sv-eyebrow` / `.sv-section-title`: small, bold, tracked capitals.
    func svCaps(_ size: CGFloat = 12) -> some View {
        svFont(size, .bold)
            .textCase(.uppercase)
            .tracking(size * 0.1)
    }

    /// `.sv-card`: a white card with a hairline border.
    func svCard() -> some View {
        background(SV.surface)
            .clipShape(RoundedRectangle(cornerRadius: SV.radius))
            .overlay(RoundedRectangle(cornerRadius: SV.radius).strokeBorder(SV.hairline))
    }

    /// `.sv-rise`, and `.sv-cascade` when given an index.
    func svRise(index: Int = 0) -> some View {
        modifier(Rise(delay: Double(index) * 0.045))
    }
}

private struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(.timingCurve(0.25, 0.6, 0.3, 1, duration: 0.45).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// `.sv-skeleton`: a shimmering placeholder bar.
struct Skeleton: View {
    var width: CGFloat = 140
    var height: CGFloat = 16
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(SV.skeleton)
            .frame(width: width, height: height)
            .opacity(dim ? 0.9 : 0.45)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// `.sv-press`: the 0.985 scale-down every tappable card does.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The `.sv-chevron` that turns over when a card opens.
struct Chevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .svFont(13, .semibold)
            .foregroundStyle(SV.muted)
            .rotationEffect(.degrees(open ? 180 : 0))
            .animation(.easeInOut(duration: 0.2), value: open)
            .accessibilityHidden(true)
    }
}

/// Wraps its children like CSS `flex-wrap`, so legends and card metadata reflow on
/// narrow phones and large text sizes instead of truncating.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = switch alignment {
            case .center: bounds.minX + (bounds.width - row.width) / 2
            case .trailing: bounds.maxX - row.width
            default: bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
