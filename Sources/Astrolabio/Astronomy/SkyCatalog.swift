import Foundation

/// Estrellas, líneas y nombres de constelaciones listos para dibujar (se leen una sola vez).
enum SkyCatalog {
    struct Star {
        let ra: Double      // grados
        let dec: Double     // grados
        let mag: Double
        let bv: Double
        let name: String
    }

    struct ConstellationLabel {
        let ra: Double
        let dec: Double
        let names: [String]     // es, en, fr, de, zh, ru
        let rank: Int

        var name: String {
            let i = AppLanguage.allCases.firstIndex(of: Loc.shared.language) ?? 0
            return i < names.count ? names[i] : names.first ?? ""
        }
    }

    static let stars: [Star] = StarData.stars.split(separator: "\n").compactMap { line in
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 5, let ra = Double(f[0]), let dec = Double(f[1]), let mag = Double(f[2]) else { return nil }
        return Star(ra: ra, dec: dec, mag: mag, bv: Double(f[3]) ?? 0.6, name: String(f[4]))
    }

    /// Polilíneas (AR, Dec en grados) de cada constelación.
    static let lines: [[(ra: Double, dec: Double)]] = StarData.lines.split(separator: "\n").compactMap { line in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let pts = line[line.index(after: colon)...].split(separator: ";").compactMap { p -> (ra: Double, dec: Double)? in
            let c = p.split(separator: ",")
            guard c.count == 2, let a = Double(c[0]), let d = Double(c[1]) else { return nil }
            return (a, d)
        }
        return pts.count >= 2 ? pts : nil
    }

    static let labels: [ConstellationLabel] = StarData.constellations.split(separator: "\n").compactMap { line in
        let f = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
        guard f.count == 4, let ra = Double(f[0]), let dec = Double(f[1]) else { return nil }
        return ConstellationLabel(ra: ra, dec: dec, names: f[3].split(separator: "|").map(String.init), rank: Int(f[2]) ?? 3)
    }
}

/// Proyección estereográfica del cielo visible: cenit en el centro y horizonte en el borde,
/// con el norte arriba y el este a la izquierda (como un planisferio mirando hacia arriba).
struct SkyProjection {
    let lat: Double
    let lst: Double            // tiempo sidéreo local en grados
    let center: CGPoint
    let radius: CGFloat        // radio del horizonte en puntos (ya con el zoom)

    init(date: Date, lat: Double, lon: Double, center: CGPoint, radius: CGFloat) {
        self.lat = lat
        self.lst = Astro.localSiderealTime(date, longitude: lon)
        self.center = center
        self.radius = radius
    }

    /// Altura y acimut (grados) de unas coordenadas ecuatoriales (AR y Dec en grados).
    func altAz(raDeg: Double, decDeg: Double) -> (alt: Double, az: Double) {
        let ha = (lst - raDeg) * Astro.deg
        let d = decDeg * Astro.deg, p = lat * Astro.deg
        let sinAlt = sin(d) * sin(p) + cos(d) * cos(p) * cos(ha)
        let alt = asin(max(-1, min(1, sinAlt)))
        let y = -sin(ha) * cos(d)
        let x = sin(d) * cos(p) - cos(d) * cos(ha) * sin(p)
        return (alt * Astro.rad, Astro.norm360(atan2(y, x) * Astro.rad))
    }

    func point(alt: Double, az: Double) -> CGPoint {
        let z = (90 - alt) * Astro.deg
        let r = Double(radius) * tan(z / 2)          // tan(45°) = 1 en el horizonte
        let a = az * Astro.deg
        return CGPoint(x: center.x - CGFloat(r * sin(a)), y: center.y - CGFloat(r * cos(a)))
    }

    /// Punto en pantalla, o nil si está bajo el horizonte (con un margen opcional).
    func point(raDeg: Double, decDeg: Double, minAlt: Double = 0) -> CGPoint? {
        let h = altAz(raDeg: raDeg, decDeg: decDeg)
        guard h.alt >= minAlt else { return nil }
        return point(alt: h.alt, az: h.az)
    }

    /// Inversa: de un punto de la pantalla a altura y acimut.
    func altAz(at p: CGPoint) -> (alt: Double, az: Double) {
        let dx = Double(center.x - p.x), dy = Double(center.y - p.y)
        let r = sqrt(dx * dx + dy * dy) / Double(radius)
        let z = 2 * atan(r)
        return (90 - z * Astro.rad, Astro.norm360(atan2(dx, dy) * Astro.rad))
    }
}
