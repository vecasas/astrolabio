import Foundation

/// Nitidez de las estrellas: radio de media intensidad (HFR) en píxeles.
enum StarMetrics {
    struct Result: Equatable {
        let hfr: Double
        let stars: Int
    }

    /// Mide la mediana del HFR de las estrellas de una imagen de luminancia lineal (0…1).
    /// Devuelve nil si hay menos de `minStars` estrellas medibles (nubes, desenfoque extremo, día).
    static func measure(_ lum: [Float], width: Int, height: Int, radius: Int = 8, maxStars: Int = 150, minStars: Int = 5) -> Result? {
        guard width > 4 * radius, height > 4 * radius, lum.count >= width * height else { return nil }
        // Fondo y ruido con una muestra (mediana y MAD).
        var sample: [Float] = []
        sample.reserveCapacity(width * height / 49 + 1)
        var i = 0
        while i < width * height { sample.append(lum[i]); i += 49 }
        sample.sort()
        let bg = sample[sample.count / 2]
        var dev = sample.map { abs($0 - bg) }
        dev.sort()
        let sigma = max(1e-5, dev[dev.count / 2] * 1.4826)
        let threshold = bg + 6 * sigma
        let saturation: Float = 0.95

        // Máximos locales por encima del umbral.
        var peaks: [(x: Int, y: Int, v: Float)] = []
        for y in stride(from: radius, to: height - radius, by: 1) {
            let row = y * width
            var x = radius
            while x < width - radius {
                let v = lum[row + x]
                if v > threshold && v < saturation {
                    var isMax = true
                    loop: for dy in -2...2 {
                        for dx in -2...2 where dx != 0 || dy != 0 {
                            if lum[row + dy * width + x + dx] > v { isMax = false; break loop }
                        }
                    }
                    if isMax { peaks.append((x, y, v)); x += radius; continue }
                }
                x += 1
            }
        }
        guard peaks.count >= minStars else { return nil }
        peaks.sort { $0.v > $1.v }

        var hfrs: [Double] = []
        var taken: [(Int, Int)] = []
        for p in peaks {
            if hfrs.count >= maxStars { break }
            // Sin estrellas vecinas que contaminen la medida.
            if taken.contains(where: { abs($0.0 - p.x) < 2 * radius && abs($0.1 - p.y) < 2 * radius }) { continue }
            var sumF = 0.0, sumRF = 0.0, cx = 0.0, cy = 0.0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let f = Double(max(0, lum[(p.y + dy) * width + p.x + dx] - bg))
                    sumF += f; cx += f * Double(dx); cy += f * Double(dy)
                }
            }
            guard sumF > 0 else { continue }
            cx /= sumF; cy /= sumF
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let f = Double(max(0, lum[(p.y + dy) * width + p.x + dx] - bg))
                    let r = ((Double(dx) - cx) * (Double(dx) - cx) + (Double(dy) - cy) * (Double(dy) - cy)).squareRoot()
                    sumRF += r * f
                }
            }
            let hfr = sumRF / sumF
            if hfr > 0.3 && hfr < Double(radius) * 0.8 { hfrs.append(hfr); taken.append((p.x, p.y)) }
        }
        guard hfrs.count >= minStars else { return nil }
        hfrs.sort()
        return Result(hfr: hfrs[hfrs.count / 2], stars: hfrs.count)
    }

    /// Luminancia de una imagen lineal en color.
    static func luminance(_ img: LinearImage) -> [Float] {
        var out = [Float](repeating: 0, count: img.width * img.height)
        for i in out.indices { out[i] = 0.2126 * img.r[i] + 0.7152 * img.g[i] + 0.0722 * img.b[i] }
        return out
    }
}

/// Vigila si las estrellas pierden nitidez durante el apilado (enfoque o rocío).
struct FocusWatch {
    /// Empeoramiento relativo a partir del que se avisa (0,3 = 30 %).
    var threshold = 0.3
    private(set) var target = ""
    private(set) var baseline: Double?
    private(set) var recent: [Double] = []
    private var warmup: [Double] = []

    enum Verdict: Equatable { case learning, ok, softening(percent: Int) }

    init(threshold: Double = 0.3) { self.threshold = threshold }

    /// Añade una medida. La referencia es la mediana de las tres primeras medidas de cada objeto.
    mutating func add(hfr: Double, target: String) -> Verdict {
        if target != self.target { reset(target: target) }
        if baseline == nil {
            warmup.append(hfr)
            if warmup.count >= 3 { baseline = warmup.sorted()[1] }
            return .learning
        }
        recent.append(hfr)
        if recent.count > 3 { recent.removeFirst() }
        guard let base = baseline, recent.count == 3 else { return .ok }
        let now = recent.sorted()[1]
        // Hace falta empeorar en proporción y al menos medio píxel (el ruido de la medida).
        if now > base * (1 + threshold) && now - base >= 0.5 {
            return .softening(percent: Int(((now / base) - 1) * 100))
        }
        return .ok
    }

    mutating func reset(target: String = "") {
        self.target = target
        baseline = nil
        recent = []
        warmup = []
    }
}

/// Riesgo de rocío a partir de la temperatura y el punto de rocío.
enum DewRisk: Equatable {
    case low, possible, high

    static func level(temperature: Double, dewPoint: Double) -> DewRisk {
        let spread = temperature - dewPoint
        if spread < 2 { return .high }
        if spread < 4 { return .possible }
        return .low
    }
}

/// Aviso meteorológico oficial (MeteoAlarm, formato CAP).
struct WeatherWarning: Equatable, Identifiable {
    var id: String { "\(area)|\(event)|\(onset.timeIntervalSince1970)" }
    let area: String
    let event: String
    let headline: String
    /// 1 verde, 2 amarillo, 3 naranja, 4 rojo.
    let level: Int
    /// Tipo MeteoAlarm: 1 viento, 2 nieve/hielo, 3 tormenta, 4 niebla, 10 lluvia, 12 inundación, 13 lluvia e inundación…
    let type: Int
    let onset: Date
    let expires: Date

    static let dangerousTypes: Set<Int> = [1, 2, 3, 10, 12, 13]

    func isActive(at date: Date) -> Bool { onset <= date && date <= expires }
    var isDangerous: Bool { level >= 2 && Self.dangerousTypes.contains(type) }
}

/// Guardia de tormenta: decide si hay que recoger el telescopio.
enum StormGuard {
    /// Motivo para recoger, o nil si no hace falta.
    /// - Parameters:
    ///   - warnings: avisos oficiales de la zona elegida.
    ///   - hours: previsión horaria (código de tiempo, precipitación y rachas).
    static func reason(warnings: [WeatherWarning], hours: [WeatherHour], now: Date = Date()) -> String? {
        if let w = warnings.first(where: { $0.isActive(at: now) && $0.isDangerous }) {
            return tr("Aviso oficial: %@", w.headline.isEmpty ? w.event : w.headline)
        }
        // Próxima hora y media de previsión.
        let soon = hours.filter { $0.time >= now.addingTimeInterval(-1800) && $0.time <= now.addingTimeInterval(5400) }
        if soon.contains(where: { (95...99).contains($0.weatherCode) }) {
            return tr("Se prevén tormentas en la próxima hora.")
        }
        if let h = soon.first(where: { $0.precipitation >= 0.3 }) {
            return tr("Se prevé lluvia (%@ mm/h).", String(format: "%.1f", h.precipitation))
        }
        if let h = soon.first(where: { $0.gusts >= 50 }) {
            return tr("Se prevén rachas de viento de %@ km/h.", "\(Int(h.gusts))")
        }
        return nil
    }
}
