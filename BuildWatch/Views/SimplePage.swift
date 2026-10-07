import SwiftUI

/// One screen of the app, laid out like a page of Treeherder's simple view: the dark
/// Treeherder bar, an optional context bar with the way back, an optional blue info bar,
/// then the content in a single centred column.
struct SimplePage<Info: View, Content: View>: View {
    var backLabel: String?
    let fullView: URL
    var refresh: (() async -> Void)?
    @ViewBuilder var info: () -> Info
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            TopBar(fullView: fullView, dark: colorScheme == .dark)
            if let backLabel {
                ContextBar(label: backLabel) { dismiss() }
            }
            if Info.self != EmptyView.self {
                InfoBar(content: info)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                    FooterNote()
                }
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: SV.maxWidth)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await refresh?() }
        }
        .background(SV.bg)
        .foregroundStyle(SV.ink)
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension SimplePage where Info == EmptyView {
    init(
        backLabel: String? = nil,
        fullView: URL,
        refresh: (() async -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(backLabel: backLabel, fullView: fullView, refresh: refresh, info: { EmptyView() }, content: content)
    }
}

// MARK: - Bars

/// `.sv-topbar`: the Treeherder logo, the dark-mode switch and the way out to the full view.
private struct TopBar: View {
    let fullView: URL
    let dark: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image("TreeherderLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .accessibilityLabel("Treeherder")
            Spacer()
            ThemeSwitch(dark: dark)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 20)
            Button { openURL(fullView) } label: {
                HStack(spacing: 4) {
                    Text(Strings.Nav.fullView)
                    Text("↗").accessibilityHidden(true)
                }
                .svFont(14)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.35)))
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(SV.topbar.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            SV.topbarBorder.frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The sun-and-moon switch. The app follows the system until it's used.
private struct ThemeSwitch: View {
    /// The page's scheme, read before the bar forces its own contents dark.
    let dark: Bool
    @AppStorage("theme") private var theme = ""

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { theme = dark ? "light" : "dark" }
        } label: {
            ZStack(alignment: dark ? .trailing : .leading) {
                Capsule()
                    .fill(dark ? Color(rgb: 0x6EA8FE) : .white.opacity(0.25))
                    .frame(width: 44, height: 24)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(dark ? SV.contextbar : SV.warning)
                    }
                    .padding(2)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.Nav.darkMode)
        .accessibilityValue(Strings.Nav.darkModeState(dark))
        .accessibilityAddTraits(.isToggle)
    }
}

/// `.sv-contextbar`: back to where you came from, with the repo on the right.
private struct ContextBar: View {
    let label: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Text("‹").svFont(22).accessibilityHidden(true)
                    Text(label).svFont(15)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PressStyle(scale: 0.97))
            Spacer()
            Text("try")
                .svFont(15, .bold)
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .background(SV.contextbar)
    }
}

/// `.sv-infobar`: the light-blue strip saying what the page is filtered to.
private struct InfoBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .svFont(14, .bold)
        .foregroundStyle(SV.infoInk)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(SV.infoBg)
    }
}

// MARK: - Shared pieces

/// The note under every page, where the web says the simple view is new.
private struct FooterNote: View {
    var body: some View {
        Text(note)
            .svFont(13)
            .foregroundStyle(SV.muted)
            .tint(SV.link)
            .padding(.horizontal, 6)
            .padding(.top, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: AttributedString {
        var text = AttributedString("BuildWatch \(Bundle.main.versionString). ")
        var link = AttributedString(Strings.Footer.report)
        link.link = Strings.feedbackURL
        link.underlineStyle = .single
        text.append(link)
        return text
    }
}

/// Kit, in one of four poses, chosen once per appearance.
struct Kit: View {
    @State private var pose = ["sitting-looking-up", "sitting-looking-forward", "inquisitive", "alert"].randomElement()!
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("Kit-\(pose)")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96, alignment: .bottomTrailing)
            .padding(.bottom, 6)
            .opacity(shown || reduceMotion ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.92, anchor: .bottom)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .accessibilityLabel(Strings.kitAlt)
            .onAppear {
                withAnimation(.timingCurve(0.3, 1.4, 0.5, 1, duration: 0.6).delay(0.2)) { shown = true }
            }
    }
}

/// `.sv-section-title` with its count.
struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).svCaps()
            if let count {
                Text("\(count)").svFont(12).foregroundStyle(SV.muted)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `.sv-link`: a plain blue text link, 48pt tall to tap.
struct TextLink: View {
    let title: String
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            Text(title)
                .svFont(14)
                .foregroundStyle(SV.link)
                .frame(minHeight: 48)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}

extension Bundle {
    /// "1.2 (10)", from the bundle so it always names the binary that's running.
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = infoDictionary?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}
