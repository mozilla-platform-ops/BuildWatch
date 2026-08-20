import SwiftUI

/// Status colours that stay legible in both appearances.
///
/// The previous palette was tuned against a dark canvas and three of its four colours
/// failed WCAG AA non-text contrast (3:1) on a white list row — success green sat at
/// **1.67:1**, effectively invisible. Each colour below is now a pair: a darkened light
/// variant (4.4:1–5.7:1 on white) and the original bright variant for dark mode
/// (5.6:1–12.1:1 on #1C1C1E), so dark mode looks unchanged and light mode becomes readable.
nonisolated enum StatusPalette {

    static let success   = pair(light: 0x0F8A4D, dark: 0x3DDC97)
    static let failed    = pair(light: 0xD92D3A, dark: 0xFF5A66)
    static let busted    = pair(light: 0xB45309, dark: 0xFFA033)
    static let exception = pair(light: 0x7C3AED, dark: 0xB794F6)
    static let retry     = pair(light: 0x8A6D00, dark: 0xFFD54A)
    static let running   = pair(light: 0x0B69D4, dark: 0x5AA9FF)
    static let idle      = Color(uiColor: .systemGray)

    private static func pair(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8)  & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }
}
