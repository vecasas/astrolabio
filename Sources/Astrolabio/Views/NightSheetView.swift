import SwiftUI
import AppKit

/// Datos de la hoja de la noche (se calculan una vez y se dibujan en pantalla y en la imagen).
struct NightSheetData {
    struct Planet { let name: String; let rise: Date?; let set: Date?; let best: Date?; let maxAlt: Double; let mag: Double? }
    struct Target { let name: String; let best: Date?; let maxAlt: Double; let window: String }
    struct Comet { let name: String; let mag: Double; let best: Date?; let maxAlt: Double }

    let date: Date
    let place: String
    let night: Astro.Night
    let moonIllum: Double
    let moonPhase: String
    let moonRise: Date?
    let moonSet: Date?
    let planets: [Planet]
    let targets: [Target]
    let comets: [Comet]
    let events: [SkyEvent]
    let passes: [SatellitePass]

    @MainActor
    static func make(settings: AppSettings, tonight: TonightModel, comets: [CometOrbit], passes: [SatellitePass],
                     date: Date = Date()) -> NightSheetData {
        let lat = settings.latitude, lon = settings.longitude
        let n = tonight.night ?? Astro.night(for: date, lat: lat, lon: lon)
        let start = n.sunset ?? date, end = n.sunrise ?? start.addingTimeInterval(12 * 3600)
        let hours = max(1, end.timeIntervalSince(start) / 3600)
        let moonRS = Ephemeris.riseSet(from: start.addingTimeInterval(-6 * 3600), hours: hours + 12, step: 300, h0: 0.125,
                                       altitude: Ephemeris.moonAltitude(lat: lat, lon: lon))
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let planets: [Planet] = Astro.planetNames.compactMap { name in
            let rs = Ephemeris.riseSet(from: start, hours: hours, step: 600, h0: 0, altitude: Ephemeris.planetAltitude(name, lat: lat, lon: lon))
            guard !rs.neverUp, rs.maxAltitude > 10 else { return nil }
            return Planet(name: tr(name), rise: rs.rise, set: rs.set, best: rs.transit, maxAlt: rs.maxAltitude,
                          mag: Ephemeris.magnitude(name, date: mid))
        }
        let targets = tonight.forecasts.prefix(8).map { f in
            Target(name: f.object.displayName, best: f.bestTime, maxAlt: f.maxAltitude,
                   window: [f.windowStart, f.windowEnd].compactMap { $0?.shortTime }.joined(separator: "–"))
        }
        let cs = Comets.visible(comets, night: n, lat: lat, lon: lon, minAltitude: settings.minAltitude, maxMagnitude: 11)
            .prefix(4).map { Comet(name: $0.orbit.name, mag: $0.position.magnitude, best: $0.best, maxAlt: $0.maxAltitude) }
        let events = SkyEvents.upcoming(from: start, days: 7, lat: lat, lon: lon).prefix(6).map { $0 }
        let tonightPasses = passes.filter { $0.rise >= start && $0.rise <= end }.prefix(6).map { $0 }
        return NightSheetData(date: date, place: String(format: "%.2f°, %.2f°", lat, lon), night: n,
                              moonIllum: Astro.moon(mid).illumination, moonPhase: Astro.moonPhase(mid).name,
                              moonRise: moonRS.rise, moonSet: moonRS.set, planets: planets, targets: Array(targets),
                              comets: Array(cs), events: events, passes: tonightPasses)
    }
}

/// La hoja: una imagen de una página con todo lo de la noche.
struct NightSheet: View {
    let data: NightSheetData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Hoja de la noche")).font(.system(size: 34, weight: .bold, design: .rounded))
                Spacer()
                Text(data.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Loc.shared.locale)))
                    .font(.system(size: 20))
            }
            Text(tr("Lugar: %@", data.place)).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))

            HStack(alignment: .top, spacing: 16) {
                box(tr("Oscuridad"), "moon.stars") {
                    row(tr("Puesta de sol"), data.night.sunset?.shortTime)
                    row(tr("Noche cerrada"), data.night.duskStart?.shortTime)
                    row(tr("Fin de la noche"), data.night.dawnEnd?.shortTime)
                    row(tr("Salida del sol"), data.night.sunrise?.shortTime)
                }
                box(tr("Luna"), "moonphase.waxing.gibbous") {
                    HStack(spacing: 12) {
                        RealisticMoonStatic(date: data.date).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(data.moonPhase).font(.system(size: 16, weight: .semibold))
                            Text(tr("Iluminada al %.0f %%", data.moonIllum * 100)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    row(tr("Sale"), data.moonRise?.shortTime)
                    row(tr("Se pone"), data.moonSet?.shortTime)
                }
                box(tr("Planetas"), "globe.europe.africa") {
                    if data.planets.isEmpty { Text(tr("Ninguno alto esta noche.")).foregroundStyle(.white.opacity(0.6)) }
                    ForEach(data.planets, id: \.name) { p in
                        HStack {
                            Text(p.name).frame(width: 80, alignment: .leading)
                            Text(Self.span(p.rise, p.set)).monospacedDigit()
                            Spacer()
                            Text(String(format: "%.0f°", p.maxAlt)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                        }.font(.system(size: 14))
                    }
                }
            }

            box(tr("Los mejores objetos para el Seestar"), "sparkles") {
                if data.targets.isEmpty { Text(tr("Abre «Qué mirar» para calcular la lista.")).foregroundStyle(.white.opacity(0.6)) }
                ForEach(Array(data.targets.enumerated()), id: \.offset) { i, t in
                    HStack {
                        Text("\(i + 1).").monospacedDigit().frame(width: 26, alignment: .trailing).foregroundStyle(.white.opacity(0.6))
                        Text(t.name).lineLimit(1)
                        Spacer()
                        Text(t.window).monospacedDigit().foregroundStyle(.white.opacity(0.75)).frame(width: 130, alignment: .trailing)
                        Text(tr("máx. %.0f°", t.maxAlt)).monospacedDigit().foregroundStyle(.white.opacity(0.75)).frame(width: 80, alignment: .trailing)
                    }.font(.system(size: 15))
                }
            }

            HStack(alignment: .top, spacing: 16) {
                box(tr("Estación Espacial y satélites"), "airplane") {
                    if data.passes.isEmpty { Text(tr("Sin pasos visibles esta noche.")).foregroundStyle(.white.opacity(0.6)) }
                    ForEach(data.passes) { p in
                        HStack {
                            Text(p.name).lineLimit(1).frame(width: 150, alignment: .leading)
                            Text(p.rise.shortTime).monospacedDigit()
                            Text(tr("%1$@ → %2$@", Compass.name(p.riseAzimuth), Compass.name(p.setAzimuth)))
                            Spacer()
                            Text(String(format: "%.0f°", p.maxAltitude)).monospacedDigit()
                        }.font(.system(size: 14))
                    }
                }
                box(tr("Cometas"), "light.beacon.max") {
                    if data.comets.isEmpty { Text(tr("Ninguno al alcance esta noche.")).foregroundStyle(.white.opacity(0.6)) }
                    ForEach(data.comets, id: \.name) { c in
                        HStack {
                            Text(c.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "mag %.1f", c.mag)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                        }.font(.system(size: 14))
                    }
                }
            }

            box(tr("Esta semana en el cielo"), "calendar") {
                if data.events.isEmpty { Text(tr("Nada destacado.")).foregroundStyle(.white.opacity(0.6)) }
                ForEach(data.events) { e in
                    HStack {
                        Image(systemName: e.kind.symbol).frame(width: 20)
                        Text(e.title)
                        Spacer()
                        Text(e.date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(Loc.shared.locale))).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }.font(.system(size: 14))
                }
            }
            Text(tr("Hecho con Astrolabio para el Seestar S50 · horas locales")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(30)
        .frame(width: 1000, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Theme.deep, Theme.navy], startPoint: .top, endPoint: .bottom))
    }

    private func box<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accentSoft)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }

    /// «18:55–4:07», «desde 6:02» o «hasta 4:40» (si ya estaba arriba o sigue al amanecer).
    static func span(_ rise: Date?, _ set: Date?) -> String {
        switch (rise, set) {
        case let (r?, s?): return "\(r.shortTime)–\(s.shortTime)"
        case let (r?, nil): return tr("desde %@", r.shortTime)
        case let (nil, s?): return tr("hasta %@", s.shortTime)
        default: return tr("toda la noche")
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack { Text(label).foregroundStyle(.white.opacity(0.7)); Spacer(); Text(value ?? "—").monospacedDigit() }.font(.system(size: 14))
    }
}

/// Luna dibujada de forma síncrona (para la imagen exportada, que no espera a tareas en segundo plano).
struct RealisticMoonStatic: View {
    let date: Date
    var body: some View {
        if let img = MoonRenderer.render(size: 160, geometry: MoonFeatures.geometry(date)) {
            Image(decorative: img, scale: 1).resizable()
        } else { Circle().fill(Color(white: 0.2)) }
    }
}

@MainActor
struct NightSheetView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tonight: TonightModel
    @ObservedObject private var comets = CometStore.shared
    @ObservedObject private var sats = SatelliteStore.shared
    @ObservedObject private var passes = SatellitePassModel.shared
    @State private var message = ""

    @State private var image: NSImage?

    var body: some View {
        let data = NightSheetData.make(settings: settings, tonight: tonight, comets: comets.orbits, passes: passes.passes)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tr("Un resumen de la noche en una imagen, para guardarla, copiarla o imprimirla.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Guardar imagen")) { save(data) }
                    Button(tr("Copiar")) {
                        if let png = Self.png(data) { ImageSaving.copy(png); message = tr("Copiada al portapapeles") }
                    }
                    Button(tr("Imprimir")) { printSheet(data) }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                // Se muestra la misma imagen que se guarda, ajustada al ancho de la ventana.
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1000).clipShape(RoundedRectangle(cornerRadius: 14))
                } else { ProgressView() }
            }
            .padding(20)
        }
        .onAppear { redraw() }
        .onChange(of: passes.passes) { _, _ in redraw() }
        .onChange(of: comets.orbits.count) { _, _ in redraw() }
        .onChange(of: tonight.forecasts.count) { _, _ in redraw() }
        .navigationTitle(tr("Hoja de la noche"))
        .task {
            await sats.refreshIfNeeded()
            await passes.update(tles: sats.tles, lat: settings.latitude, lon: settings.longitude)
            if comets.orbits.isEmpty { await comets.refreshIfNeeded() }
        }
    }

    private func redraw() {
        let data = NightSheetData.make(settings: settings, tonight: tonight, comets: comets.orbits, passes: passes.passes)
        image = Self.png(data).flatMap { NSImage(data: $0) }
    }

    static func png(_ data: NightSheetData) -> Data? {
        let r = ImageRenderer(content: NightSheet(data: data))
        r.scale = 2
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func save(_ data: NightSheetData) {
        guard let png = Self.png(data) else { message = tr("No se pudo crear la imagen."); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if let url = ImageSaving.savePNG(png, name: "Hoja_de_la_noche_\(f.string(from: data.date)).png", folder: settings.saveFolderURL) {
            message = tr("Guardada en %@", url.lastPathComponent)
        }
    }

    private func printSheet(_ data: NightSheetData) {
        guard let png = Self.png(data), let img = NSImage(data: png) else { return }
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: img.size.width / 2, height: img.size.height / 2))
        img.size = view.frame.size
        view.image = img
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        NSPrintOperation(view: view, printInfo: info).run()
    }
}
