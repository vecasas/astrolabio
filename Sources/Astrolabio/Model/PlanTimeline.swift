import Foundation

/// Horario previsto del plan: cuándo empezaría y terminaría cada objeto, con avisos.
struct PlanSlot: Identifiable, Equatable {
    var id: UUID { itemID }
    let itemID: UUID
    let start: Date
    let end: Date
    /// Minutos del tramo en los que el objeto está bajo la altura mínima o detrás del horizonte.
    let hiddenMinutes: Double
    let afterDawn: Bool
    /// Espera antes de empezar (por «no antes de»).
    let waitMinutes: Double

    var hasWarning: Bool { hiddenMinutes >= 10 || afterDawn }
}

enum PlanTimeline {
    /// Minutos que se cuentan por objeto para apuntar y enfocar.
    static let overheadMinutes = 5.0

    /// Coloca los objetos pendientes uno tras otro desde el anochecer (o desde ahora si ya es de noche).
    static func schedule(_ items: [PlanItem], night: Astro.Night, now: Date = Date(), limit: SkyLimit,
                         lat: Double, lon: Double) -> [PlanSlot] {
        guard let dusk = night.duskStart, let dawn = night.dawnEnd else { return [] }
        var cursor = max(now, dusk)
        var out: [PlanSlot] = []
        for item in items where item.status == .pending || item.status == .running {
            let begin = max(cursor, item.notBefore ?? cursor)
            let minutes = max(0, item.minutes - (item.doneSeconds ?? 0) / 60)
            let end = begin.addingTimeInterval((overheadMinutes + minutes) * 60)
            let clear = limit.clearFixed(raJ2000: item.raHours, decJ2000: item.decDeg, lat: lat, lon: lon)
            var hidden = 0.0
            var t = begin.addingTimeInterval(overheadMinutes * 60)
            while t < end { if !clear(t) { hidden += 5 }; t = t.addingTimeInterval(300) }
            out.append(PlanSlot(itemID: item.id, start: begin, end: end, hiddenMinutes: hidden,
                                afterDawn: end > dawn.addingTimeInterval(60), waitMinutes: begin.timeIntervalSince(cursor) / 60))
            cursor = end
        }
        return out
    }

    /// Tramos de la noche en que un objeto se ve (para dibujarlos detrás de su barra).
    static func visibleWindows(_ item: PlanItem, from: Date, to: Date, limit: SkyLimit, lat: Double, lon: Double) -> [ClosedRange<Date>] {
        let clear = limit.clearFixed(raJ2000: item.raHours, decJ2000: item.decDeg, lat: lat, lon: lon)
        var out: [ClosedRange<Date>] = []
        var openAt: Date?
        var t = from
        while t <= to {
            if clear(t) { if openAt == nil { openAt = t } }
            else if let o = openAt { out.append(o...t); openAt = nil }
            t = t.addingTimeInterval(300)
        }
        if let o = openAt { out.append(o...to) }
        return out
    }

    /// Redondea a múltiplos de 5 minutos (para arrastrar las barras).
    static func snap(_ minutes: Double) -> Double { (minutes / 5).rounded() * 5 }
}
