import Foundation

/// Órbita de un cometa (elementos del Minor Planet Center, eclíptica J2000).
struct CometOrbit: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String            // «C/2025 A6 (Lemmon)», «12P/Pons-Brooks»
    let perihelionJD: Double    // fecha del perihelio (día juliano)
    let q: Double               // distancia del perihelio (UA)
    let e: Double               // excentricidad
    let argPeri: Double         // ω (°)
    let node: Double            // Ω (°)
    let incl: Double            // i (°)
    let h: Double               // magnitud absoluta
    let g: Double               // parámetro de pendiente (m = H + 5 log Δ + 2,5·G·log r)
}

/// Posición de un cometa vista desde la Tierra.
struct CometPosition: Equatable {
    let raHours: Double     // J2000
    let decDeg: Double      // J2000
    let r: Double           // distancia al Sol (UA)
    let delta: Double       // distancia a la Tierra (UA)
    let magnitude: Double
}

enum Comets {
    /// Constante gravitacional de Gauss (rad/día).
    static let k = 0.01720209895
    /// Tamaño máximo aceptado del archivo del MPC (el real ocupa unos 170 KB).
    static let maxBytes = 2 * 1024 * 1024

    // MARK: Lectura del archivo CometEls.txt del MPC (columnas fijas)

    static func parse(_ text: String) -> [CometOrbit] {
        var out: [CometOrbit] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let c = Array(line)
            guard c.count >= 103 else { continue }
            func field(_ a: Int, _ b: Int) -> String {
                String(c[min(a, c.count)..<min(b, c.count)]).trimmingCharacters(in: .whitespaces)
            }
            func num(_ a: Int, _ b: Int) -> Double? { Double(field(a, b)) }
            guard let year = Int(field(14, 18)), let month = Int(field(19, 21)), let day = num(22, 29),
                  let q = num(30, 39), let e = num(41, 49), let w = num(51, 59), let node = num(61, 69),
                  let i = num(71, 79), q > 0, e >= 0, e < 10, (1...12).contains(month) else { continue }
            let name = field(102, 158)
            guard !name.isEmpty else { continue }
            out.append(CometOrbit(name: name, perihelionJD: julianDay(year: year, month: month, day: day),
                                  q: q, e: e, argPeri: w, node: node, incl: i,
                                  h: num(91, 95) ?? 15, g: num(96, 100) ?? 4))
        }
        return out
    }

    static func julianDay(year: Int, month: Int, day: Double) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(y / 100), b = 2 - a + floor(a / 4)
        return floor(365.25 * (y + 4716)) + floor(30.6001 * (m + 1)) + day + b - 1524.5
    }

    // MARK: Posición

    /// Posición heliocéntrica eclíptica J2000 (UA) en un día juliano.
    static func heliocentric(_ o: CometOrbit, jd: Double) -> (x: Double, y: Double, z: Double, r: Double) {
        let dt = jd - o.perihelionJD
        var xv: Double, yv: Double
        if abs(o.e - 1) < 1e-6 {
            // Parabólica: ecuación de Barker.
            let w = 3 * k * dt / (sqrt(2) * pow(o.q, 1.5))
            let yb = cbrt(w / 2 + sqrt(w * w / 4 + 1))
            let s = yb - 1 / yb
            xv = o.q * (1 - s * s)
            yv = 2 * o.q * s
        } else if o.e < 1 {
            let a = o.q / (1 - o.e)
            let mAnom = k * dt / pow(a, 1.5)
            let mm = remainder(mAnom, 2 * .pi)
            // Valor inicial de Danby: converge bien también con excentricidades cercanas a 1.
            var ea = mm + 0.85 * o.e * (sin(mm) >= 0 ? 1 : -1)
            for _ in 0..<100 {
                let f = ea - o.e * sin(ea) - mm
                let d = f / (1 - o.e * cos(ea))
                ea -= d
                if abs(d) < 1e-12 { break }
            }
            xv = a * (cos(ea) - o.e)
            yv = a * sqrt(1 - o.e * o.e) * sin(ea)
        } else {
            let a = o.q / (o.e - 1)
            let mAnom = k * dt / pow(a, 1.5)
            var hA = asinh(mAnom / o.e)
            for _ in 0..<100 {
                let f = o.e * sinh(hA) - hA - mAnom
                let d = f / (o.e * cosh(hA) - 1)
                hA -= d
                if abs(d) < 1e-12 { break }
            }
            xv = a * (o.e - cosh(hA))
            yv = a * sqrt(o.e * o.e - 1) * sinh(hA)
        }
        let r = sqrt(xv * xv + yv * yv)
        let v = atan2(yv, xv)
        let deg = Double.pi / 180
        let node = o.node * deg, w = o.argPeri * deg, i = o.incl * deg
        let u = w + v
        let x = r * (cos(node) * cos(u) - sin(node) * sin(u) * cos(i))
        let y = r * (sin(node) * cos(u) + cos(node) * sin(u) * cos(i))
        let z = r * sin(u) * sin(i)
        return (x, y, z, r)
    }

    /// Tierra heliocéntrica, eclíptica J2000 (UA), con una fórmula solar de baja precisión (~0,01°).
    static func earth(jd: Double) -> (x: Double, y: Double, z: Double) {
        let n = jd - 2451545.0
        let lMean = 280.460 + 0.9856474 * n
        let g = (357.528 + 0.9856003 * n) * .pi / 180
        // Longitud del Sol de la fecha → J2000 (precesión: 1,397° por siglo).
        let lambda = (lMean + 1.915 * sin(g) + 0.020 * sin(2 * g) - 1.3970 * n / 36525) * .pi / 180
        let rSun = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        return (-rSun * cos(lambda), -rSun * sin(lambda), 0)
    }

    static func position(_ o: CometOrbit, date: Date) -> CometPosition {
        let jdUTC = Astro.julianDay(date)
        let jd = jdUTC + 69.2 / 86400          // TT ≈ UTC + 69 s
        let e = earth(jd: jd)
        var c = heliocentric(o, jd: jd)
        var dx = c.x - e.x, dy = c.y - e.y, dz = c.z - e.z
        var delta = sqrt(dx * dx + dy * dy + dz * dz)
        // Tiempo de luz (una iteración basta).
        c = heliocentric(o, jd: jd - delta * 0.0057755183)
        dx = c.x - e.x; dy = c.y - e.y; dz = c.z - e.z
        delta = sqrt(dx * dx + dy * dy + dz * dz)
        let eps = 23.4392911 * Double.pi / 180
        let xq = dx, yq = dy * cos(eps) - dz * sin(eps), zq = dy * sin(eps) + dz * cos(eps)
        var ra = atan2(yq, xq) * 180 / .pi / 15
        if ra < 0 { ra += 24 }
        let dec = asin(zq / delta) * 180 / .pi
        let mag = o.h + 5 * log10(delta) + 2.5 * o.g * log10(c.r)
        return CometPosition(raHours: ra, decDeg: dec, r: c.r, delta: delta, magnitude: mag)
    }

    // MARK: Cometas visibles esta noche

    struct Forecast: Identifiable, Equatable {
        var id: String { orbit.name }
        let orbit: CometOrbit
        let position: CometPosition     // a mitad de la noche
        let maxAltitude: Double
        let best: Date?
        let usableMinutes: Double
    }

    /// Cometas más brillantes que `maxMagnitude` que suben por encima de `minAltitude` de noche.
    static func visible(_ orbits: [CometOrbit], night: Astro.Night, lat: Double, lon: Double,
                        minAltitude: Double, maxMagnitude: Double = 12) -> [Forecast] {
        guard let start = night.duskStart, let end = night.dawnEnd, end > start else { return [] }
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        var times: [Date] = []
        var t = start
        while t <= end { times.append(t); t = t.addingTimeInterval(900) }
        return orbits.compactMap { o -> Forecast? in
            // Primero la magnitud (barata); los cometas lejanos se descartan enseguida.
            let p = position(o, date: mid)
            guard p.magnitude <= maxMagnitude, p.magnitude.isFinite else { return nil }
            let now = Astro.precessFromJ2000(raHours: p.raHours, decDeg: p.decDeg, to: mid)
            var maxAlt = -90.0, best: Date?, usable = 0.0
            for tm in times {
                let alt = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: tm, lat: lat, lon: lon).alt
                if alt > maxAlt { maxAlt = alt; best = tm }
                if alt >= minAltitude { usable += 15 }
            }
            guard usable > 0 else { return nil }
            return Forecast(orbit: o, position: p, maxAltitude: maxAlt, best: best, usableMinutes: usable)
        }
        .sorted { $0.position.magnitude < $1.position.magnitude }
    }
}
