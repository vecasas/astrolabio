import Foundation

/// Acontecimiento del cielo en las próximas semanas.
struct SkyEvent: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case meteors, conjunction, pair, phase, opposition, elongation, comet
        var symbol: String {
            switch self {
            case .meteors: return "sparkles"
            case .conjunction: return "moon.circle"
            case .pair: return "circle.grid.2x1"
            case .phase: return "moonphase.full.moon"
            case .opposition: return "sun.max.trianglebadge.exclamationmark"
            case .elongation: return "arrow.left.and.right"
            case .comet: return "light.beacon.max"
            }
        }
    }
    /// Etiquetas pensadas para el Seestar.
    enum Tag: String, CaseIterable {
        case fitsField, nakedEye, darkSky, moonBright, twilight, lowSky
        var name: String {
            switch self {
            case .fitsField: return tr("Cabe en el campo del Seestar")
            case .nakedEye: return tr("A simple vista")
            case .darkSky: return tr("Sin Luna")
            case .moonBright: return tr("Luna brillante")
            case .twilight: return tr("En el crepúsculo")
            case .lowSky: return tr("Bajo en el cielo")
            }
        }
        var good: Bool { self == .fitsField || self == .nakedEye || self == .darkSky }
    }
    var id: String { "\(kind.rawValue)|\(title)|\(Int(date.timeIntervalSince1970 / 3600))" }
    let kind: Kind
    let date: Date
    let title: String
    let detail: String
    let tags: [Tag]
}

enum SkyEvents {
    /// Lluvias de estrellas principales: día y mes del máximo, tasa horaria cenital y radiante.
    static let showers: [(name: String, month: Int, day: Int, zhr: Int, radiant: String)] = [
        ("Cuadrántidas", 1, 4, 110, "Bootes"),
        ("Líridas", 4, 22, 18, "Lyra"),
        ("Eta Acuáridas", 5, 6, 50, "Aquarius"),
        ("Delta Acuáridas", 7, 30, 25, "Aquarius"),
        ("Perseidas", 8, 12, 100, "Perseus"),
        ("Dracónidas", 10, 8, 10, "Draco"),
        ("Oriónidas", 10, 21, 20, "Orion"),
        ("Táuridas", 11, 5, 5, "Taurus"),
        ("Leónidas", 11, 17, 15, "Leo"),
        ("Gemínidas", 12, 14, 150, "Gemini"),
        ("Úrsidas", 12, 22, 10, "Ursa Minor"),
    ]

    static let fieldDegrees = 1.29

    /// Todo lo que pasa entre `start` y `start + days`, ordenado por fecha.
    static func upcoming(from start: Date = Date(), days: Int = 42, lat: Double, lon: Double,
                         comets: [CometOrbit] = []) -> [SkyEvent] {
        let end = start.addingTimeInterval(Double(days) * 86400)
        var out: [SkyEvent] = []
        out += meteorShowers(from: start, to: end, lat: lat, lon: lon)
        out += phases(from: start, to: end)
        out += moonConjunctions(from: start, to: end, lat: lat, lon: lon)
        out += planetPairs(from: start, to: end, lat: lat, lon: lon)
        out += planetMilestones(from: start, to: end)
        out += brightComets(comets, from: start, to: end, lat: lat, lon: lon)
        return out.sorted { $0.date < $1.date }
    }

    // MARK: Lluvias de estrellas

    static func meteorShowers(from start: Date, to end: Date, lat: Double = 40, lon: Double = 0) -> [SkyEvent] {
        let cal = Calendar(identifier: .gregorian)
        var out: [SkyEvent] = []
        let y0 = cal.component(.year, from: start)
        for year in [y0, y0 + 1] {
            for s in showers {
                var c = DateComponents(); c.year = year; c.month = s.month; c.day = s.day; c.hour = 2
                guard let d = cal.date(from: c), d >= start.addingTimeInterval(-86400), d <= end else { continue }
                // La Luna solo molesta si está brillante y sobre el horizonte en la madrugada del máximo.
                let m = Astro.moon(d)
                let moonUp = Astro.altAz(raHours: m.ra, decDeg: m.dec, date: d, lat: lat, lon: lon).alt > 0
                var tags: [SkyEvent.Tag] = [.nakedEye]
                tags.append(m.illumination >= 0.35 && moonUp ? .moonBright : .darkSky)
                out.append(SkyEvent(kind: .meteors, date: d, title: tr(s.name),
                                    detail: tr("Máximo de unos %d meteoros por hora con cielo ideal; radiante en %@. Mejor de madrugada, a simple vista o con una cámara de gran angular: el Seestar tiene un campo demasiado pequeño.", s.zhr, s.radiant),
                                    tags: tags))
            }
        }
        return out
    }

    // MARK: Fases

    static func phases(from start: Date, to end: Date) -> [SkyEvent] {
        Ephemeris.nextPhases(after: start, count: 8).filter { $0.date <= end }.map { p in
            let tags: [SkyEvent.Tag] = p.kind == .new ? [.darkSky] : (p.kind == .full ? [.moonBright] : [])
            let detail: String
            switch p.kind {
            case .new: detail = tr("Las noches más oscuras del mes: lo mejor para galaxias y nebulosas débiles.")
            case .full: detail = tr("La Luna ilumina todo el cielo: buena noche para la Luna, los planetas y las estrellas dobles.")
            default: detail = tr("Con la Luna a medias el terminador muestra el relieve: buen momento para fotografiarla.")
            }
            return SkyEvent(kind: .phase, date: p.date, title: p.kind.name, detail: detail, tags: tags)
        }
    }

    // MARK: Conjunciones

    /// Mínimos locales de una función muestreada en `step` segundos, por debajo de `limit`.
    static func minima(from start: Date, to end: Date, step: TimeInterval, limit: Double,
                       _ f: (Date) -> Double) -> [(date: Date, value: Double)] {
        var out: [(Date, Double)] = []
        var t = start
        var a = f(t), b = f(t.addingTimeInterval(step))
        while t.addingTimeInterval(2 * step) <= end {
            let c = f(t.addingTimeInterval(2 * step))
            if b <= a && b < c && b < limit {
                // Afina con una parábola por los tres puntos.
                let denom = a - 2 * b + c
                let off = denom > 0 ? 0.5 * (a - c) / denom : 0
                out.append((t.addingTimeInterval(step * (1 + max(-1, min(1, off)))), b - 0.25 * (a - c) * off))
            }
            a = b; b = c
            t = t.addingTimeInterval(step)
        }
        return out.map { (date: $0.0, value: max(0, $0.1)) }
    }

    /// Mejor altura del par a oscuras (Sol < −6°) en la noche de `date`.
    static func bestDarkAltitude(raHours: Double, decDeg: Double, near date: Date, lat: Double, lon: Double) -> Double {
        var best = -90.0
        var t = date.addingTimeInterval(-10 * 3600)
        while t <= date.addingTimeInterval(10 * 3600) {
            if Astro.sunAltitude(t, lat: lat, lon: lon) < -6 {
                best = max(best, Astro.altAz(raHours: raHours, decDeg: decDeg, date: t, lat: lat, lon: lon).alt)
            }
            t = t.addingTimeInterval(1800)
        }
        return best
    }

    static func moonConjunctions(from start: Date, to end: Date, lat: Double, lon: Double) -> [SkyEvent] {
        var out: [SkyEvent] = []
        for name in Astro.planetNames where name != "Neptuno" {
            let sep: (Date) -> Double = { d in
                guard let p = Astro.planet(name, date: d) else { return 180 }
                let m = Astro.moon(d)
                return Astro.separation(ra1: p.ra, dec1: p.dec, ra2: m.ra, dec2: m.dec)
            }
            for m in minima(from: start, to: end, step: 3600, limit: 5, sep) {
                guard let p = Astro.planet(name, date: m.date), let g = Ephemeris.phaseGeometry(name, date: m.date) else { continue }
                if g.elongation < 12 { continue }                   // pegado al Sol: no se ve
                let alt = bestDarkAltitude(raHours: p.ra, decDeg: p.dec, near: m.date, lat: lat, lon: lon)
                var tags: [SkyEvent.Tag] = [.nakedEye]
                if m.value < fieldDegrees * 0.8 { tags.insert(.fitsField, at: 0) }
                if g.elongation < 30 { tags.append(.twilight) }
                if alt < 15 { tags.append(.lowSky) }
                out.append(SkyEvent(kind: .conjunction, date: m.date, title: tr("La Luna y %@", tr(name)),
                                    detail: tr("Separación mínima de %.1f°.", m.value), tags: tags))
            }
        }
        return out
    }

    static func planetPairs(from start: Date, to end: Date, lat: Double, lon: Double) -> [SkyEvent] {
        var out: [SkyEvent] = []
        let names = Astro.planetNames
        for i in 0..<names.count { for j in (i + 1)..<names.count {
            let a = names[i], b = names[j]
            let sep: (Date) -> Double = { d in
                guard let p = Astro.planet(a, date: d), let q = Astro.planet(b, date: d) else { return 180 }
                return Astro.separation(ra1: p.ra, dec1: p.dec, ra2: q.ra, dec2: q.dec)
            }
            for m in minima(from: start, to: end, step: 6 * 3600, limit: 3, sep) {
                guard let p = Astro.planet(a, date: m.date), let g = Ephemeris.phaseGeometry(a, date: m.date) else { continue }
                if g.elongation < 12 { continue }
                let alt = bestDarkAltitude(raHours: p.ra, decDeg: p.dec, near: m.date, lat: lat, lon: lon)
                let bright = [a, b].allSatisfy { (Ephemeris.magnitude($0, date: m.date) ?? 9) < 6 }
                var tags: [SkyEvent.Tag] = []
                if m.value < fieldDegrees * 0.8 { tags.append(.fitsField) }
                if bright { tags.append(.nakedEye) }
                if g.elongation < 30 { tags.append(.twilight) }
                if alt < 15 { tags.append(.lowSky) }
                out.append(SkyEvent(kind: .pair, date: m.date, title: tr("%1$@ y %2$@", tr(a), tr(b)),
                                    detail: tr("Separación mínima de %.1f°.", m.value), tags: tags))
            }
        } }
        return out
    }

    // MARK: Oposiciones y elongaciones

    static func planetMilestones(from start: Date, to end: Date) -> [SkyEvent] {
        var out: [SkyEvent] = []
        for name in Astro.planetNames {
            let inner = name == "Mercurio" || name == "Venus"
            // Máximo de elongación: mínimo de −elongación.
            let f: (Date) -> Double = { -(Ephemeris.phaseGeometry(name, date: $0)?.elongation ?? 0) }
            for m in minima(from: start, to: end, step: 12 * 3600, limit: 0, f) {
                let e = -m.value
                if inner {
                    guard e > 15 else { continue }
                    let east = Astro.norm360((Astro.planet(name, date: m.date).map { $0.ra * 15 } ?? 0) - Astro.sun(m.date).ra * 15) < 180
                    out.append(SkyEvent(kind: .elongation, date: m.date,
                                        title: tr("Máxima elongación de %@", tr(name)),
                                        detail: tr("%1$.0f° del Sol, visible %2$@.", e, east ? tr("al anochecer") : tr("al amanecer")),
                                        tags: [.nakedEye, .twilight]))
                } else if e > 175 {
                    out.append(SkyEvent(kind: .opposition, date: m.date, title: tr("Oposición de %@", tr(name)),
                                        detail: tr("Toda la noche en el cielo y en su máximo brillo y tamaño: el mejor momento del año para fotografiarlo."),
                                        tags: (Ephemeris.magnitude(name, date: m.date) ?? 9) < 6 ? [.nakedEye] : []))
                }
            }
        }
        return out
    }

    // MARK: Cometas

    static func brightComets(_ orbits: [CometOrbit], from start: Date, to end: Date, lat: Double, lon: Double,
                             maxMagnitude: Double = 9) -> [SkyEvent] {
        var out: [SkyEvent] = []
        for o in orbits {
            // Momento de máximo brillo en el intervalo, en pasos de un día.
            var best: (Date, CometPosition)?
            var t = start
            while t <= end {
                let p = Comets.position(o, date: t)
                if p.magnitude.isFinite, best == nil || p.magnitude < best!.1.magnitude { best = (t, p) }
                t = t.addingTimeInterval(86400)
            }
            guard let (d, p) = best, p.magnitude <= maxMagnitude else { continue }
            let alt = bestDarkAltitude(raHours: p.raHours, decDeg: p.decDeg, near: d, lat: lat, lon: lon)
            guard alt > 0 else { continue }
            var tags: [SkyEvent.Tag] = p.magnitude < 6 ? [.nakedEye] : []
            if alt < 15 { tags.append(.lowSky) }
            out.append(SkyEvent(kind: .comet, date: d, title: o.name,
                                detail: tr("Magnitud prevista %.1f en su mejor momento del periodo.", p.magnitude), tags: tags))
        }
        return out.sorted { $0.date < $1.date }.prefix(8).map { $0 }
    }
}
