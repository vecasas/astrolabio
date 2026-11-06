import SwiftUI

/// Ventana «Acerca de Astrolabio»: versión, autor, fecha de creación y contacto.
@MainActor
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [Theme.accentSoft, Theme.accent], startPoint: .top, endPoint: .bottom))
            Text(AppInfo.name).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(tr("Control del Seestar desde el Mac")).foregroundStyle(.secondary)
            Divider().overlay(Theme.cardStroke)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text(tr("Versión")).foregroundStyle(.secondary)
                    Text("\(AppInfo.bundleVersion) (\(AppInfo.build))").monospacedDigit()
                }
                GridRow {
                    Text(tr("Autor")).foregroundStyle(.secondary)
                    Text(AppInfo.author)
                }
                GridRow {
                    Text(tr("Creada el")).foregroundStyle(.secondary)
                    Text(AppInfo.created.formatted(.dateTime.day().month(.wide).year().locale(Loc.shared.locale)))
                }
                GridRow {
                    Text(tr("Contacto")).foregroundStyle(.secondary)
                    Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!)
                }
                GridRow {
                    Text(tr("Código fuente")).foregroundStyle(.secondary)
                    Link("github.com/vecasas/astrolabio", destination: URL(string: AppInfo.repository)!)
                }
            }
            .font(.callout)
            Divider().overlay(Theme.cardStroke)
            Text(tr("Datos: d3-celestial y catálogo HYG (estrellas), NASA LRO (Luna), DSS2 vía NASA SkyView (fotos), Open-Meteo (tiempo), Wikipedia (descripciones), CDS SIMBAD (búsqueda)."))
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Text(tr("Astrolabio es independiente y no está afiliado a ZWO."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.background)
    }
}

/// Entrada «Acerca de Astrolabio» del menú de la app.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(tr("Acerca de Astrolabio")) { openWindow(id: "about") }
    }
}

/// Botón ⓘ que abre la ventana «Acerca de».
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "about") } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Acerca de Astrolabio"))
    }
}
