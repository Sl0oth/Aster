import SwiftUI

/// The accent color used across Aster. Chosen in Settings → General.
enum AsterAccent: String, CaseIterable, Identifiable {
    case purple
    case indigo
    case blue
    case teal
    case green
    case orange
    case pink
    case red
    case graphite

    static let defaultsKey = "Aster.Appearance.accent"

    static var current: AsterAccent {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AsterAccent.init(rawValue:)) ?? .purple
    }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    private var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .purple: (0.48, 0.20, 0.96)
        case .indigo: (0.35, 0.34, 0.92)
        case .blue: (0.16, 0.48, 0.98)
        case .teal: (0.10, 0.66, 0.72)
        case .green: (0.20, 0.70, 0.36)
        case .orange: (0.96, 0.52, 0.12)
        case .pink: (0.95, 0.26, 0.56)
        case .red: (0.92, 0.24, 0.24)
        case .graphite: (0.50, 0.52, 0.58)
        }
    }

    var color: Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }

    /// A darker shade for titles and background washes.
    var deepColor: Color {
        if self == .purple { return Color(red: 0.27, green: 0.07, blue: 0.58) }
        return Color(
            red: components.red * 0.58,
            green: components.green * 0.58,
            blue: components.blue * 0.58
        )
    }

    /// A light tint that stays readable as text on Aster's dark surfaces.
    var lightColor: Color {
        if self == .purple { return Color(red: 0.80, green: 0.72, blue: 1.0) }
        return Color(
            red: components.red + (1 - components.red) * 0.6,
            green: components.green + (1 - components.green) * 0.6,
            blue: components.blue + (1 - components.blue) * 0.6
        )
    }
}

extension Color {
    static var asterAccent: Color { AsterAccent.current.color }
    static var asterAccentDeep: Color { AsterAccent.current.deepColor }
    static var asterAccentLight: Color { AsterAccent.current.lightColor }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

/// Rebuilds a view tree when the accent color changes, so every surface that
/// reads `Color.asterAccent` picks up the new color immediately.
private struct AsterAccentAware: ViewModifier {
    @AppStorage(AsterAccent.defaultsKey) private var accent = AsterAccent.purple.rawValue

    func body(content: Content) -> some View {
        content
            .id(accent)
            .tint(Color.asterAccent)
    }
}

extension View {
    func asterAccentAware() -> some View {
        modifier(AsterAccentAware())
    }
}
