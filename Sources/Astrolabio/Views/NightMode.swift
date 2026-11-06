import SwiftUI

/// Modo nocturno: convierte toda la interfaz (textos, controles, gráficas e imágenes) a tonos
/// rojos y tenues. La luz roja apenas afecta a la adaptación del ojo a la oscuridad.
struct NightModeModifier: ViewModifier {
    @ObservedObject var settings: AppSettings

    func body(content: Content) -> some View {
        if settings.nightModeActive {
            content
                .grayscale(1)
                .colorMultiply(Color(red: 1.0, green: 0.12, blue: 0.06))
                .brightness(-(1 - settings.nightBrightness) * 0.5)
        } else {
            content
        }
    }
}

/// Versión para vistas que reciben los ajustes por el entorno (hojas, paneles).
struct EnvironmentNightMode: ViewModifier {
    @EnvironmentObject var settings: AppSettings
    func body(content: Content) -> some View { content.modifier(NightModeModifier(settings: settings)) }
}

extension View {
    /// En la raíz de una ventana, donde los ajustes aún no están en el entorno.
    func nightMode(_ settings: AppSettings) -> some View { modifier(NightModeModifier(settings: settings)) }
    /// Dentro de la jerarquía (hojas), leyendo los ajustes del entorno.
    func nightMode() -> some View { modifier(EnvironmentNightMode()) }
}

/// Botón de la barra superior para encender y apagar el modo nocturno.
struct NightModeButton: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Button {
            settings.toggleNightMode()
        } label: {
            Image(systemName: settings.nightModeActive ? "eye.fill" : "eye")
                .font(.title3)
                .foregroundStyle(settings.nightModeActive ? Color.red : Theme.accentSoft)
                .frame(width: 34, height: 30)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.cardStroke))
        }
        .buttonStyle(.plain)
        .help(tr("Modo nocturno (⌃⌘N): todo en rojo tenue para no perder la adaptación a la oscuridad"))
    }
}
