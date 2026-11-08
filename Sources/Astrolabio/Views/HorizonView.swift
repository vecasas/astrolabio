import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor del horizonte propio: un panorama de 360° en el que se dibuja con el ratón la altura de
/// árboles, tejados y montes. Se guarda para el lugar de observación actual.
@MainActor
struct HorizonView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var draft: Horizon = .flat
    @State private var lastAz: Double?
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Mi horizonte en %@", settings.siteName)).font(.title3.bold())
                Text(tr("Dibuja con el ratón la altura de lo que tapa el cielo desde tu sitio: árboles, tejados, montes. Los objetos que queden detrás no se sugieren y la sesión automática los espera o los salta."))
                    .foregroundStyle(.secondary)
                Card(title: tr("Panorama"), systemImage: "mountain.2") {
                    editor.frame(height: 260)
                    HStack {
                        Text(tr("Pulsa y arrastra para dibujar. Mayúsculas + arrastrar borra (pone 0°)."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(tr("Altura máxima: %@°", "\(Int(draft.altitudes.max() ?? 0))")).font(.caption).monospacedDigit()
                    }
                }
                HStack {
                    Button(tr("Guardar")) { settings.horizon = draft; message = tr("Horizonte guardado para %@.", settings.siteName) }
                        .buttonStyle(.borderedProminent).disabled(draft == settings.horizon)
                    Button(tr("Deshacer cambios")) { draft = settings.horizon }.disabled(draft == settings.horizon)
                    Button(tr("Horizonte plano")) { draft = .flat }
                    Spacer()
                    Button(tr("Importar…")) { importFile() }
                    Button(tr("Exportar…")) { exportFile() }
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.accentSoft) }
                Text(tr("Formato del archivo: una línea por punto con «acimut altura» en grados (0 = norte, 90 = este). Sirve el de otros programas de astronomía con ese formato."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .onAppear { draft = settings.horizon }
        .onChange(of: AppSettings.siteKey(lat: settings.latitude, lon: settings.longitude)) { _, _ in draft = settings.horizon }
    }

    private var editor: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxAlt = Horizon.maxAltitude
            let x: (Double) -> CGFloat = { az in CGFloat(az / 360) * w }
            let y: (Double) -> CGFloat = { alt in h - CGFloat(alt / maxAlt) * h }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // Cielo y rejilla.
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .linearGradient(
                        Gradient(colors: [Theme.navy, Theme.midnight]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                    for alt in stride(from: 10.0, through: maxAlt, by: 10) {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: y(alt))); p.addLine(to: CGPoint(x: w, y: y(alt)))
                        ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                        ctx.draw(Text("\(Int(alt))°").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 16, y: y(alt) - 7))
                    }
                    for (az, name) in [(0.0, "N"), (45, "NE"), (90, "E"), (135, "SE"), (180, "S"), (225, "SO"), (270, "O"), (315, "NO"), (360, "N")] {
                        var p = Path(); p.move(to: CGPoint(x: x(az), y: 0)); p.addLine(to: CGPoint(x: x(az), y: h))
                        ctx.stroke(p, with: .color(.white.opacity(az.truncatingRemainder(dividingBy: 90) == 0 ? 0.18 : 0.07)), lineWidth: 0.5)
                        ctx.draw(Text(tr(name)).font(.caption.bold()).foregroundStyle(Theme.accentSoft), at: CGPoint(x: min(w - 10, max(10, x(az))), y: 10))
                    }
                    // Altura mínima de los ajustes.
                    var m = Path(); m.move(to: CGPoint(x: 0, y: y(settings.minAltitude))); m.addLine(to: CGPoint(x: w, y: y(settings.minAltitude)))
                    ctx.stroke(m, with: .color(Theme.warn.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // Silueta.
                    var top = Path()
                    for az in stride(from: 0.0, through: 360.0, by: 1) {
                        let pt = CGPoint(x: x(az), y: y(draft.altitude(atAzimuth: az)))
                        if az == 0 { top.move(to: pt) } else { top.addLine(to: pt) }
                    }
                    var fill = top
                    fill.addLine(to: CGPoint(x: w, y: h)); fill.addLine(to: CGPoint(x: 0, y: h)); fill.closeSubpath()
                    ctx.fill(fill, with: .color(Color(red: 0.06, green: 0.16, blue: 0.10)))
                    ctx.stroke(top, with: .color(.green.opacity(0.8)), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let az = max(0, min(359.99, Double(g.location.x / w) * 360))
                let alt = NSEvent.modifierFlags.contains(.shift) ? 0 : max(0, min(maxAlt, Double((h - g.location.y) / h) * maxAlt))
                // Rellena también los acimuts intermedios si el ratón va deprisa.
                let from = lastAz ?? az
                let lo = min(from, az), hi = max(from, az)
                var a = lo
                while a <= hi { draft.set(azimuth: a, altitude: alt); a += Horizon.step / 2 }
                draft.set(azimuth: az, altitude: alt)
                lastAz = az
            }.onEnded { _ in lastAz = nil })
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 1_000_000, let text = try? String(contentsOf: url, encoding: .utf8), let h = Horizon.parse(text) else {
            message = tr("No se pudo leer el horizonte de ese archivo.")
            return
        }
        draft = h
        message = tr("Horizonte importado. Pulsa «Guardar» para usarlo.")
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "horizonte_\(SafeName.fileComponent(settings.siteName)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ("# Horizonte de \(settings.siteName) (acimut altura, grados)\n" + draft.text() + "\n").write(to: url, atomically: true, encoding: .utf8)
            message = tr("Exportado a %@", url.lastPathComponent)
        } catch { message = error.localizedDescription }
    }
}
