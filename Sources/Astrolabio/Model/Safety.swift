import Foundation

/// Límites de seguridad del apuntado: nunca cerca del Sol ni demasiado bajo.
enum GotoSafety {
    /// La distancia mínima al Sol no puede bajar de aquí (no se puede desactivar).
    static let sunSeparationFloor = 15.0

    struct Limits: Equatable {
        var latitude: Double
        var longitude: Double
        var minAltitude: Double = 15
        var minSunSeparation: Double = 30
    }

    /// Devuelve el motivo para no apuntar, o nil si es seguro. Coordenadas de la fecha (RA en horas).
    static func check(raHours: Double, decDeg: Double, date: Date = Date(), limits: Limits) -> String? {
        let sun = Astro.sun(date)
        let sep = Astro.separation(ra1: raHours, dec1: decDeg, ra2: sun.ra, dec2: sun.dec)
        let sunLimit = max(sunSeparationFloor, limits.minSunSeparation)
        if sep < sunLimit {
            return tr("Bloqueado por seguridad: el objetivo está a %@° del Sol (mínimo %@°). Apuntar cerca del Sol puede dañar la cámara.",
                      "\(Int(sep.rounded()))", "\(Int(sunLimit))")
        }
        let alt = Astro.altAz(raHours: raHours, decDeg: decDeg, date: date, lat: limits.latitude, lon: limits.longitude).alt
        if alt < limits.minAltitude {
            return tr("Bloqueado por seguridad: el objetivo está a %@° de altura (mínimo %@°).",
                      "\(Int(alt.rounded()))", "\(Int(limits.minAltitude))")
        }
        return nil
    }
}

struct GotoBlockedError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Estimación de la batería del Seestar a partir de las sesiones anteriores.
enum BatteryEstimate {
    /// Consumo típico si todavía no hay datos propios (%/h, apilando).
    static let defaultDrainPerHour = 15.0
    /// Margen que se quiere conservar al terminar.
    static let reserve = 10.0

    /// Consumo medio por hora medido en sesiones de al menos 20 minutos sin carga.
    static func drainPerHour(_ records: [ObservationRecord]) -> Double {
        let samples = records.compactMap { r -> Double? in
            guard let b1 = r.batteryStart, let b2 = r.batteryEnd, b1 > b2 else { return nil }
            let hours = r.end.timeIntervalSince(r.start) / 3600
            guard hours >= 1.0 / 3 else { return nil }
            return Double(b1 - b2) / hours
        }
        guard !samples.isEmpty else { return defaultDrainPerHour }
        // Media recortada: sin los extremos si hay bastantes muestras.
        let s = samples.sorted()
        let cut = s.count >= 5 ? Array(s.dropFirst().dropLast()) : s
        return min(40, max(3, cut.reduce(0, +) / Double(cut.count)))
    }

    /// Batería prevista al final del plan.
    static func expectedAtEnd(battery: Int, hours: Double, drainPerHour: Double) -> Double {
        Double(battery) - hours * drainPerHour
    }

    static func isEnough(battery: Int, charging: Bool, hours: Double, drainPerHour: Double) -> Bool {
        charging || expectedAtEnd(battery: battery, hours: hours, drainPerHour: drainPerHour) >= reserve
    }

    /// Horas de un plan: tiempo de apilado pendiente más unos minutos por objeto para apuntar y enfocar.
    static func planHours(_ items: [PlanItem]) -> Double {
        let pending = items.filter { $0.status == .pending || $0.status == .running }
        let minutes = pending.reduce(0.0) { $0 + max(0, $1.minutes - ($1.doneSeconds ?? 0) / 60) + 6 }
        return minutes / 60
    }
}

/// Evita repetir el mismo aviso: como mucho uno de cada tipo cada `interval` segundos.
struct AlertLimiter {
    var interval: TimeInterval = 1800
    private(set) var last: [String: Date] = [:]

    init(interval: TimeInterval = 1800) { self.interval = interval }

    mutating func shouldSend(_ kind: String, now: Date = Date()) -> Bool {
        if let t = last[kind], now.timeIntervalSince(t) < interval { return false }
        last[kind] = now
        return true
    }
}

/// Decide si hay que volver a apuntar porque el objeto quedó descentrado.
enum RecenterPolicy {
    /// Más allá de esto, la lectura no es fiable (otro sistema de coordenadas o sin resolver).
    static let implausibleDegrees = 3.0

    /// Separación en minutos de arco entre el objetivo y donde apunta el telescopio.
    static func offsetArcmin(targetRA: Double, targetDec: Double, actualRA: Double, actualDec: Double) -> Double {
        Astro.separation(ra1: targetRA, dec1: targetDec, ra2: actualRA, dec2: actualDec) * 60
    }

    enum Decision: Equatable { case centered, recenter, unreliable }

    static func decide(offsetArcmin: Double, tolerance: Double) -> Decision {
        if offsetArcmin > implausibleDegrees * 60 { return .unreliable }
        return offsetArcmin > tolerance ? .recenter : .centered
    }
}

/// Qué hacer cuando termina el plan.
enum EndAction: String, CaseIterable, Identifiable, Codable {
    case park, shutdown, nothing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .park: return tr("Aparcar el telescopio")
        case .shutdown: return tr("Aparcar y apagar el telescopio")
        case .nothing: return tr("Dejarlo como está")
        }
    }
}

/// Reparte el tiempo ya apilado de un objeto entre sus paneles para poder retomarlo.
enum PlanProgress {
    /// Para cada panel, los segundos que faltan (0 si ya está hecho).
    static func remainingPerPanel(totalSeconds: Double, panels: Int, done: Double) -> [Double] {
        guard panels > 0 else { return [] }
        let per = totalSeconds / Double(panels)
        return (0..<panels).map { i in
            let start = Double(i) * per
            return max(0, min(per, start + per - done))
        }
    }
}
