import Foundation
import CoreGraphics
import ImageIO

/// Una noche de observación: todas las sesiones de apilado entre el mediodía y el mediodía siguiente.
struct NightSession: Identifiable, Hashable {
    let night: Date
    let records: [ObservationRecord]

    var id: Date { night }
    var start: Date { records.map(\.start).min() ?? night }
    var end: Date { records.map(\.end).max() ?? night }
    var frames: Int { records.reduce(0) { $0 + $1.frames } }
    var integrationMinutes: Double { records.reduce(0) { $0 + $1.integrationMinutes } }

    /// Objetos en el orden en que se observaron, sin repetir.
    var targets: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in records where seen.insert(r.target).inserted { out.append(r.target) }
        return out
    }

    var siteName: String? { records.compactMap(\.siteName).first }
    var latitude: Double? { records.compactMap(\.latitude).first }
    var longitude: Double? { records.compactMap(\.longitude).first }

    /// Agrupa el historial por noches, de la más reciente a la más antigua.
    static func group(_ records: [ObservationRecord]) -> [NightSession] {
        Dictionary(grouping: records, by: \.nightDate)
            .map { NightSession(night: $0.key, records: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.night > $1.night }
    }
}

enum ReportFormat {
    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? tr("%d h %02d min", m / 60, m % 60) : tr("%d min", m)
    }

    static func date(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Loc.shared.locale))
    }

    static func time(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Loc.shared.locale))
    }

    static func number(_ x: Double, _ digits: Int = 0) -> String {
        x.formatted(.number.precision(.fractionLength(digits)).locale(Loc.shared.locale))
    }

    static func yesNo(_ b: Bool) -> String { b ? tr("Sí") : tr("No") }
}

/// Contenido de un informe, ya traducido; lo usan tanto la vista como el PDF.
struct ReportDocument {
    struct Row: Hashable {
        let label: String
        let value: String
    }

    struct ObjectBlock {
        let title: String
        let subtitle: String
        let rows: [Row]
        let image: CGImage?
    }

    var title: String
    var subtitle: String
    var summary: [Row]
    var conditions: [Row]
    var objects: [ObjectBlock]
    var events: [String]
    var device: [Row]
    var footer: String

    /// Construye el informe de una noche.
    /// - Parameters:
    ///   - weather: horas de tiempo descargadas (si no se guardó al observar).
    ///   - images: imágenes del apilado por id de registro.
    ///   - site: lugar configurado, para los registros que no lo guardaron.
    static func make(_ session: NightSession, weather: [WeatherHour] = [], images: [UUID: CGImage] = [:],
                     site: (name: String, lat: Double, lon: Double)? = nil, generated: Date = Date()) -> ReportDocument {
        typealias R = Row
        let lat = session.latitude ?? site?.lat
        let lon = session.longitude ?? site?.lon
        let mid = session.start.addingTimeInterval(session.end.timeIntervalSince(session.start) / 2)

        var summary: [R] = [
            R(label: tr("Fecha"), value: ReportFormat.date(session.night)),
            R(label: tr("Horario"), value: "\(ReportFormat.time(session.start)) – \(ReportFormat.time(session.end))"),
            R(label: tr("Objetos"), value: session.targets.joined(separator: ", ")),
            R(label: tr("Integración total"), value: ReportFormat.duration(session.integrationMinutes)),
            R(label: tr("Fotogramas apilados"), value: "\(session.frames)"),
        ]
        if let name = session.siteName ?? site?.name { summary.append(R(label: tr("Lugar"), value: name)) }
        if let lat, let lon {
            summary.append(R(label: tr("Coordenadas del lugar"),
                             value: String(format: "%.4f°, %.4f°", locale: Locale(identifier: "en_US_POSIX"), lat, lon)))
        }

        // Condiciones: el tiempo guardado al empezar o, si no hay, el histórico descargado.
        var conditions: [R] = []
        let snap = session.records.compactMap(\.weather).first
            ?? WeatherService.nearest(mid, in: weather).map {
                WeatherSnapshot(cloudCover: $0.cloudCover, temperature: $0.temperature, dewPoint: $0.dewPoint,
                                humidity: $0.humidity, wind: $0.wind)
            }
        if let w = snap {
            conditions += [
                R(label: tr("Nubes"), value: "\(ReportFormat.number(w.cloudCover)) %"),
                R(label: tr("Temperatura"), value: "\(ReportFormat.number(w.temperature, 1)) °C"),
                R(label: tr("Punto de rocío"), value: "\(ReportFormat.number(w.dewPoint, 1)) °C"),
                R(label: tr("Humedad"), value: "\(ReportFormat.number(w.humidity)) %"),
                R(label: tr("Viento"), value: "\(ReportFormat.number(w.wind)) km/h"),
            ]
        } else {
            conditions.append(R(label: tr("Tiempo"), value: tr("Sin datos")))
        }
        let phase = Astro.moonPhase(mid)
        conditions.append(R(label: tr("Fase lunar"), value: phase.name))
        conditions.append(R(label: tr("Iluminación de la Luna"), value: "\(ReportFormat.number(Astro.moon(mid).illumination * 100)) %"))
        if let lat, let lon {
            let alt = Ephemeris.moonAltitude(lat: lat, lon: lon)(mid)
            conditions.append(R(label: tr("Altura de la Luna"),
                                value: alt < 0 ? tr("Bajo el horizonte") : "\(ReportFormat.number(alt))°"))
        }

        // Objetos.
        let objects = session.records.map { r -> ObjectBlock in
            var rows: [R] = []
            let obj = Catalog.find(r.target)
            if let co = r.coordinates {
                rows.append(R(label: tr("AR / Dec"), value: "\(Astro.formatRA(co.ra))  \(Astro.formatDec(co.dec))"))
            }
            rows.append(R(label: tr("Inicio / fin"), value: "\(ReportFormat.time(r.start)) – \(ReportFormat.time(r.end))"))
            rows.append(R(label: tr("Exposición"), value: tr("%@ s", ReportFormat.number(Double(r.exposureMs) / 1000, r.exposureMs % 1000 == 0 ? 0 : 1))))
            if let g = r.gain { rows.append(R(label: tr("Ganancia"), value: "\(g)")) }
            if let lp = r.lpFilter { rows.append(R(label: tr("Filtro LP"), value: ReportFormat.yesNo(lp))) }
            var framesText = "\(r.frames)"
            if let d = r.dropped { framesText += "  " + tr("(%d descartados)", d) }
            rows.append(R(label: tr("Fotogramas apilados"), value: framesText))
            rows.append(R(label: tr("Integración"), value: ReportFormat.duration(r.integrationMinutes)))
            if let en = r.ditherEnabled {
                rows.append(R(label: tr("Dither"), value: en ? tr("Sí, %d px cada %d fotogramas", r.ditherPixels ?? 0, r.ditherInterval ?? 0) : tr("No")))
            }
            if let f = r.focusPosition { rows.append(R(label: tr("Posición del enfoque"), value: "\(f)")) }
            var a1 = r.altitudeStart, a2 = r.altitudeEnd
            if a1 == nil || a2 == nil, let co = r.coordinates, let lat, let lon {
                let f = Ephemeris.altitudeOfFixed(raJ2000: co.ra, decJ2000: co.dec, lat: lat, lon: lon)
                a1 = a1 ?? f(r.start); a2 = a2 ?? f(r.end)
            }
            if let a1, let a2 { rows.append(R(label: tr("Altura inicio / fin"), value: "\(ReportFormat.number(a1))° / \(ReportFormat.number(a2))°")) }
            if r.imported == true { rows.append(R(label: tr("Origen"), value: tr("Importado del álbum del Seestar"))) }
            let subtitle = [obj?.kind.label, obj.flatMap { $0.localizedName == r.target ? nil : $0.localizedName }]
                .compactMap { $0 }.joined(separator: " · ")
            return ObjectBlock(title: r.target, subtitle: subtitle, rows: rows, image: images[r.id])
        }

        // Eventos y errores del registro.
        let events = session.records.flatMap { $0.events ?? [] }

        // Telescopio.
        var device: [R] = []
        if let d = session.records.compactMap(\.device).first { device.append(R(label: tr("Telescopio"), value: d)) }
        if let f = session.records.compactMap(\.firmware).first { device.append(R(label: tr("Firmware"), value: f)) }
        let b1 = session.records.compactMap(\.batteryStart).first, b2 = session.records.compactMap(\.batteryEnd).last
        if let b1, let b2 { device.append(R(label: tr("Batería inicio / fin"), value: "\(b1) % / \(b2) %")) }
        let temps = session.records.compactMap(\.temperature)
        if let t = temps.first { device.append(R(label: tr("Temperatura del telescopio"), value: "\(ReportFormat.number(t, 1)) °C")) }

        let footer = tr("Generado con %@ %@ el %@", AppInfo.name, AppInfo.version,
                        generated.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Loc.shared.locale)))
        return ReportDocument(title: tr("Informe de sesión"), subtitle: ReportFormat.date(session.night),
                              summary: summary, conditions: conditions, objects: objects, events: events,
                              device: device, footer: footer)
    }
}

extension CGImage {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func load(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
