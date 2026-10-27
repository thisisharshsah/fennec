import SwiftUI

/// The app's design system: spacing, radii, type, semantic colours and the creature's mood palette.
/// Every view takes its numbers and colours from here.
enum Theme {
    // MARK: Spacing (4/8/12/16/24/32)

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 18
        static let xl: CGFloat = 28
    }

    // MARK: Type scale (system fonts, scales with Dynamic Type)

    enum Text {
        /// Large rounded number for the hero and tile values.
        static let display = Font.system(.largeTitle, design: .rounded, weight: .semibold)
        static let statValue = Font.system(.title2, design: .rounded, weight: .semibold)
        static let title = Font.title3.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.caption
        static let caption2 = Font.caption2
        static let chip = Font.subheadline.weight(.medium)
        static let mono = Font.caption.monospaced()
    }

    // MARK: Semantic colours (adapt to light / dark without an asset catalog)

    static let background = Color.adaptive(light: "#F3F4F8", dark: "#0D0F15")
    static let surface = Color.adaptive(light: "#FFFFFF", dark: "#171A23")
    static let surfaceElevated = Color.adaptive(light: "#F1F3F8", dark: "#212531")
    static let textPrimary = Color.adaptive(light: "#15181F", dark: "#F2F4F8")
    static let textSecondary = Color.adaptive(light: "#6B7384", dark: "#98A1B3")
    static let accent = Color.adaptive(light: "#3B6FE0", dark: "#8FB3FF")
    static let hairline = Color.primary.opacity(0.08)
    static let positive = Color.adaptive(light: "#2FA85A", dark: "#7DDF8A")
    static let warning = Color.adaptive(light: "#D98A1C", dark: "#FFB347")
    static let negative = Color.adaptive(light: "#D64545", dark: "#FF7A7A")
    static let inactive = Color.adaptive(light: "#A3A9B6", dark: "#5B6373")

    /// Fill for icon circles and selected chips: the tint at a quiet opacity.
    static func tintFill(_ color: Color) -> Color { color.opacity(0.16) }

    // MARK: Mood palette (single source of truth; also the creature's cheek LEDs)

    enum MoodColor {
        static let neutral = "#8fb3ff"
        static let listening = "#6ea8ff"
        static let alert = "#ffb347"
        static let curious = "#b48cff"
        static let pleased = "#7ddf8a"
        static let surprised = "#ffd166"
        static let sleepy = "#4a5a7a"

        static func hex(for mood: Mood) -> String {
            switch mood {
            case .neutral: neutral
            case .listening: listening
            case .alert: alert
            case .curious: curious
            case .pleased: pleased
            case .surprised: surprised
            case .sleepy: sleepy
            }
        }

        static func color(for mood: Mood) -> Color { Color(hex: hex(for: mood)) }

        /// Colour for a mood name as reported by the unit; falls back to neutral.
        static func color(forName name: String) -> Color {
            color(for: Mood(rawValue: name) ?? .neutral)
        }
    }

    // MARK: Chart style

    static let chartLineWidth: CGFloat = 1.5
    static let sparklineHeight: CGFloat = 28

    // MARK: Layout

    /// Widest a column of content gets on a large window; keeps the Mac and iPad layouts calm.
    static let contentMaxWidth: CGFloat = 640
    #if os(macOS)
    static let minWindowSize = CGSize(width: 760, height: 540)
    #endif
}

extension Mood {
    var color: Color { Theme.MoodColor.color(for: self) }
}

// MARK: - Card

/// Surface fill, hairline border, soft shadow in light mode only.
struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat
    var fill: Color
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape
                    .fill(fill)
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(0.06) : .clear,
                        radius: 14,
                        y: 6
                    )
            }
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(
        padding: CGFloat = Theme.Spacing.l,
        fill: Color = Theme.surface,
        radius: CGFloat = Theme.Radius.l
    ) -> some View {
        modifier(CardModifier(padding: padding, fill: fill, radius: radius))
    }

    /// Full-screen themed background behind a scrolling screen.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Large navigation titles on iOS; macOS keeps its own title style.
    func largeNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        return navigationTitle(title).navigationBarTitleDisplayMode(.large)
        #else
        return navigationTitle(title)
        #endif
    }
}

// MARK: - Small shared pieces

/// Caption text in the secondary colour, used for captions, footers and status lines.
struct SecondaryText: View {
    let text: String
    var font: Font = Theme.Text.caption

    init(_ text: String, font: Font = Theme.Text.caption) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// A small coloured status dot.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An SF Symbol in a tinted circle, the shape used for event rows and setup states.
struct IconBadge: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(scale, 1.6)
        Image(systemName: systemName)
            .font(.system(size: side * 0.45, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(Theme.tintFill(tint), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Section header for cards: a title and an optional trailing view.
struct CardHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
    }
}

/// A friendly one-line empty state for a card.
struct EmptyLine: View {
    let text: String
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Theme.Spacing.m)
    }
}

// MARK: - Haptics

enum Haptics {
    /// A light tap for mood and gesture controls. No-op outside iOS.
    @MainActor
    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A firmer tap for primary actions (Add, Identify, Save).
    @MainActor
    static func medium() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Success notification (a creature arrived, a rename was sent).
    @MainActor
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Warning notification before destructive or disruptive actions are carried out.
    @MainActor
    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

// MARK: - Buttons

/// The big filled call to action used on the welcome screen and the setup intro.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.l)
            .background(isEnabled ? Theme.accent : Theme.inactive, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
