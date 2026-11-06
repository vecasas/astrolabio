import Foundation

/// Cálculos astronómicos de baja precisión (suficientes para planificar y apuntar: el
/// Seestar corrige el error final con resolución de placa).
enum Astro {
    static let deg = Double.pi / 180
    static let rad = 180 / Double.pi

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }

    static func norm360(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Tiempo sidéreo local en grados.
    static func localSiderealTime(_ date: Date, longitude: Double) -> Double {
        let jd = julianDay(date)
        let t = (jd - 2451545.0) / 36525
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933 * t * t
        return norm360(gmst + longitude)
    }

    /// Altura y acimut (grados; acimut desde el norte hacia el este).
    static func altAz(raHours: Double, decDeg: Double, date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double) {
        let lst = localSiderealTime(date, longitude: lon)
        let ha = (lst - raHours * 15) * deg
        let d = decDeg * deg, p = lat * deg
        let sinAlt = sin(d) * sin(p) + cos(d) * cos(p) * cos(ha)
        let alt = asin(max(-1, min(1, sinAlt)))
        let y = -sin(ha) * cos(d)
        let x = sin(d) * cos(p) - cos(d) * cos(ha) * sin(p)
        let az = norm360(atan2(y, x) * rad)
        return (alt * rad, az)
    }

    /// Precesión aproximada de J2000 a la fecha (método de Meeus de baja precisión).
    static func precessFromJ2000(raHours: Double, decDeg: Double, to date: Date) -> (ra: Double, dec: Double) {
        let years = (julianDay(date) - 2451545.0) / 365.25
        let a = raHours * 15 * deg, d = decDeg * deg
        let m = 3.07496, n = 1.33621, nDeg = 20.0431
        let dRaSec = (m + n * sin(a) * tan(d)) * years           // segundos de tiempo
        let dDecArcsec = nDeg * cos(a) * years                   // segundos de arco
        var ra = raHours + dRaSec / 3600
        if ra < 0 { ra += 24 }
        if ra >= 24 { ra -= 24 }
        return (ra, decDeg + dDecArcsec / 3600)
    }

    /// Separación angular en grados.
    static func separation(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let a1 = ra1 * 15 * deg, a2 = ra2 * 15 * deg, d1 = dec1 * deg, d2 = dec2 * deg
        let c = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(a1 - a2)
        return acos(max(-1, min(1, c))) * rad
    }

    static func obliquity(_ jd: Double) -> Double {
        23.439291 - 0.0130042 * (jd - 2451545.0) / 36525
    }

    static func eclipticToEquatorial(lambda: Double, beta: Double, jd: Double) -> (ra: Double, dec: Double) {
        let e = obliquity(jd) * deg, l = lambda * deg, b = beta * deg
        let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
        let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
        return (norm360(ra * rad) / 15, dec * rad)
    }

    // MARK: Sol

    static func sun(_ date: Date) -> (ra: Double, dec: Double, lambda: Double) {
        let n = julianDay(date) - 2451545.0
        let L = norm360(280.460 + 0.9856474 * n)
        let g = norm360(357.528 + 0.9856003 * n) * deg
        let lambda = L + 1.915 * sin(g) + 0.020 * sin(2 * g)
        let eq = eclipticToEquatorial(lambda: lambda, beta: 0, jd: julianDay(date))
        return (eq.ra, eq.dec, norm360(lambda))
    }

    // MARK: Luna

    static func moon(_ date: Date) -> (ra: Double, dec: Double, illumination: Double, lambda: Double) {
        let jd = julianDay(date)
        let t = (jd - 2451545.0) / 36525
        func s(_ x: Double) -> Double { sin(x * deg) }
        let lambda = 218.32 + 481267.881 * t
            + 6.29 * s(135.0 + 477198.87 * t) - 1.27 * s(259.3 - 413335.36 * t)
            + 0.66 * s(235.7 + 890534.22 * t) + 0.21 * s(269.9 + 954397.74 * t)
            - 0.19 * s(357.5 + 35999.05 * t) - 0.11 * s(186.5 + 966404.03 * t)
        let beta = 5.13 * s(93.3 + 483202.02 * t) + 0.28 * s(228.2 + 960400.89 * t)
            - 0.28 * s(318.3 + 6003.15 * t) - 0.17 * s(217.6 - 407332.21 * t)
        let eq = eclipticToEquatorial(lambda: norm360(lambda), beta: beta, jd: jd)
        let sunL = sun(date).lambda
        let elong = acos(cos((norm360(lambda) - sunL) * deg) * cos(beta * deg))
        let illum = (1 - cos(elong)) / 2
        return (eq.ra, eq.dec, illum, norm360(lambda))
    }

    /// Edad de la Luna en días (0 = nueva) y nombre de la fase.
    static func moonPhase(_ date: Date) -> (age: Double, name: String) {
        let m = moon(date).lambda, s = sun(date).lambda
        let angle = norm360(m - s)
        let age = angle / 360 * 29.530588
        let name: String
        switch angle {
        case ..<10, 350...: name = tr("Luna nueva")
        case ..<80: name = tr("Creciente")
        case ..<100: name = tr("Cuarto creciente")
        case ..<170: name = tr("Gibosa creciente")
        case ..<190: name = tr("Luna llena")
        case ..<260: name = tr("Gibosa menguante")
        case ..<280: name = tr("Cuarto menguante")
        default: name = tr("Menguante")
        }
        return (age, name)
    }

    // MARK: Planetas (elementos keplerianos aproximados de JPL, 1800–2050)

    struct Elements {
        let a, e, i, L, w, node: (Double, Double)
    }

    static let planetElements: [String: Elements] = [
        "Mercurio": Elements(a: (0.38709927, 0.00000037), e: (0.20563593, 0.00001906), i: (7.00497902, -0.00594749),
                             L: (252.25032350, 149472.67411175), w: (77.45779628, 0.16047689), node: (48.33076593, -0.12534081)),
        "Venus": Elements(a: (0.72333566, 0.00000390), e: (0.00677672, -0.00004107), i: (3.39467605, -0.00078890),
                          L: (181.97909950, 58517.81538729), w: (131.60246718, 0.00268329), node: (76.67984255, -0.27769418)),
        "Tierra": Elements(a: (1.00000261, 0.00000562), e: (0.01671123, -0.00004392), i: (-0.00001531, -0.01294668),
                           L: (100.46457166, 35999.37244981), w: (102.93768193, 0.32327364), node: (0, 0)),
        "Marte": Elements(a: (1.52371034, 0.00001847), e: (0.09339410, 0.00007882), i: (1.84969142, -0.00813131),
                          L: (-4.55343205, 19140.30268499), w: (-23.94362959, 0.44441088), node: (49.55953891, -0.29257343)),
        "Júpiter": Elements(a: (5.20288700, -0.00011607), e: (0.04838624, -0.00013253), i: (1.30439695, -0.00183714),
                            L: (34.39644051, 3034.74612775), w: (14.72847983, 0.21252668), node: (100.47390909, 0.20469106)),
        "Saturno": Elements(a: (9.53667594, -0.00125060), e: (0.05386179, -0.00050991), i: (2.48599187, 0.00193609),
                            L: (49.95424423, 1222.49362201), w: (92.59887831, -0.41897216), node: (113.66242448, -0.28867794)),
        "Urano": Elements(a: (19.18916464, -0.00196176), e: (0.04725744, -0.00004397), i: (0.77263783, -0.00242939),
                          L: (313.23810451, 428.48202785), w: (170.95427630, 0.40805281), node: (74.01692503, 0.04240589)),
        "Neptuno": Elements(a: (30.06992276, 0.00026291), e: (0.00859048, 0.00005105), i: (1.77004347, 0.00035372),
                            L: (-55.12002969, 218.45945325), w: (44.96476227, -0.32241464), node: (131.78422574, -0.00508664)),
    ]

    static let planetNames = ["Mercurio", "Venus", "Marte", "Júpiter", "Saturno", "Urano", "Neptuno"]

    private static func heliocentric(_ el: Elements, t: Double) -> (Double, Double, Double) {
        let a = el.a.0 + el.a.1 * t
        let e = el.e.0 + el.e.1 * t
        let i = (el.i.0 + el.i.1 * t) * deg
        let L = el.L.0 + el.L.1 * t
        let w = el.w.0 + el.w.1 * t
        let node = (el.node.0 + el.node.1 * t) * deg
        let argPeri = (w - el.node.0 - el.node.1 * t) * deg
        var M = norm360(L - w)
        if M > 180 { M -= 360 }
        let Mr = M * deg
        var E = Mr + e * sin(Mr)
        for _ in 0..<8 { E -= (E - e * sin(E) - Mr) / (1 - e * cos(E)) }
        let xp = a * (cos(E) - e)
        let yp = a * sqrt(1 - e * e) * sin(E)
        let x = (cos(argPeri) * cos(node) - sin(argPeri) * sin(node) * cos(i)) * xp
            + (-sin(argPeri) * cos(node) - cos(argPeri) * sin(node) * cos(i)) * yp
        let y = (cos(argPeri) * sin(node) + sin(argPeri) * cos(node) * cos(i)) * xp
            + (-sin(argPeri) * sin(node) + cos(argPeri) * cos(node) * cos(i)) * yp
        let z = (sin(argPeri) * sin(i)) * xp + (cos(argPeri) * sin(i)) * yp
        return (x, y, z)
    }

    /// Posición geocéntrica aparente aproximada (RA en horas, Dec en grados) y distancia en UA.
    static func planet(_ name: String, date: Date) -> (ra: Double, dec: Double, distance: Double)? {
        guard let el = planetElements[name], let earth = planetElements["Tierra"] else { return nil }
        let jd = julianDay(date)
        let t = (jd - 2451545.0) / 36525
        let p = heliocentric(el, t: t)
        let e = heliocentric(earth, t: t)
        let x = p.0 - e.0, y = p.1 - e.1, z = p.2 - e.2
        let dist = sqrt(x * x + y * y + z * z)
        let lambda = norm360(atan2(y, x) * rad)
        let beta = atan2(z, sqrt(x * x + y * y)) * rad
        let eq = eclipticToEquatorial(lambda: lambda, beta: beta, jd: jd)
        // Los elementos están referidos a J2000: se precesan a la fecha.
        let now = precessFromJ2000(raHours: eq.ra, decDeg: eq.dec, to: date)
        return (now.ra, now.dec, dist)
    }

    // MARK: Noche

    struct Night {
        let duskStart: Date?        // fin del crepúsculo astronómico (Sol a -18°)
        let dawnEnd: Date?          // inicio del crepúsculo de la mañana
        let sunset: Date?
        let sunrise: Date?
        let nauticalDusk: Date?
        let nauticalDawn: Date?
    }

    /// Calcula la noche que empieza en el día de `date` (de mediodía a mediodía).
    static func night(for date: Date, lat: Double, lon: Double) -> Night {
        let cal = Calendar.current
        var noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        if date < noon && cal.component(.hour, from: date) < 12 {
            // Antes de mediodía: la noche "actual" es la que empezó ayer.
            noon = cal.date(byAdding: .day, value: -1, to: noon) ?? noon
        }
        let step: TimeInterval = 120
        var prevAlt = sunAltitude(noon, lat: lat, lon: lon)
        var sunset: Date?, sunrise: Date?, dusk: Date?, dawn: Date?, nDusk: Date?, nDawn: Date?
        var tm = noon.addingTimeInterval(step)
        let end = noon.addingTimeInterval(24 * 3600)
        while tm <= end {
            let alt = sunAltitude(tm, lat: lat, lon: lon)
            func crossed(_ h: Double) -> (down: Bool, up: Bool) {
                (prevAlt >= h && alt < h, prevAlt < h && alt >= h)
            }
            if crossed(-0.833).down && sunset == nil { sunset = tm }
            if crossed(-12).down && nDusk == nil { nDusk = tm }
            if crossed(-18).down && dusk == nil { dusk = tm }
            if crossed(-18).up && dawn == nil && dusk != nil { dawn = tm }
            if crossed(-12).up && nDawn == nil && nDusk != nil { nDawn = tm }
            if crossed(-0.833).up && sunrise == nil && sunset != nil { sunrise = tm }
            prevAlt = alt
            tm = tm.addingTimeInterval(step)
        }
        return Night(duskStart: dusk, dawnEnd: dawn, sunset: sunset, sunrise: sunrise,
                     nauticalDusk: nDusk, nauticalDawn: nDawn)
    }

    static func sunAltitude(_ date: Date, lat: Double, lon: Double) -> Double {
        let s = sun(date)
        return altAz(raHours: s.ra, decDeg: s.dec, date: date, lat: lat, lon: lon).alt
    }

    static func isDark(_ date: Date, lat: Double, lon: Double, sunLimit: Double = -18) -> Bool {
        sunAltitude(date, lat: lat, lon: lon) < sunLimit
    }

    // MARK: Formato

    static func formatRA(_ hours: Double) -> String {
        var h = hours.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        let totalSec = Int((h * 3600).rounded())
        return String(format: "%02dh %02dm %02ds", totalSec / 3600, (totalSec / 60) % 60, totalSec % 60)
    }

    static func formatDec(_ deg: Double) -> String {
        let sign = deg < 0 ? "-" : "+"
        let totalSec = Int((abs(deg) * 3600).rounded())
        return String(format: "%@%02d° %02d′ %02d″", sign, totalSec / 3600, (totalSec / 60) % 60, totalSec % 60)
    }

    /// Acepta "05 34 31.9", "05:34:31.9", "5h34m31.9s" o un número decimal de horas.
    static func parseRA(_ text: String) -> Double? {
        parseSexagesimal(text).map { v in v }
    }

    static func parseDec(_ text: String) -> Double? {
        parseSexagesimal(text)
    }

    private static func parseSexagesimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let negative = trimmed.hasPrefix("-")
        let cleaned = trimmed.map { c -> Character in
            ("0"..."9").contains(c) || c == "." || c == "," ? c : " "
        }
        let parts = String(cleaned).replacingOccurrences(of: ",", with: ".")
            .split(separator: " ").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var v = parts[0]
        if parts.count > 1 { v += parts[1] / 60 }
        if parts.count > 2 { v += parts[2] / 3600 }
        return negative ? -v : v
    }
}
