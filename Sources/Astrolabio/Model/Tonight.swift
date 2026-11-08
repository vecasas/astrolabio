import Foundation

/// Navegación compartida: permite que una sección lleve a otra (por ejemplo, «Elige por mí»
/// abre «Sesión automática» tras preparar un plan).
@MainActor
final class AppNavigation: ObservableObject {
    @Published var selection: AppSection? = .tonight
    /// Paso del tutorial que se muestra (nil: ninguno).
    @Published var tutorialStep: Int?
    /// Tema del manual que se resalta al abrirlo con «?».
    @Published var helpTopic: String?
}

/// Cálculo de la noche de hoy compartido por «Qué mirar», «Elige por mí» y la carta estelar.
@MainActor
final class TonightModel: ObservableObject {
    @Published private(set) var night: Astro.Night?
    @Published private(set) var forecasts: [TargetForecast] = []
    @Published private(set) var computedAt: Date?
    @Published private(set) var isComputing = false

    private var key = ""

    /// Recalcula si ha cambiado el lugar, los ajustes, la previsión o ha pasado más de media hora.
    func update(settings: AppSettings, weather: [WeatherHour], force: Bool = false) async {
        let newKey = "\(settings.latitude),\(settings.longitude),\(settings.minAltitude),\(settings.fovWidthDeg),\(settings.fovHeightDeg),\(settings.horizon.altitudes),\(weather.count),\(weather.first?.time.timeIntervalSince1970 ?? 0)"
        if !force, newKey == key, let c = computedAt, Date().timeIntervalSince(c) < 1800 { return }
        key = newKey
        isComputing = true
        defer { isComputing = false }
        let lat = settings.latitude, lon = settings.longitude, minAlt = settings.minAltitude
        let fov = (w: settings.fovWidthDeg, h: settings.fovHeightDeg)
        let horizon = settings.horizon
        let n = Astro.night(for: Date(), lat: lat, lon: lon)
        night = n
        forecasts = await Task.detached(priority: .userInitiated) {
            Planner.evaluate(objects: Catalog.featured, night: n, lat: lat, lon: lon,
                             minAltitude: minAlt, fov: fov, weather: weather, horizon: horizon)
        }.value
        computedAt = Date()
    }

    /// Nota de 0 a 100 para la noche: duración de la oscuridad, nubes y Luna.
    func nightQuality(weather: [WeatherHour]) -> (score: Double, cloud: Double?, moonFactor: Double)? {
        guard let n = night, let start = n.duskStart, let end = n.dawnEnd, end > start else { return nil }
        let hours = end.timeIntervalSince(start) / 3600
        var cloudSum = 0.0, cloudN = 0.0
        var t = start
        while t <= end {
            if let c = WeatherService.cloudCover(at: t, in: weather) { cloudSum += c; cloudN += 1 }
            t = t.addingTimeInterval(3600)
        }
        let cloud = cloudN > 0 ? cloudSum / cloudN : nil
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let moonFactor = Astro.moon(mid).illumination
        var score = min(1, hours / 8) * 100
        if let cloud { score *= 1 - cloud / 100 * 0.9 }
        score *= 1 - moonFactor * 0.45
        return (score, cloud, moonFactor)
    }
}

/// Una sugerencia concreta para observar ahora (o cuando oscurezca).
struct Suggestion: Identifiable {
    var id: String { forecast.id }
    let forecast: TargetForecast
    let altitudeNow: Double
    let remainingMinutes: Double     // minutos útiles desde `start` hasta que baje o amanezca
    let start: Date
    let reasons: [String]
    let suggestedMinutes: Double
    let useLPFilter: Bool
}

enum PickStyle: String, CaseIterable, Identifiable {
    case best = "Lo mejor ahora"
    case easy = "Fácil y brillante"
    case challenge = "Un reto"
    case surprise = "Sorpréndeme"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .best: return "star.fill"
        case .easy: return "sun.min"
        case .challenge: return "flame"
        case .surprise: return "dice"
        }
    }
}

enum Picker4Me {
    /// Devuelve las sugerencias ordenadas para el estilo pedido.
    static func suggestions(from forecasts: [TargetForecast], night: Astro.Night?, style: PickStyle,
                            lat: Double, lon: Double, minAltitude: Double, horizon: Horizon = .flat, now: Date = Date()) -> [Suggestion] {
        // Si aún no es de noche, se sugiere para el inicio de la noche cerrada.
        var start = now
        if let dusk = night?.duskStart, now < dusk { start = dusk }
        let end = night?.dawnEnd ?? start.addingTimeInterval(6 * 3600)
        guard end > start else { return [] }

        var out: [Suggestion] = []
        for f in forecasts where f.score > 0 {
            let alt = Ephemeris.altitudeOfFixed(raJ2000: f.object.raHours, decJ2000: f.object.decDeg, lat: lat, lon: lon)
            let clear = SkyLimit(minAltitude: minAltitude, horizon: horizon).clearFixed(raJ2000: f.object.raHours, decJ2000: f.object.decDeg, lat: lat, lon: lon)
            let a0 = alt(start)
            guard clear(start) else { continue }
            var remaining = 0.0
            var t = start
            var peak = a0, peakTime = start
            while t < end {
                let a = alt(t)
                if !clear(t) { break }
                if a > peak { peak = a; peakTime = t }
                remaining += 10
                t = t.addingTimeInterval(600)
            }
            guard remaining >= 40 else { continue }

            var reasons: [String] = []
            if peakTime > start.addingTimeInterval(600) {
                reasons.append(tr("Está a %.0f° y sube hasta %.0f° hacia las %@.", a0, peak, peakTime.shortTime))
            } else if alt(start.addingTimeInterval(1800)) < a0 - 1 {
                reasons.append(tr("Está a %.0f° y empieza a bajar: mejor ahora que más tarde.", a0))
            } else {
                reasons.append(tr("Está a %.0f° de altura, en su mejor momento.", a0))
            }
            reasons.append(tr("Quedan %.1f h por encima de %.0f°.", remaining / 60, minAltitude))
            reasons.append(tr("La Luna está a %.0f°%@.", f.moonSeparation, f.moonSeparation > 60 ? tr(", lejos") : (f.moonSeparation < 30 ? tr(", demasiado cerca") : "")))
            switch f.fit {
            case .good: reasons.append(tr("Cabe entero en el campo del Seestar."))
            case .small: reasons.append(tr("Es pequeño: después conviene recortar la imagen."))
            case .mosaic(let c, let r): reasons.append(tr("Es grande: queda mejor como mosaico %@×%@.", "\(c)", "\(r)"))
            }
            let lp = [.nebula, .snr, .planetary].contains(f.object.kind)
            if lp { reasons.append(tr("Es una nebulosa de emisión: el filtro antipolución ayuda.")) }
            if let c = f.meanCloud { reasons.append(tr("Nubes previstas: %.0f %%.", c)) }

            let minutes = min(remaining * 0.8, 120)
            out.append(Suggestion(forecast: f, altitudeNow: a0, remainingMinutes: remaining, start: start,
                                  reasons: reasons, suggestedMinutes: max(20, (minutes / 10).rounded() * 10),
                                  useLPFilter: lp))
        }

        switch style {
        case .best:
            out.sort { $0.forecast.score + min($0.remainingMinutes, 240) / 24 > $1.forecast.score + min($1.remainingMinutes, 240) / 24 }
        case .easy:
            out = out.filter { $0.forecast.object.magnitude <= 8 && $0.forecast.fit != .small }
            out.sort { ($0.forecast.object.magnitude - $0.forecast.score / 20) < ($1.forecast.object.magnitude - $1.forecast.score / 20) }
        case .challenge:
            out = out.filter { $0.forecast.object.magnitude > 9 || $0.forecast.object.kind == .snr }
            out.sort { $0.forecast.score > $1.forecast.score }
        case .surprise:
            let top = out.sorted { $0.forecast.score > $1.forecast.score }.prefix(15)
            out = Array(top).shuffled()
        }
        return out
    }

    /// Plan sencillo para el resto de la noche: reparte el tiempo entre objetos que estén altos
    /// en cada tramo, sin repetir.
    static func shortPlan(from forecasts: [TargetForecast], night: Astro.Night?, lat: Double, lon: Double,
                          minAltitude: Double, horizon: Horizon = .flat, maxTargets: Int = 3, now: Date = Date()) -> [PlanItem] {
        var start = now
        if let dusk = night?.duskStart, now < dusk { start = dusk }
        guard let end = night?.dawnEnd, end > start.addingTimeInterval(1800) else { return [] }
        let total = end.timeIntervalSince(start)
        let n = max(1, min(maxTargets, Int(total / 3600 / 1.2)))
        let slot = total / Double(n)
        var used = Set<String>()
        var items: [PlanItem] = []
        for i in 0..<n {
            let s = start.addingTimeInterval(Double(i) * slot)
            let e = s.addingTimeInterval(slot)
            let best = forecasts
                .filter { !used.contains($0.id) && $0.score > 0 }
                .compactMap { f -> (TargetForecast, Double)? in
                    let alt = Ephemeris.altitudeOfFixed(raJ2000: f.object.raHours, decJ2000: f.object.decDeg, lat: lat, lon: lon)
                    let clear = SkyLimit(minAltitude: minAltitude, horizon: horizon).clearFixed(raJ2000: f.object.raHours, decJ2000: f.object.decDeg, lat: lat, lon: lon)
                    let a1 = alt(s), a2 = alt(s.addingTimeInterval(slot / 2)), a3 = alt(e)
                    guard clear(s), clear(s.addingTimeInterval(slot / 2)), clear(e) else { return nil }
                    return (f, f.score + (a1 + a2 + a3) / 9)
                }
                .max { $0.1 < $1.1 }
            guard let (f, _) = best else { continue }
            used.insert(f.id)
            var item = PlanItem(name: f.object.id, raHours: f.object.raHours, decDeg: f.object.decDeg,
                                minutes: max(30, (slot / 60 * 0.85 / 10).rounded() * 10))
            item.lpFilter = [.nebula, .snr, .planetary].contains(f.object.kind)
            item.notBefore = i == 0 ? nil : s
            items.append(item)
        }
        return items
    }
}

extension SeestarClient {
    /// Apunta a unas coordenadas J2000 y, si llega bien, empieza a apilar con ese nombre.
    /// Devuelve un mensaje para mostrar al usuario.
    func gotoAndStack(name: String, raJ2000: Double, decJ2000: Double, lpFilter: Bool) async -> (ok: Bool, message: String) {
        let now = Astro.precessFromJ2000(raHours: raJ2000, decDeg: decJ2000, to: Date())
        do {
            let ok = try await gotoAndWait(name: name, raHours: now.ra, decDeg: now.dec, lpFilter: lpFilter)
            guard ok else { return (false, tr("El GoTo a %@ no terminó bien (¿nubes o poca altura?).", "\(name)")) }
            try await setTargetName(name)
            try await startStack()
            return (true, tr("Apilando %@.", "\(name)"))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
