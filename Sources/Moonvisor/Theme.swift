import MoonvisorCore
import SwiftUI

/// Moon-Theme: Nachtblau + Lila, übernommen aus Luna-OS/Moon-Windows-Theme und Moon-Terminal.
enum Moon {
    static let night = Color(hex: 0x10121C)        // Grundfläche
    static let deep = Color(hex: 0x0E0B1F)         // Fensterhintergrund
    static let panel = Color(hex: 0x14172A)        // Titel-/Werkzeugleisten
    static let card = Color(hex: 0x1A1535)         // Karten
    static let cardHover = Color(hex: 0x231C47)
    static let line = Color(hex: 0x262A44)         // Trennlinien
    static let indigo = Color(hex: 0x3A3168)

    static let accent = Color(hex: 0x8E7CFF)       // Lila-Akzent
    static let accentLight = Color(hex: 0xB8ABFF)
    static let accentDeep = Color(hex: 0x6A57E0)
    static let accentDark = Color(hex: 0x4B3AB3)

    static let text = Color(hex: 0xEEEAFF)
    static let textSecondary = Color(hex: 0xD0C8F5)
    static let textMuted = Color(hex: 0xABA3D6)

    static let mint = Color(hex: 0x8EE3C0)         // läuft
    static let gold = Color(hex: 0xF5D78E)         // angehalten
    static let rose = Color(hex: 0xFF8FB1)         // Fehler / ausschalten

    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Sternenhimmel-Hintergrund wie in den Moon-Wallpapers.
    static let sky = LinearGradient(
        colors: [Color(hex: 0x130F28), Color(hex: 0x0E0B1F), Color(hex: 0x10121C)],
        startPoint: .top, endPoint: .bottom
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Dezente Sterne, deterministisch verteilt.
struct StarField: View {
    var count = 70

    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt32.max >> 1)
            }
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height
                let r = 0.4 + next() * 1.1
                let alpha = 0.15 + next() * 0.45
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(Moon.textSecondary.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct MoonBackground: View {
    var body: some View {
        ZStack {
            Moon.sky
            StarField()
        }
        .ignoresSafeArea()
    }
}

struct MoonPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Moon.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Moon.accentGradient)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            )
            .shadow(color: Moon.accent.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 2)
    }
}

struct MoonSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Moon.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Moon.card.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Moon.line))
    }
}

struct MoonCard<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Moon.cardHover : Moon.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Moon.accent : Moon.line, lineWidth: selected ? 1.5 : 1)
            )
    }
}

/// Das Moonvisor-Logo: Mondsichel mit Bildschirm.
struct MoonLogo: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Moon.accentGradient)
            Circle()
                .fill(Moon.deep)
                .frame(width: size * 0.78, height: size * 0.78)
                .offset(x: size * 0.2, y: -size * 0.14)
        }
        .frame(width: size, height: size)
        .shadow(color: Moon.accent.opacity(0.5), radius: size * 0.2)
    }
}

extension VMRunState {
    var color: Color {
        switch self {
        case .running: return Moon.mint
        case .paused: return Moon.gold
        case .stopped: return Moon.textMuted
        case .starting, .stopping: return Moon.accentLight
        }
    }
}

private struct PreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Beim Offscreen-Rendern (README-Bilder) zeichnet `ImageRenderer` keine ScrollViews.
    var isPreviewRendering: Bool {
        get { self[PreviewRenderingKey.self] }
        set { self[PreviewRenderingKey.self] = newValue }
    }
}

/// ScrollView, die beim Offscreen-Rendern als normaler Stapel gezeichnet wird.
struct MoonScroll<Content: View>: View {
    @Environment(\.isPreviewRendering) private var previewRendering
    @ViewBuilder var content: Content

    var body: some View {
        if previewRendering {
            VStack(spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
