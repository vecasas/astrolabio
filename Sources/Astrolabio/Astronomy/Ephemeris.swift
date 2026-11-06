import Foundation

/// Utilidades de efemérides construidas sobre `Astro`: salidas, puestas y tránsitos,
/// próximas fases lunares y datos físicos aproximados de los planetas.
enum Ephemeris {

    struct RiseSet {
        var rise: Date?
        var transit: Date?
        var set: Date?
        var maxAltitude: Double
        var alwaysUp: Bool
        var neverUp: Bool
    }

    /// Busca salida, tránsito (máxima altura) y puesta en [start, start + hours] muestreando
    /// la altura cada `step` segundos e interpolando el cruce del horizonte `h0`.
    static func riseSet(from start: Date, hours: Double = 24, step: TimeInterval = 300, h0: Double = 0,
                        altitude: (Date) -> Double) -> RiseSet {
        var out = RiseSet(rise: nil, transit: nil, set: nil, maxAltitude: -90, alwaysUp: true, neverUp: true)
        var t = start
        var prev = altitude(t)
        let end = start.addingTimeInterval(hours * 3600)
        out.maxAltitude = prev
        out.transit = t
        if prev >= h0 { out.neverUp = false } else { out.alwaysUp = false }
        while t < end {
            let next = t.addingTimeInterval(step)
            let alt = altitude(next)
            if alt > out.maxAltitude { out.maxAltitude = alt; out.transit = next }
            if alt >= h0 { out.neverUp = false } else { out.alwaysUp = false }
            if prev < h0 && alt >= h0 && out.rise == nil {
                out.rise = t.addingTimeInterval(step * (h0 - prev) / (alt - prev))
            }
            if prev >= h0 && alt < h0 && out.set == nil {
                out.set = t.addingTimeInterval(step * (prev - h0) / (prev - alt))
            }
            prev = alt
            t = next
        }
        return out
    }

    static func altitudeOfFixed(raJ2000: Double, decJ2000: Double, lat: Double, lon: Double) -> (Date) -> Double {
        let now = Astro.precessFromJ2000(raHours: raJ2000, decDeg: decJ2000, to: Date())
        return { Astro.altAz(raHours: now.ra, decDeg: now.dec, date: $0, lat: lat, lon: lon).alt }
    }

    static func moonAltitude(lat: Double, lon: Double) -> (Date) -> Double {
        { let m = Astro.moon($0); return Astro.altAz(raHours: m.ra, decDeg: m.dec, date: $0, lat: lat, lon: lon).alt }
    }

    static func planetAltitude(_ name: String, lat: Double, lon: Double) -> (Date) -> Double {
        { d in
            guard let p = Astro.planet(name, date: d) else { return -90 }
            return Astro.altAz(raHours: p.ra, decDeg: p.dec, date: d, lat: lat, lon: lon).alt
        }
    }

    // MARK: Fases de la Luna

    enum PhaseKind: Double, CaseIterable {
        case new = 0, firstQuarter = 90, full = 180, lastQuarter = 270
        var name: String {
            switch self {
            case .new: return tr("Luna nueva")
            case .firstQuarter: return tr("Cuarto creciente")
            case .full: return tr("Luna llena")
            case .lastQuarter: return tr("Cuarto menguante")
            }
        }
        var symbol: String {
            switch self {
            case .new: return "moonphase.new.moon"
            case .firstQuarter: return "moonphase.first.quarter"
            case .full: return "moonphase.full.moon"
            case .lastQuarter: return "moonphase.last.quarter"
            }
        }
    }

    /// Elongación Luna−Sol (0–360°): 0 nueva, 90 cuarto creciente, 180 llena, 270 menguante.
    static func moonElongation(_ d: Date) -> Double {
        Astro.norm360(Astro.moon(d).lambda - Astro.sun(d).lambda)
    }

    /// Próximas fases principales a partir de `date` (precisión de unos minutos).
    static func nextPhases(after date: Date, count: Int = 4) -> [(kind: PhaseKind, date: Date)] {
        var out: [(PhaseKind, Date)] = []
        var t = date
        let step: TimeInterval = 3 * 3600
        var prev = moonElongation(t)
        while out.count < count && t < date.addingTimeInterval(40 * 86400) {
            let next = t.addingTimeInterval(step)
            let e = moonElongation(next)
            for kind in PhaseKind.allCases {
                let target = kind.rawValue
                // Diferencia con signo respecto a la fase buscada, en (−180, 180].
                func diff(_ x: Double) -> Double { var d = x - target; while d > 180 { d -= 360 }; while d <= -180 { d += 360 }; return d }
                let d0 = diff(prev), d1 = diff(e)
                if d0 < 0 && d1 >= 0 && abs(d1 - d0) < 90 {
                    // Bisección para afinar.
                    var a = t, b = next
                    for _ in 0..<20 {
                        let m = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                        if diff(moonElongation(m)) < 0 { a = m } else { b = m }
                    }
                    out.append((kind, b))
                }
            }
            prev = e
            t = next
        }
        return out.sorted { $0.1 < $1.1 }.prefix(count).map { (kind: $0.0, date: $0.1) }
    }

    /// Distancia aproximada Tierra–Luna en km (término principal de la serie de Meeus).
    static func moonDistanceKm(_ d: Date) -> Double {
        let t = (Astro.julianDay(d) - 2451545.0) / 36525
        let mPrime = (134.9633964 + 477198.8675055 * t) * Astro.deg
        let dElong = (297.8501921 + 445267.1114034 * t) * Astro.deg
        let m = (357.5291092 + 35999.0502909 * t) * Astro.deg
        return 385000.56 - 20905.355 * cos(mPrime) - 3699.111 * cos(2 * dElong - mPrime)
            - 2955.968 * cos(2 * dElong) - 569.925 * cos(2 * mPrime) + 48.888 * cos(m)
    }

    // MARK: Planetas

    struct PlanetInfo {
        let diameterKm: Double
        let symbol: String
        let note: String
    }

    static let planetInfo: [String: PlanetInfo] = [
        "Mercurio": PlanetInfo(diameterKm: 4879, symbol: "circle.fill", note: tr("Siempre cerca del Sol: búscalo en el crepúsculo.")),
        "Venus": PlanetInfo(diameterKm: 12104, symbol: "sparkle", note: tr("Muestra fases como la Luna.")),
        "Marte": PlanetInfo(diameterKm: 6779, symbol: "circle.fill", note: tr("Mejor cerca de la oposición, cuando se ve más grande.")),
        "Júpiter": PlanetInfo(diameterKm: 139820, symbol: "circle.fill", note: tr("Bandas de nubes y las cuatro lunas galileanas.")),
        "Saturno": PlanetInfo(diameterKm: 116460, symbol: "circle.circle", note: tr("Los anillos se distinguen incluso con el Seestar.")),
        "Urano": PlanetInfo(diameterKm: 50724, symbol: "circle.fill", note: tr("Un pequeño disco verdoso.")),
        "Neptuno": PlanetInfo(diameterKm: 49244, symbol: "circle.fill", note: tr("Un punto azulado: pide un apilado largo.")),
    ]

    /// Diámetro aparente en segundos de arco.
    static func apparentDiameterArcsec(_ name: String, distanceAU: Double) -> Double? {
        guard let info = planetInfo[name], distanceAU > 0 else { return nil }
        let km = distanceAU * 149_597_870.7
        return 2 * atan(info.diameterKm / 2 / km) * Astro.rad * 3600
    }

    /// Distancia al Sol (UA) y ángulo de fase (°) del planeta visto desde la Tierra.
    static func phaseGeometry(_ name: String, date: Date) -> (sunDistance: Double, phaseAngle: Double, elongation: Double)? {
        guard let p = Astro.planet(name, date: date) else { return nil }
        let s = Astro.sun(date)
        let elong = Astro.separation(ra1: p.ra, dec1: p.dec, ra2: s.ra, dec2: s.dec)
        // Distancia Tierra–Sol ≈ 1 UA; ley del coseno para r (planeta–Sol).
        let delta = p.distance
        let r = sqrt(max(0.01, 1 + delta * delta - 2 * delta * cos(elong * Astro.deg)))
        let cosPhase = (r * r + delta * delta - 1) / (2 * r * delta)
        return (r, acos(max(-1, min(1, cosPhase))) * Astro.rad, elong)
    }

    /// Magnitud visual aproximada (fórmulas sencillas de Meeus/Explanatory Supplement).
    static func magnitude(_ name: String, date: Date) -> Double? {
        guard let p = Astro.planet(name, date: date), let g = phaseGeometry(name, date: date) else { return nil }
        let k = 5 * log10(g.sunDistance * p.distance)
        let i = g.phaseAngle
        switch name {
        case "Mercurio": return -0.42 + k + 0.038 * i - 0.000273 * i * i + 0.000002 * i * i * i
        case "Venus": return -4.40 + k + 0.0009 * i + 0.000239 * i * i - 0.00000065 * i * i * i
        case "Marte": return -1.52 + k + 0.016 * i
        case "Júpiter": return -9.40 + k + 0.005 * i
        case "Saturno": return -8.88 + k + 0.044 * i
        case "Urano": return -7.19 + k
        case "Neptuno": return -6.87 + k
        default: return nil
        }
    }
}
