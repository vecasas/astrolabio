import Foundation

/// Horizonte propio: altura de los obstáculos (árboles, tejados, montes) en cada acimut.
/// Se guarda cada 10° (36 puntos) y se interpola entre ellos.
struct Horizon: Codable, Equatable {
    static let step = 10.0
    static let count = 36
    /// Altura máxima que se puede dibujar.
    static let maxAltitude = 70.0

    /// Altura (°) en los acimuts 0°, 10°, … 350°.
    var altitudes: [Double]

    static let flat = Horizon(altitudes: Array(repeating: 0, count: count))

    init(altitudes: [Double]) {
        var a = Array(altitudes.prefix(Self.count))
        if a.count < Self.count { a += Array(repeating: 0, count: Self.count - a.count) }
        self.altitudes = a.map { min(Self.maxAltitude, max(0, $0.isFinite ? $0 : 0)) }
    }

    var isFlat: Bool { altitudes.allSatisfy { $0 == 0 } }

    /// Altura del horizonte en un acimut (°, 0 = norte, 90 = este), interpolada.
    func altitude(atAzimuth az: Double) -> Double {
        var a = az.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let i = Int(a / Self.step) % Self.count
        let j = (i + 1) % Self.count
        let f = (a - Double(i) * Self.step) / Self.step
        return altitudes[i] * (1 - f) + altitudes[j] * f
    }

    /// ¿Se ve un objeto a esa altura y acimut, con la altura mínima de los ajustes?
    func isVisible(altitude: Double, azimuth: Double, minAltitude: Double) -> Bool {
        altitude >= max(minAltitude, self.altitude(atAzimuth: azimuth))
    }

    /// Cambia la altura en el acimut más cercano.
    mutating func set(azimuth: Double, altitude: Double) {
        var a = azimuth.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let i = Int((a / Self.step).rounded()) % Self.count
        altitudes[i] = min(Self.maxAltitude, max(0, altitude))
    }

    /// Texto «acimut altura» por línea, para guardar o compartir.
    func text() -> String {
        altitudes.enumerated().map { "\(Int(Double($0.offset) * Self.step)) \(String(format: "%.0f", $0.element))" }.joined(separator: "\n")
    }

    /// Lee un horizonte en texto: líneas «acimut altura» (separadas por espacio, coma, punto y coma o tabulador).
    /// Admite acimuts en cualquier orden y cualquier paso; los huecos se interpolan.
    static func parse(_ text: String) -> Horizon? {
        var points: [(az: Double, alt: Double)] = []
        for raw in text.split(whereSeparator: \.isNewline).prefix(2000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(whereSeparator: { " ,;\t".contains($0) }).compactMap { Double($0) }
            guard f.count >= 2, f[0].isFinite, f[1].isFinite else { continue }
            var az = f[0].truncatingRemainder(dividingBy: 360)
            if az < 0 { az += 360 }
            points.append((az, f[1]))
        }
        guard points.count >= 2 else { return nil }
        points.sort { $0.az < $1.az }
        func interp(_ az: Double) -> Double {
            // Vecinos en el círculo.
            let after = points.first { $0.az >= az } ?? points[0]
            let before = points.last { $0.az <= az } ?? points[points.count - 1]
            var span = after.az - before.az
            if span <= 0 { span += 360 }
            if span == 360 { return before.alt }
            var d = az - before.az
            if d < 0 { d += 360 }
            return before.alt + (after.alt - before.alt) * d / span
        }
        return Horizon(altitudes: (0..<count).map { interp(Double($0) * step) })
    }
}

/// Lo que limita la vista: la altura mínima de los ajustes y el horizonte propio.
struct SkyLimit: Equatable {
    var minAltitude: Double
    var horizon: Horizon = .flat

    /// ¿Se ve un objeto (coordenadas de la fecha) en ese momento?
    func clear(raHours: Double, decDeg: Double, date: Date, lat: Double, lon: Double) -> Bool {
        let aa = Astro.altAz(raHours: raHours, decDeg: decDeg, date: date, lat: lat, lon: lon)
        return horizon.isVisible(altitude: aa.alt, azimuth: aa.az, minAltitude: minAltitude)
    }

    /// Lo mismo para un objeto fijo en J2000 (se precesa una vez).
    func clearFixed(raJ2000: Double, decJ2000: Double, lat: Double, lon: Double) -> (Date) -> Bool {
        let now = Astro.precessFromJ2000(raHours: raJ2000, decDeg: decJ2000, to: Date())
        return { clear(raHours: now.ra, decDeg: now.dec, date: $0, lat: lat, lon: lon) }
    }
}

extension AppSettings {
    var skyLimit: SkyLimit { SkyLimit(minAltitude: minAltitude, horizon: horizon) }
}
