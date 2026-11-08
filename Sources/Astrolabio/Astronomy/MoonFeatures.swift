import Foundation

/// Accidente de la superficie lunar con su posición selenográfica (nombres de la UAI, de dominio público).
struct MoonFeature: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case crater, mare, mountain, valley, landing
        var name: String {
            switch self {
            case .crater: return tr("Cráter")
            case .mare: return tr("Mar")
            case .mountain: return tr("Montes")
            case .valley: return tr("Valle o falla")
            case .landing: return tr("Alunizaje")
            }
        }
    }
    var id: String { name }
    let name: String
    let lat: Double         // ° norte
    let lon: Double         // ° este (selenográfico)
    let sizeKm: Double
    let kind: Kind
}

/// Geometría de la Luna vista desde la Tierra: libración y punto subsolar.
struct MoonGeometry {
    /// Libración óptica: punto subterrestre (°). l > 0 deja ver más del borde este.
    let l: Double
    let b: Double
    /// Punto subsolar (°).
    let l0: Double
    let b0: Double
    /// Colongitud del Sol (°): 0 ≈ cuarto creciente, 90 llena, 180 cuarto menguante, 270 nueva.
    var colongitude: Double { Astro.norm360(90 - l0) }
}

enum MoonFeatures {
    static let all: [MoonFeature] = {
        typealias F = MoonFeature
        return [
            // Mares
            F(name: "Mare Imbrium", lat: 32.8, lon: -15.6, sizeKm: 1146, kind: .mare),
            F(name: "Mare Serenitatis", lat: 28.0, lon: 17.5, sizeKm: 707, kind: .mare),
            F(name: "Mare Tranquillitatis", lat: 8.5, lon: 31.4, sizeKm: 873, kind: .mare),
            F(name: "Mare Crisium", lat: 17.0, lon: 59.1, sizeKm: 556, kind: .mare),
            F(name: "Mare Fecunditatis", lat: -7.8, lon: 51.3, sizeKm: 909, kind: .mare),
            F(name: "Mare Nectaris", lat: -15.2, lon: 35.5, sizeKm: 339, kind: .mare),
            F(name: "Mare Nubium", lat: -21.3, lon: -16.6, sizeKm: 715, kind: .mare),
            F(name: "Mare Humorum", lat: -24.4, lon: -38.6, sizeKm: 389, kind: .mare),
            F(name: "Oceanus Procellarum", lat: 18.4, lon: -57.4, sizeKm: 2568, kind: .mare),
            F(name: "Mare Frigoris", lat: 56.0, lon: 1.4, sizeKm: 1446, kind: .mare),
            F(name: "Mare Vaporum", lat: 13.3, lon: 3.6, sizeKm: 245, kind: .mare),
            F(name: "Sinus Iridum", lat: 44.1, lon: -31.5, sizeKm: 236, kind: .mare),
            F(name: "Sinus Medii", lat: 2.4, lon: 1.7, sizeKm: 335, kind: .mare),
            // Cráteres
            F(name: "Tycho", lat: -43.3, lon: -11.4, sizeKm: 85, kind: .crater),
            F(name: "Copernicus", lat: 9.6, lon: -20.1, sizeKm: 96, kind: .crater),
            F(name: "Kepler", lat: 8.1, lon: -38.0, sizeKm: 31, kind: .crater),
            F(name: "Aristarchus", lat: 23.7, lon: -47.4, sizeKm: 40, kind: .crater),
            F(name: "Plato", lat: 51.6, lon: -9.4, sizeKm: 101, kind: .crater),
            F(name: "Clavius", lat: -58.4, lon: -14.4, sizeKm: 225, kind: .crater),
            F(name: "Ptolemaeus", lat: -9.2, lon: -1.8, sizeKm: 153, kind: .crater),
            F(name: "Alphonsus", lat: -13.4, lon: -3.2, sizeKm: 108, kind: .crater),
            F(name: "Arzachel", lat: -18.2, lon: -1.9, sizeKm: 97, kind: .crater),
            F(name: "Archimedes", lat: 29.7, lon: -4.0, sizeKm: 81, kind: .crater),
            F(name: "Aristoteles", lat: 50.2, lon: 17.4, sizeKm: 87, kind: .crater),
            F(name: "Eudoxus", lat: 44.3, lon: 16.3, sizeKm: 67, kind: .crater),
            F(name: "Theophilus", lat: -11.4, lon: 26.4, sizeKm: 99, kind: .crater),
            F(name: "Cyrillus", lat: -13.2, lon: 24.0, sizeKm: 98, kind: .crater),
            F(name: "Catharina", lat: -18.1, lon: 23.6, sizeKm: 99, kind: .crater),
            F(name: "Langrenus", lat: -8.9, lon: 61.1, sizeKm: 132, kind: .crater),
            F(name: "Petavius", lat: -25.3, lon: 60.4, sizeKm: 177, kind: .crater),
            F(name: "Gassendi", lat: -17.5, lon: -40.1, sizeKm: 101, kind: .crater),
            F(name: "Grimaldi", lat: -5.2, lon: -68.6, sizeKm: 173, kind: .crater),
            F(name: "Schickard", lat: -44.3, lon: -54.6, sizeKm: 206, kind: .crater),
            F(name: "Longomontanus", lat: -49.6, lon: -21.9, sizeKm: 145, kind: .crater),
            F(name: "Maginus", lat: -50.5, lon: -6.3, sizeKm: 194, kind: .crater),
            F(name: "Posidonius", lat: 31.9, lon: 29.9, sizeKm: 95, kind: .crater),
            F(name: "Atlas", lat: 46.7, lon: 44.4, sizeKm: 87, kind: .crater),
            F(name: "Hercules", lat: 46.7, lon: 39.1, sizeKm: 69, kind: .crater),
            F(name: "Endymion", lat: 53.6, lon: 57.0, sizeKm: 123, kind: .crater),
            F(name: "Cleomedes", lat: 27.6, lon: 55.5, sizeKm: 125, kind: .crater),
            F(name: "Proclus", lat: 16.1, lon: 46.8, sizeKm: 28, kind: .crater),
            F(name: "Stöfler", lat: -41.1, lon: 6.0, sizeKm: 126, kind: .crater),
            F(name: "Walther", lat: -33.0, lon: 0.7, sizeKm: 128, kind: .crater),
            F(name: "Purbach", lat: -25.5, lon: -1.9, sizeKm: 115, kind: .crater),
            F(name: "Regiomontanus", lat: -28.4, lon: -0.6, sizeKm: 126, kind: .crater),
            F(name: "Albategnius", lat: -11.2, lon: 4.0, sizeKm: 136, kind: .crater),
            F(name: "Hipparchus", lat: -5.1, lon: 5.2, sizeKm: 138, kind: .crater),
            F(name: "Manilius", lat: 14.5, lon: 9.1, sizeKm: 39, kind: .crater),
            F(name: "Menelaus", lat: 16.3, lon: 16.0, sizeKm: 26, kind: .crater),
            F(name: "Plinius", lat: 15.4, lon: 23.6, sizeKm: 41, kind: .crater),
            F(name: "Eratosthenes", lat: 14.5, lon: -11.3, sizeKm: 58, kind: .crater),
            F(name: "Bullialdus", lat: -20.7, lon: -22.2, sizeKm: 61, kind: .crater),
            F(name: "Mersenius", lat: -21.5, lon: -49.2, sizeKm: 84, kind: .crater),
            F(name: "Pitatus", lat: -29.8, lon: -13.5, sizeKm: 106, kind: .crater),
            F(name: "Wargentin", lat: -49.6, lon: -60.2, sizeKm: 84, kind: .crater),
            F(name: "Janssen", lat: -44.9, lon: 40.8, sizeKm: 190, kind: .crater),
            F(name: "Maurolycus", lat: -41.8, lon: 14.0, sizeKm: 114, kind: .crater),
            F(name: "Piccolomini", lat: -29.7, lon: 32.2, sizeKm: 88, kind: .crater),
            F(name: "Fracastorius", lat: -21.5, lon: 33.2, sizeKm: 124, kind: .crater),
            F(name: "Fra Mauro", lat: -6.0, lon: -17.0, sizeKm: 101, kind: .crater),
            F(name: "Hevelius", lat: 2.2, lon: -67.6, sizeKm: 115, kind: .crater),
            F(name: "Riccioli", lat: -3.0, lon: -74.6, sizeKm: 139, kind: .crater),
            F(name: "Pythagoras", lat: 63.5, lon: -63.0, sizeKm: 142, kind: .crater),
            // Montes, valles y fallas
            F(name: "Montes Apenninus", lat: 18.9, lon: -3.7, sizeKm: 600, kind: .mountain),
            F(name: "Montes Alpes", lat: 46.4, lon: -0.8, sizeKm: 281, kind: .mountain),
            F(name: "Montes Caucasus", lat: 38.4, lon: 10.0, sizeKm: 445, kind: .mountain),
            F(name: "Mons Pico", lat: 45.8, lon: -8.9, sizeKm: 25, kind: .mountain),
            F(name: "Mons Piton", lat: 40.6, lon: -1.1, sizeKm: 25, kind: .mountain),
            F(name: "Vallis Alpes", lat: 48.5, lon: 3.2, sizeKm: 155, kind: .valley),
            F(name: "Rupes Recta", lat: -22.1, lon: -7.8, sizeKm: 110, kind: .valley),
            F(name: "Vallis Schröteri", lat: 26.2, lon: -50.8, sizeKm: 168, kind: .valley),
            // Alunizajes
            F(name: "Apollo 11", lat: 0.67, lon: 23.47, sizeKm: 1, kind: .landing),
            F(name: "Apollo 15", lat: 26.13, lon: 3.63, sizeKm: 1, kind: .landing),
            F(name: "Apollo 17", lat: 20.19, lon: 30.77, sizeKm: 1, kind: .landing),
        ]
    }()

    // MARK: Geometría (Meeus, cap. 53, libración óptica)

    /// Longitud y latitud eclípticas geocéntricas de la Luna (°), misma teoría que `Astro.moon`.
    static func moonEcliptic(_ date: Date) -> (lambda: Double, beta: Double) {
        let t = (Astro.julianDay(date) - 2451545.0) / 36525
        func s(_ x: Double) -> Double { sin(x * Astro.deg) }
        let lambda = 218.32 + 481267.881 * t
            + 6.29 * s(135.0 + 477198.87 * t) - 1.27 * s(259.3 - 413335.36 * t)
            + 0.66 * s(235.7 + 890534.22 * t) + 0.21 * s(269.9 + 954397.74 * t)
            - 0.19 * s(357.5 + 35999.05 * t) - 0.11 * s(186.5 + 966404.03 * t)
        let beta = 5.13 * s(93.3 + 483202.02 * t) + 0.28 * s(228.2 + 960400.89 * t)
            - 0.28 * s(318.3 + 6003.15 * t) - 0.17 * s(217.6 - 407332.21 * t)
        return (Astro.norm360(lambda), beta)
    }

    private static func libration(lambda: Double, beta: Double, t: Double) -> (l: Double, b: Double) {
        let d = Astro.deg
        let inc = 1.54242 * d
        let node = (125.0445479 - 1934.1362891 * t) * d
        let f = (93.2720950 + 483202.0175233 * t) * d
        let w = lambda * d - node, be = beta * d
        let a = atan2(sin(w) * cos(be) * cos(inc) - sin(be) * sin(inc), cos(w) * cos(be))
        var l = Astro.norm360((a - f) / d)
        if l > 180 { l -= 360 }
        let b = asin(-sin(w) * cos(be) * sin(inc) - sin(be) * cos(inc)) / d
        return (l, b)
    }

    static func geometry(_ date: Date) -> MoonGeometry {
        let t = (Astro.julianDay(date) - 2451545.0) / 36525
        let m = moonEcliptic(date)
        let earth = libration(lambda: m.lambda, beta: m.beta, t: t)
        // Dirección del Sol vista desde la Luna (casi la opuesta a la de la Tierra vista desde el Sol).
        let sunL = Astro.sun(date).lambda
        let ratio = Ephemeris.moonDistanceKm(date) / 149_597_870.7
        let lh = sunL + 180 + ratio * Astro.rad * cos(m.beta * Astro.deg) * sin((sunL - m.lambda) * Astro.deg)
        let bh = ratio * m.beta
        let sun = libration(lambda: Astro.norm360(lh), beta: bh, t: t)
        return MoonGeometry(l: earth.l, b: earth.b, l0: sun.l, b0: sun.b)
    }

    // MARK: Proyección y luz

    static func vector(lat: Double, lon: Double) -> SIMD3<Double> {
        let p = lat * Astro.deg, l = lon * Astro.deg
        return SIMD3(cos(p) * sin(l), sin(p), cos(p) * cos(l))    // x este, y norte, z hacia longitud 0
    }

    /// Ejes de la vista (x derecha, y arriba, z hacia el observador) en el sistema de la Luna, con norte arriba.
    static func viewBasis(_ g: MoonGeometry) -> (x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) {
        let l = g.l * Astro.deg, b = g.b * Astro.deg
        return (SIMD3(cos(l), 0, -sin(l)), SIMD3(-sin(b) * sin(l), cos(b), -sin(b) * cos(l)), SIMD3(cos(b) * sin(l), sin(b), cos(b) * cos(l)))
    }

    /// Posición en el disco (−1…1, x a la derecha, y arriba) y si está en la cara visible.
    static func project(_ f: MoonFeature, _ g: MoonGeometry) -> (x: Double, y: Double, visible: Bool) {
        let v = vector(lat: f.lat, lon: f.lon), e = viewBasis(g)
        let z = (v * e.z).sum()
        return ((v * e.x).sum(), (v * e.y).sum(), z > 0.05)
    }

    /// Altura del Sol sobre el horizonte local del accidente (°). Negativa: de noche en la Luna.
    static func sunAltitude(_ f: MoonFeature, _ g: MoonGeometry) -> Double {
        let s = vector(lat: g.b0, lon: g.l0), v = vector(lat: f.lat, lon: f.lon)
        return asin(max(-1, min(1, (s * v).sum()))) * Astro.rad
    }

    /// El Sol en la vista (para el dibujo): x derecha, y arriba, z hacia el observador.
    static func sunInView(_ g: MoonGeometry) -> SIMD3<Double> {
        let s = vector(lat: g.b0, lon: g.l0), e = viewBasis(g)
        return SIMD3((s * e.x).sum(), (s * e.y).sum(), (s * e.z).sum())
    }

    enum Light: Equatable { case terminator, lit, dark, hidden }

    /// Cómo se ve esta noche: junto al terminador (sombras largas: el mejor momento), iluminado, a oscuras u oculto.
    static func light(_ f: MoonFeature, _ g: MoonGeometry) -> Light {
        guard project(f, g).visible else { return .hidden }
        let h = sunAltitude(f, g)
        // Los mares se aprecian mejor con más luz; los cráteres y montes, con el Sol bajo.
        let limit = f.kind == .mare ? 25.0 : 12.0
        if h < 0 { return .dark }
        return h <= limit ? .terminator : .lit
    }

    /// Los mejores accidentes para mirar ahora: visibles y cerca del terminador, de mayor a menor.
    static func bestNow(_ g: MoonGeometry, limit: Int = 10) -> [MoonFeature] {
        all.filter { $0.kind != .mare && light($0, g) == .terminator }
            .sorted { $0.sizeKm > $1.sizeKm }
            .prefix(limit).map { $0 }
    }
}
