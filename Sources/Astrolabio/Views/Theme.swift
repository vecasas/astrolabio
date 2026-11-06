import SwiftUI

/// Paleta propia de Astrolabio: azules de cielo nocturno, pensados para usarse a oscuras.
enum Theme {
    static let accent = Color(red: 0.32, green: 0.63, blue: 1.00)
    static let accentSoft = Color(red: 0.55, green: 0.78, blue: 1.00)
    static let deep = Color(red: 0.020, green: 0.050, blue: 0.120)
    static let navy = Color(red: 0.050, green: 0.105, blue: 0.225)
    static let midnight = Color(red: 0.075, green: 0.150, blue: 0.300)
    static let card = Color(red: 0.085, green: 0.155, blue: 0.300).opacity(0.78)
    static let cardStroke = Color(red: 0.40, green: 0.60, blue: 1.00).opacity(0.22)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.75)
    static let warn = Color(red: 1.00, green: 0.72, blue: 0.35)
    static let bad = Color(red: 1.00, green: 0.45, blue: 0.45)

    static var background: LinearGradient {
        LinearGradient(colors: [deep, navy], startPoint: .top, endPoint: .bottom)
    }

    static var sidebar: LinearGradient {
        LinearGradient(colors: [Color(red: 0.035, green: 0.085, blue: 0.19), deep], startPoint: .top, endPoint: .bottom)
    }

    /// Color de una nota de 0 a 100.
    static func scoreColor(_ score: Double) -> Color {
        score > 50 ? good : (score > 25 ? accentSoft : .secondary)
    }
}

/// Fondo azul común para el área de contenido.
struct ThemedBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

extension View {
    func themedBackground() -> some View { modifier(ThemedBackground()) }
}

/// Etiqueta redondeada pequeña (nota, tipo de objeto, estado…).
struct Pill: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
        .foregroundStyle(color)
    }
}

/// Cifra destacada con su rótulo (para resúmenes y estadísticas).
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.accentSoft)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }
}
