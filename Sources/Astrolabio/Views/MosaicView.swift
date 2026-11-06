import SwiftUI

@MainActor
struct MosaicView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plan: PlanStore

    @State private var query = tr("NGC 7000")
    @State private var name = tr("NGC 7000")
    @State private var ra = 20.988
    @State private var dec = 44.52
    @State private var sizeArcmin = 120.0
    @State private var columns = 2
    @State private var rows = 2
    @State private var overlap = 15.0
    @State private var minutes = 120.0
    @State private var lp = true
    @State private var message = ""

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Form {
                SwiftUI.Section(tr("Objeto")) {
                    HStack {
                        TextField(tr("Buscar"), text: $query).onSubmit(lookup)
                        Button(tr("Buscar"), action: lookup)
                    }
                    TextField(tr("Nombre"), text: $name)
                    LabeledContent(tr("AR"), value: Astro.formatRA(ra))
                    LabeledContent(tr("Dec"), value: Astro.formatDec(dec))
                    Stepper(tr("Tamaño del objeto: %@′", "\(Int(sizeArcmin))"), value: $sizeArcmin, in: 5...300, step: 5)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                SwiftUI.Section(tr("Mosaico")) {
                    Stepper(tr("Columnas: %@", "\(columns)"), value: $columns, in: 1...3)
                    Stepper(tr("Filas: %@", "\(rows)"), value: $rows, in: 1...3)
                    Stepper(tr("Solape: %@ %%", "\(Int(overlap))"), value: $overlap, in: 5...40, step: 5)
                    Stepper(tr("Tiempo total: %@ min", "\(Int(minutes))"), value: $minutes, in: 20...600, step: 10)
                    Text(tr("Unos %@ min por panel.", "\(Int(minutes / Double(columns * rows)))")).font(.caption).foregroundStyle(.secondary)
                    Toggle(tr("Filtro antipolución (LP)"), isOn: $lp)
                    Button(tr("Ajustar al tamaño del objeto")) {
                        if case .mosaic(let c, let r) = Planner.frameFit(sizeArcmin, fov: (settings.fovWidthDeg, settings.fovHeightDeg)) {
                            columns = c; rows = r
                        } else { columns = 1; rows = 1 }
                    }
                }
                Button(tr("Añadir al plan")) {
                    var item = PlanItem(name: name, raHours: ra, decDeg: dec, minutes: minutes)
                    item.mosaicColumns = columns
                    item.mosaicRows = rows
                    item.overlapPercent = overlap
                    item.lpFilter = lp
                    plan.items.append(item)
                    message = tr("Añadido al plan. Ve a «Sesión automática» para ejecutarlo.")
                }
                .buttonStyle(.borderedProminent)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 360)

            VStack(alignment: .leading) {
                Text(tr("Vista previa del encuadre")).font(.headline)
                MosaicPreview(raHours: ra, decDeg: dec, columns: columns, rows: rows, overlap: overlap, sizeArcmin: sizeArcmin,
                              fov: (settings.fovWidthDeg, settings.fovHeightDeg))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(tr("Foto real de la zona (DSS2, NASA SkyView) con el norte arriba y el este a la izquierda. Cada rectángulo amarillo es un panel del Seestar, numerado columna-fila; el círculo discontinuo marca el tamaño aproximado del objeto."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .navigationTitle(tr("Mosaicos"))
    }

    private func lookup() {
        if let obj = Catalog.find(query) {
            name = obj.id; ra = obj.raHours; dec = obj.decDeg; sizeArcmin = obj.sizeArcmin
            lp = [.nebula, .snr, .planetary].contains(obj.kind)
            message = obj.displayName
            return
        }
        let q = query
        message = tr("Buscando en SIMBAD…")
        Task {
            if let r = try? await NameResolver.resolve(q) {
                name = q; ra = r.ra; dec = r.dec
                message = tr("Encontrado en SIMBAD (indica el tamaño a mano si hace falta).")
            } else {
                message = tr("No se encontró %@.", "\(q)")
            }
        }
    }
}

@MainActor
struct MosaicPreview: View {
    let raHours: Double
    let decDeg: Double
    let columns: Int
    let rows: Int
    let overlap: Double
    let sizeArcmin: Double
    let fov: (Double, Double)

    /// Lado (en grados) de la zona cuadrada que se muestra: el mosaico o el objeto, con margen.
    private var span: Double {
        let stepW = fov.0 * (1 - overlap / 100), stepH = fov.1 * (1 - overlap / 100)
        let totalW = stepW * Double(columns - 1) + fov.0
        let totalH = stepH * Double(rows - 1) + fov.1
        return min(6, max(totalW, totalH, sizeArcmin / 60) * 1.15)
    }

    var body: some View {
        let span = self.span
        ZStack {
            Color.black
            if let url = SkyImage.url(raHours: raHours, decDeg: decDeg, width: span, height: span, pixelWidth: 600) {
                StretchedSkyImage(url: url)
            }
            Canvas { ctx, size in
                let stepW = fov.0 * (1 - overlap / 100), stepH = fov.1 * (1 - overlap / 100)
                let scale = min(size.width, size.height) / span
                let cx = size.width / 2, cy = size.height / 2
                let r = sizeArcmin / 60 / 2 * scale
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                           with: .color(Theme.accentSoft.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                for row in 0..<rows {
                    for col in 0..<columns {
                        // La columna 1 es la de menor AR (oeste), que en el cielo queda a la derecha.
                        let x = -(Double(col) - Double(columns - 1) / 2) * stepW
                        let y = (Double(row) - Double(rows - 1) / 2) * stepH
                        let rect = CGRect(x: cx + (x - fov.0 / 2) * scale, y: cy - (y + fov.1 / 2) * scale,
                                          width: fov.0 * scale, height: fov.1 * scale)
                        ctx.fill(Path(rect), with: .color(.yellow.opacity(0.06)))
                        ctx.stroke(Path(rect), with: .color(.yellow), lineWidth: 1.5)
                        ctx.draw(Text("\(col + 1)\(row + 1)").font(.headline).foregroundColor(.yellow),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
                ctx.draw(Text("N").font(.caption.bold()).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: cx, y: 12))
                ctx.draw(Text("E").font(.caption.bold()).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: 12, y: cy))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
        .id("\(raHours)|\(decDeg)|\(span)")
    }
}
