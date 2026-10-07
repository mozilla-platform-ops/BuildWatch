import SwiftUI

enum Route: Hashable {
    case push(Push)
    case people
}

/// The app is one stack, like the simple view is one page: your pushes, a push, and the
/// "Pushes by…" picker.
struct ContentView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var path: [Route] = []
    @State private var safariURL: SafariURL?
    @AppStorage("theme") private var theme = ""
    @Environment(\.scenePhase) private var scenePhase

    /// Poll cadence. Fast while something is still building, slow once everything settled,
    /// so a push that finishes while you're looking at the list turns green on its own
    /// instead of waiting for a manual pull.
    private static let activeInterval: Duration = .seconds(30)
    private static let idleInterval: Duration = .seconds(120)

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if viewModel.username.isEmpty {
                    PeoplePicker()
                } else {
                    PushListScreen()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .push(let push):
                    PushScreen(push: push)
                case .people:
                    PeoplePicker(canGoBack: true) { path.removeAll() }
                }
            }
        }
        .environment(viewModel)
        .onChange(of: theme, initial: true) { applyTheme() }
        .onChange(of: scenePhase) { applyTheme() }
        .tint(SV.link)
        .environment(\.openURL, OpenURLAction { url in
            safariURL = SafariURL(url: url)
            return .handled
        })
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .sensoryFeedback(trigger: viewModel.haptic) { _, signal in
            signal.tick == 0 ? nil : signal.event.feedback
        }
        .task(id: viewModel.username) {
            guard !viewModel.username.isEmpty else { return }
            await viewModel.refresh()
            await pollLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPush)) { note in
            guard let id = note.userInfo?["pushId"] as? Int,
                  let push = viewModel.pushes.first(where: { $0.id == id })
            else { return }
            path = [.push(push)]
        }
    }

    /// Sets the theme on the window rather than with `preferredColorScheme`, which also
    /// flips the status bar to dark text in light mode, unreadable on the always-dark top bar.
    private func applyTheme() {
        let style: UIUserInterfaceStyle = theme == "dark" ? .dark : theme == "light" ? .light : .unspecified
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }

    /// Runs for as long as the app is up; skips work whenever it isn't frontmost.
    private func pollLoop() async {
        while !Task.isCancelled {
            let interval = viewModel.anyPushRunning ? Self.activeInterval : Self.idleInterval
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, scenePhase == .active else { continue }
            await viewModel.poll()
        }
    }
}

/// Hiding the navigation bar also switches off the swipe back, so put it back.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

#Preview {
    ContentView()
}
