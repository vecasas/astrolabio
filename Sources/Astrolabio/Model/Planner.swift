import Foundation

enum FrameFit: Equatable {
    case small, good, mosaic(Int, Int)

    var label: String {
        switch self {
        case .small: return tr("Pequeño")
        case .good: return tr("Cabe bien")
        case .mosaic(let a, let b): return tr("Mosaico %@×%@", "\(a)", "\(b)")
        }
    }
}

struct TargetForecast: Identifiable {
    var id: String { object.id }
    let object: DeepSkyObject
    let minutesUsable: Double       // minutos sobre la altura mínima en plena oscuridad
    let maxAltitude: Double         // en la noche oscura
    let bestTime: Date?             // momento de máxima altura en la noche
    let windowStart: Date?
    let windowEnd: Date?
    let moonSeparation: Double
    let meanCloud: Double?
    let fit: FrameFit
    let score: Double
}

/// Ordena los objetos del catálogo para una noche concreta, como haría un astrónomo:
/// tiempo útil alto en el cielo y a oscuras, distancia a la Luna, nubes previstas y
/// si el objeto cabe en el campo del Seestar.
enum Planner {
    static func evaluate(objects: [DeepSkyObject],
                         night: Astro.Night,
                         lat: Double, lon: Double,
                         minAltitude: Double,
                         fov: (w: Double, h: Double),
                         weather: [WeatherHour]) -> [TargetForecast] {
        guard let start = night.duskStart, let end = night.dawnEnd, end > start else { return [] }
        let step: TimeInterval = 600
        var times: [Date] = []
        var t = start
        while t <= end { times.append(t); t = t.addingTimeInterval(step) }
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let moon = Astro.moon(mid)
        let moonAlts = times.map { Astro.altAz(raHours: Astro.moon($0).ra, decDeg: Astro.moon($0).dec, date: $0, lat: lat, lon: lon).alt }
        let moonUpFraction = Double(moonAlts.filter { $0 > 0 }.count) / Double(max(1, moonAlts.count))
        let clouds = times.map { WeatherService.cloudCover(at: $0, in: weather) }

        return objects.map { obj in
            let now = Astro.precessFromJ2000(raHours: obj.raHours, decDeg: obj.decDeg, to: mid)
            var usable = 0.0, maxAlt = -90.0
            var best: Date?
            var first: Date?, last: Date?
            var cloudSum = 0.0, cloudN = 0.0
            for (i, tm) in times.enumerated() {
                let alt = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: tm, lat: lat, lon: lon).alt
                if alt > maxAlt { maxAlt = alt; best = tm }
                if alt >= minAltitude {
                    usable += step / 60
                    if first == nil { first = tm }
                    last = tm
                    if let c = clouds[i] { cloudSum += c; cloudN += 1 }
                }
            }
            let sep = Astro.separation(ra1: now.ra, dec1: now.dec, ra2: moon.ra, dec2: moon.dec)
            let meanCloud = cloudN > 0 ? cloudSum / cloudN : nil
            let fit = frameFit(obj.sizeArcmin, fov: fov)

            var score = min(usable, 360) / 360 * 60                         // hasta 60 puntos por tiempo
            score += max(0, maxAlt - minAltitude) / (90 - minAltitude) * 15  // hasta 15 por altura
            let sensitivity: Double
            switch obj.kind {
            case .galaxy: sensitivity = 1.0
            case .planetary, .snr, .nebula: sensitivity = 0.5               // el filtro LP ayuda
            case .globular: sensitivity = 0.4
            case .open, .other: sensitivity = 0.2
            }
            let moonFactor = moon.illumination * moonUpFraction * (sep < 30 ? 1 : (sep < 60 ? 0.6 : 0.3))
            score *= 1 - sensitivity * moonFactor * 0.7
            if let mc = meanCloud { score *= 1 - mc / 100 * 0.9 }
            switch fit {
            case .small: score *= obj.sizeArcmin < 1.5 ? 0.6 : 0.8
            case .good: score *= 1
            case .mosaic: score *= 0.85
            }
            if obj.magnitude > 10.5 { score *= 0.85 }
            if usable == 0 { score = 0 }
            return TargetForecast(object: obj, minutesUsable: usable, maxAltitude: maxAlt, bestTime: best,
                                  windowStart: first, windowEnd: last, moonSeparation: sep,
                                  meanCloud: meanCloud, fit: fit, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    static func frameFit(_ sizeArcmin: Double, fov: (w: Double, h: Double)) -> FrameFit {
        let size = sizeArcmin / 60
        if size < fov.w * 0.12 { return .small }
        if size <= fov.h * 0.95 { return .good }
        let nW = Int(ceil(size / (fov.w * 0.85)))
        let nH = Int(ceil(size / (fov.h * 0.85)))
        return .mosaic(min(3, max(1, nW)), min(3, max(1, nH)))
    }

    /// Centros de los paneles de un mosaico (RA en horas, Dec en grados, mismas coordenadas que el centro).
    static func mosaicPanels(centerRA: Double, centerDec: Double, columns: Int, rows: Int,
                             overlapPercent: Double, fov: (w: Double, h: Double)) -> [(label: String, ra: Double, dec: Double)] {
        let stepDec = fov.h * (1 - overlapPercent / 100)
        let stepRAdeg = fov.w * (1 - overlapPercent / 100)
        var out: [(String, Double, Double)] = []
        for r in 0..<rows {
            let dec = centerDec + (Double(r) - Double(rows - 1) / 2) * stepDec
            let cosd = max(0.05, cos(dec * Astro.deg))
            for c in 0..<columns {
                var ra = centerRA + (Double(c) - Double(columns - 1) / 2) * stepRAdeg / cosd / 15
                if ra < 0 { ra += 24 }
                if ra >= 24 { ra -= 24 }
                out.append(("\(c + 1)\(r + 1)", ra, max(-89.9, min(89.9, dec))))
            }
        }
        return out
    }
}
