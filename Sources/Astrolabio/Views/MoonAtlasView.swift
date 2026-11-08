import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Luna realista con los nombres de los accidentes en su sitio (con la libración del día). Norte arriba.
struct LabeledMoon: View {
    let date: Date
    var showLabels = true
    var pixelSize = 520
    /// Accidentes que se rotulan; por defecto, los mejores de esta noche y los mares iluminados.
    var features: [MoonFeature]? = nil

    var body: some View {
        let g = MoonFeatures.geometry(date)
        let list = features ?? MoonAtlas.defaultLabels(g)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2
            ZStack(alignment: .topLeading) {
                RealisticMoon(date: date, pixelSize: pixelSize).frame(width: side, height: side)
                if showLabels {
                    ForEach(list) { f in
                        let p = MoonFeatures.project(f, g)
                        if p.visible {
                            let x = r + p.x * (r - 1), y = r - p.y * (r - 1)
                            let isMare = f.kind == .mare
                            ZStack {
                                if !isMare { Circle().stroke(Color.yellow.opacity(0.9), lineWidth: 1).frame(width: 5, height: 5) }
                                Text(f.name)
                                    .font(.system(size: max(8, side / (isMare ? 30 : 34)), weight: isMare ? .regular : .semibold))
                                    .italic(isMare)
                                    .foregroundStyle(isMare ? Color.white.opacity(0.75) : Color.yellow)
                                    .shadow(color: .black, radius: 1.5)
                                    .fixedSize()
                                    .offset(x: 0, y: isMare ? 0 : -side / 34)
                            }
                            .position(x: x, y: y)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

enum MoonAtlas {
    static func defaultLabels(_ g: MoonGeometry) -> [MoonFeature] {
        let maria = MoonFeatures.all.filter { $0.kind == .mare && $0.sizeKm > 500 && MoonFeatures.light($0, g) != .dark && MoonFeatures.light($0, g) != .hidden }
        // Sin rótulos encima de otros: se quedan los mayores.
        var placed: [(Double, Double)] = []
        return (maria + MoonFeatures.bestNow(g, limit: 12)).filter { f in
            let p = MoonFeatures.project(f, g)
            guard !placed.contains(where: { abs($0.0 - p.x) < 0.22 && abs($0.1 - p.y) < 0.07 }) else { return false }
            placed.append((p.x, p.y))
            return true
        }
    }

    /// Imagen PNG de la Luna rotulada con fecha y lugar, para guardar o compartir.
    @MainActor
    static func snapshot(date: Date, place: String) -> Data? {
        // La imagen de la Luna se calcula aquí (la vista la calcula en segundo plano y aún no estaría).
        let g = MoonFeatures.geometry(date)
        guard let moon = MoonRenderer.render(size: 900, geometry: g) else { return nil }
        let view = ZStack(alignment: .topLeading) {
            Color.black
            VStack(spacing: 10) {
                ZStack {
                    Image(decorative: moon, scale: 1).resizable().frame(width: 900, height: 900)
                    LabeledMoonOverlay(geometry: g, features: defaultLabels(g)).frame(width: 900, height: 900)
                }
                Text("\(date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Loc.shared.locale)))  ·  \(place)")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.85))
                Text(tr("Norte arriba · %@ · Astrolabio", tr("Iluminada al %.0f %% · %.1f días", Astro.moon(date).illumination * 100, Astro.moonPhase(date).age)))
                    .font(.system(size: 17)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(30)
        }
        .frame(width: 960, height: 1040)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Solo los rótulos (para la imagen exportada, sobre la Luna ya dibujada).
struct LabeledMoonOverlay: View {
    let geometry: MoonGeometry
    let features: [MoonFeature]
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ForEach(features) { f in
                let p = MoonFeatures.project(f, geometry)
                if p.visible {
                    let isMare = f.kind == .mare
                    VStack(spacing: 2) {
                        Text(f.name).font(.system(size: isMare ? 26 : 22, weight: isMare ? .regular : .semibold)).italic(isMare)
                            .foregroundStyle(isMare ? Color.white.opacity(0.8) : Color.yellow).shadow(color: .black, radius: 2).fixedSize()
                        if !isMare { Circle().stroke(Color.yellow, lineWidth: 2).frame(width: 9, height: 9) }
                    }
                    .position(x: r + p.x * (r - 1), y: r - p.y * (r - 1) - (isMare ? 0 : 12))
                }
            }
        }
    }
}

/// Tarjeta con lo que se ve bien en la Luna esta noche y la lista completa.
struct MoonFeaturesCard: View {
    let date: Date
    @State private var filter: MoonFeature.Kind? = nil
    @State private var showAll = false

    var body: some View {
        let g = MoonFeatures.geometry(date)
        let best = MoonFeatures.bestNow(g, limit: 10)
        Card(title: tr("Qué mirar en la Luna"), systemImage: "scope") {
            Text(tr("Los relieves lucen más junto al terminador, la línea entre el día y la noche lunar: allí el Sol está bajo y las sombras son largas."))
                .font(.callout).foregroundStyle(.secondary)
            if best.isEmpty {
                Text(tr("Ahora no hay accidentes de la lista junto al terminador (Luna llena o nueva).")).font(.callout)
            } else {
                FlowRow(best.map(\.name))
            }
            HStack(spacing: 14) {
                Text(tr("Libración: %1$+.1f° en longitud, %2$+.1f° en latitud", g.l, g.b)).font(.caption).foregroundStyle(.secondary)
                Text(tr("Colongitud %.1f°", g.colongitude)).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showAll) {
                Picker(tr("Tipo"), selection: $filter) {
                    Text(tr("Todos")).tag(MoonFeature.Kind?.none)
                    ForEach(MoonFeature.Kind.allCases, id: \.self) { k in Text(k.name).tag(Optional(k)) }
                }
                .pickerStyle(.segmented).labelsHidden()
                ForEach(MoonFeatures.all.filter { filter == nil || $0.kind == filter }) { f in
                    let light = MoonFeatures.light(f, g)
                    HStack {
                        Text(f.name).frame(width: 170, alignment: .leading)
                        Text(f.kind.name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(String(format: "%.1f°%@ %.1f°%@", abs(f.lat), f.lat >= 0 ? "N" : "S", abs(f.lon), f.lon >= 0 ? "E" : "W"))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        if f.kind != .landing { Text(tr("%.0f km", f.sizeKm)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing) }
                        Spacer()
                        Pill(text: Self.lightName(light), color: Self.lightColor(light))
                    }
                    .font(.callout)
                }
            } label: {
                Text(tr("Los %d accidentes de la lista", MoonFeatures.all.count)).font(.callout)
            }
            Text(tr("El Seestar ve la Luna entera de una vez (su campo mide 44′ × 77′ y la Luna unos 31′), así que no hace falta apuntar a cada cráter: usa el modo Luna y amplía la imagen."))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    static func lightName(_ l: MoonFeatures.Light) -> String {
        switch l {
        case .terminator: return tr("Junto al terminador")
        case .lit: return tr("Iluminado")
        case .dark: return tr("De noche")
        case .hidden: return tr("Cara oculta")
        }
    }
    static func lightColor(_ l: MoonFeatures.Light) -> Color {
        switch l {
        case .terminator: return Theme.good
        case .lit: return Theme.accent
        case .dark, .hidden: return .secondary
        }
    }
}

/// Fila de etiquetas que salta de línea.
struct FlowRow: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { Pill(text: $0, color: Theme.good) }
        }
    }
}

enum ImageSaving {
    /// Pide dónde guardar un PNG y lo escribe.
    @MainActor
    static func savePNG(_ data: Data, name: String, folder: URL?) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = name
        p.directoryURL = folder
        guard p.runModal() == .OK, let url = p.url else { return nil }
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    @MainActor
    static func copy(_ data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}
