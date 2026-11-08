import Foundation

// MARK: - La mejor noche de la semana

struct NightOutlook: Identifiable, Equatable {
    var id: Date { date }
    let date: Date              // día en que empieza la noche
    let darkHours: Double       // horas de noche astronómica
    let cloud: Double?          // nubes medias durante la noche (%), nil sin previsión
    let moonIllumination: Double
    let moonUpFraction: Double  // parte de la noche con la Luna sobre el horizonte
    let score: Int              // 0–100
}

enum WeekOutlook {
    /// Valora las próximas `days` noches con la previsión de nubes, la oscuridad y la Luna.
    static func nights(from date: Date = Date(), days: Int = 7, lat: Double, lon: Double, weather: [WeatherHour]) -> [NightOutlook] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)
        return (0..<days).compactMap { k -> NightOutlook? in
            guard let day = cal.date(byAdding: .day, value: k, to: today)?.addingTimeInterval(12 * 3600) else { return nil }
            let n = Astro.night(for: day, lat: lat, lon: lon)
            guard let s = n.duskStart, let e = n.dawnEnd, e > s else {
                return NightOutlook(date: cal.startOfDay(for: day), darkHours: 0, cloud: nil, moonIllumination: 0, moonUpFraction: 0, score: 0)
            }
            var times: [Date] = []
            var t = s
            while t <= e { times.append(t); t = t.addingTimeInterval(1800) }
            let clouds = times.compactMap { WeatherService.cloudCover(at: $0, in: weather) }
            let cloud = clouds.count >= max(1, times.count / 2) ? clouds.reduce(0, +) / Double(clouds.count) : nil
            let mid = s.addingTimeInterval(e.timeIntervalSince(s) / 2)
            let illum = Astro.moon(mid).illumination
            let moonAlt = Ephemeris.moonAltitude(lat: lat, lon: lon)
            let up = Double(times.filter { moonAlt($0) > 0 }.count) / Double(max(1, times.count))
            let hours = e.timeIntervalSince(s) / 3600
            return NightOutlook(date: cal.startOfDay(for: day), darkHours: hours, cloud: cloud, moonIllumination: illum,
                                moonUpFraction: up, score: score(darkHours: hours, cloud: cloud, moon: illum, moonUp: up))
        }
    }

    /// Puntuación de 0 a 100: las nubes mandan; luego la Luna y las horas de oscuridad.
    static func score(darkHours: Double, cloud: Double?, moon: Double, moonUp: Double) -> Int {
        guard darkHours > 0 else { return 0 }
        let clear = 1 - (cloud ?? 50) / 100
        let dark = min(1, darkHours / 9)
        let moonPenalty = 1 - 0.6 * moon * moonUp
        return Int((100 * clear * clear * (0.6 + 0.4 * dark) * moonPenalty).rounded())
    }

    static func best(_ nights: [NightOutlook]) -> NightOutlook? {
        nights.filter { $0.cloud != nil }.max { $0.score < $1.score }
    }
}

// MARK: - Listas Messier y Caldwell

struct ListEntry: Identifiable {
    var id: String { label }
    let label: String           // «M31», «C14»
    let object: DeepSkyObject?
}

enum ObservingList: String, CaseIterable, Identifiable {
    case messier = "Messier"
    case caldwell = "Caldwell"
    var id: String { rawValue }

    /// Elementos de la lista en su orden: (etiqueta «M31» o «C14», objeto).
    var entries: [ListEntry] {
        switch self {
        case .messier: return (1...110).map { ListEntry(label: "M\($0)", object: Catalog.find("M\($0)")) }
        case .caldwell: return (1...109).map { ListEntry(label: "C\($0)", object: Catalog.caldwellObject($0)) }
        }
    }
}

enum ListStatus: String, CaseIterable, Identifiable {
    case all = "Todos"
    case done = "Hechos"
    case pending = "Pendientes"
    case pendingTonight = "Pendientes y visibles esta noche"
    var id: String { rawValue }
}

enum ObservingLists {
    /// Objetos del catálogo con al menos una sesión en el historial (incluido lo importado del álbum).
    static func imaged(_ records: [ObservationRecord]) -> Set<String> {
        var out = Set<String>()
        for r in records {
            if let o = Catalog.find(r.target) { out.insert(o.id) }
        }
        return out
    }

    /// Minutos útiles esta noche por encima de la altura mínima.
    static func usableTonight(_ o: DeepSkyObject, night: Astro.Night, lat: Double, lon: Double, minAltitude: Double,
                              horizon: Horizon = .flat) -> Double {
        guard let s = night.duskStart, let e = night.dawnEnd, e > s else { return 0 }
        let clear = SkyLimit(minAltitude: minAltitude, horizon: horizon).clearFixed(raJ2000: o.raHours, decJ2000: o.decDeg, lat: lat, lon: lon)
        var t = s, minutes = 0.0
        while t <= e { if clear(t) { minutes += 15 }; t = t.addingTimeInterval(900) }
        return minutes
    }

    /// CSV de una lista con su estado.
    static func csv(_ list: ObservingList, imaged: Set<String>, tonight: [String: Double]) -> String {
        var out = "lista,numero,objeto,nombre,tipo,magnitud,fotografiado,minutos_esta_noche\n"
        for e in list.entries {
            var fields: [String] = [list.rawValue, e.label]
            if let o = e.object {
                let done = imaged.contains(o.id) ? "sí" : "no"
                let minutes = Int(tonight[o.id] ?? 0)
                fields += [o.id, o.localizedName, o.kind.label, String(format: "%.1f", o.magnitude), done, String(minutes)]
            } else {
                fields += ["", "", "", "", "no", "0"]
            }
            out += fields.map(CSV.field).joined(separator: ",") + "\n"
        }
        return out
    }
}

// MARK: - Maratón Messier

struct MarathonStep: Identifiable, Equatable {
    var id: String { object.id }
    let object: DeepSkyObject
    let time: Date
    let altitude: Double
}

enum Marathon {
    /// Ordena los 110 Messier para verlos todos en una noche: en cada momento se elige, de los
    /// visibles, el que antes deja de verse (los que se ponen por el oeste al anochecer primero; los
    /// que salen por el este al amanecer, al final). Devuelve el orden y los que no se pueden ver.
    static func plan(night: Astro.Night, lat: Double, lon: Double, minAltitude: Double = 10,
                     minutesPerObject: Double = 4, horizon: Horizon = .flat) -> (steps: [MarathonStep], missed: [DeepSkyObject]) {
        let objects = (1...110).compactMap { Catalog.find("M\($0)") }
        // Para el maratón vale el crepúsculo náutico (el Sol a −12°): los primeros y los últimos están en él.
        guard let start = night.nauticalDusk ?? night.duskStart,
              let end = night.nauticalDawn ?? night.dawnEnd, end > start else {
            return ([], objects)
        }
        let step = 300.0
        var times: [Date] = []
        var t = start
        while t <= end { times.append(t); t = t.addingTimeInterval(step) }
        // Altura de cada objeto en cada instante.
        // Altura útil: la real, o −90 si está detrás del horizonte propio.
        let alts: [[Double]] = objects.map { o in
            let now = Astro.precessFromJ2000(raHours: o.raHours, decDeg: o.decDeg, to: start)
            return times.map { t in
                let aa = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: t, lat: lat, lon: lon)
                return aa.alt >= horizon.altitude(atAzimuth: aa.az) ? aa.alt : -90
            }
        }
        func lastVisible(_ i: Int, from k: Int) -> Int {
            var j = k
            while j + 1 < times.count && alts[i][j + 1] >= minAltitude { j += 1 }
            return j
        }
        var remaining = Set(objects.indices)
        var steps: [MarathonStep] = []
        var clock = start
        while !remaining.isEmpty {
            let k = Int((clock.timeIntervalSince(start) / step).rounded(.down))
            guard k < times.count else { break }
            let visible = remaining.filter { alts[$0][k] >= minAltitude }
            if visible.isEmpty {
                clock = clock.addingTimeInterval(step)
                continue
            }
            // El que antes desaparece; a igualdad, el más bajo.
            let next = visible.min { a, b in
                let la = lastVisible(a, from: k), lb = lastVisible(b, from: k)
                return la != lb ? la < lb : alts[a][k] < alts[b][k]
            }!
            steps.append(MarathonStep(object: objects[next], time: clock, altitude: alts[next][k]))
            remaining.remove(next)
            clock = clock.addingTimeInterval(minutesPerObject * 60)
        }
        let missed = remaining.sorted().map { objects[$0] }
        return (steps, missed)
    }
}
