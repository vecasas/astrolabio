import Testing
import Foundation
@testable import Astrolabio

/// Posiciones de cometas comparadas con las efemérides de JPL Horizons (8 nov 2026, 00:00 UT).
@MainActor
struct CometTests {
    // Líneas reales de CometEls.txt del Minor Planet Center (época 2026-11-08).
    static let mpc = """
    CK25A060  2025 11  8.5202  0.529814  0.995608  132.9562  108.0997  143.6634  20261108   8.6  4.0  C/2025 A6 (Lemmon)                                       MPEC 2026-U70
0012P         2024 04 21.2124  0.781960  0.954751  199.0367  255.8683   74.1442  20261108   5.0  6.0  12P/Pons-Brooks                                          MPEC 2026-TI5
    CK25K010  2025 10  8.4092  0.334370  1.000218  271.0354   97.5695  147.8676  20261108  12.2  4.0  C/2025 K1 (ATLAS)                                        MPEC 2026-TI5
0210P         2025 11 22.7082  0.524602  0.833994  345.9522   93.7986   10.2867  20261108  14.3  4.0  210P/Christensen                                         MPEC 2026-R26
"""

    @Test func testParsesMPCFormat() throws {
        let orbits = Comets.parse(Self.mpc + "\nlínea rota\n" + String(repeating: "x", count: 200))
        #expect(orbits.count == 4)
        let lemmon = try #require(orbits.first { $0.name == "C/2025 A6 (Lemmon)" })
        #expect(abs(lemmon.q - 0.529814) < 1e-6 && abs(lemmon.e - 0.995608) < 1e-6 && lemmon.h == 8.6)
        #expect(orbits.contains { $0.name == "12P/Pons-Brooks" })
    }

    /// Valores de JPL Horizons: RA y Dec astrométricas J2000 (°), r y Δ (UA).
    @Test(arguments: [
        ("C/2025 A6 (Lemmon)", 182.01646, -35.22280, 5.1095, 5.8180),     // elíptica casi parabólica
        ("12P/Pons-Brooks", 247.19108, -30.95300, 9.1006, 9.9759),        // periódica
        ("C/2025 K1 (ATLAS)", 19.97427, 45.29682, 5.6156, 4.7719),        // hiperbólica
        ("210P/Christensen", 232.09659, -13.54302, 3.9361, 4.9102),       // periódica corta
    ])
    func testPositionMatchesJPL(name: String, ra: Double, dec: Double, r: Double, delta: Double) throws {
        let o = try #require(Comets.parse(Self.mpc).first { $0.name == name })
        let date = ISO8601DateFormatter().date(from: "2026-11-08T00:00:00Z")!
        let p = Comets.position(o, date: date)
        let sep = Astro.separation(ra1: p.raHours, dec1: p.decDeg, ra2: ra / 15, dec2: dec)
        #expect(sep < 0.05, "\(name): \(sep * 60)′")            // menos de 3′ (el campo del Seestar mide 44′)
        #expect(abs(p.r - r) < 0.005 && abs(p.delta - delta) < 0.005)
    }

    @Test func testVisibleTonightFiltersByMagnitude() throws {
        let orbits = Comets.parse(Self.mpc)
        let night = Astro.night(for: ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!, lat: 40.48, lon: -3.36)
        let all = Comets.visible(orbits, night: night, lat: 40.48, lon: -3.36, minAltitude: 0, maxMagnitude: 30)
        let bright = Comets.visible(orbits, night: night, lat: 40.48, lon: -3.36, minAltitude: 0, maxMagnitude: 5)
        #expect(all.count >= 1 && bright.isEmpty)
        #expect(all == all.sorted { $0.position.magnitude < $1.position.magnitude })
    }
}
