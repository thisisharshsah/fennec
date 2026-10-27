import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension Color {
    init(hex: String, fallback: Color = .blue) {
        guard let rgb = Color.rgb(hex: hex) else {
            self = fallback
            return
        }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// A colour that resolves to `light` or `dark` (hex strings) with the current appearance,
    /// without an asset catalog entry.
    static func adaptive(light: String, dark: String) -> Color {
        let lightRGB = rgb(hex: light) ?? (0.5, 0.5, 0.5)
        let darkRGB = rgb(hex: dark) ?? lightRGB
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? darkRGB : lightRGB
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? darkRGB : lightRGB
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }

    /// Parses "#rgb", "#rrggbb" or the same without the hash into unit-interval components.
    static func rgb(hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
