import Testing
import Foundation
@testable import Astrolabio

/// SGP4 comparado con los vectores de verificación de Vallado et al. (2006), satélite 00005.
struct SGP4Tests {
    static let l1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
    static let l2 = "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667"

    @Test func testParsesTLE() throws {
        let t = try #require(TLE.parse(name: "VANGUARD 1", line1: Self.l1, line2: Self.l2))
        #expect(abs(t.ecc - 0.1859667) < 1e-9 && abs(t.bstar - 0.28098e-4) < 1e-12)
        #expect(TLE.parse(name: "x", line1: Self.l1.replacingOccurrences(of: "4753", with: "4754"), line2: Self.l2) == nil)  // suma mal
        #expect(TLE.parseList("VANGUARD 1\n\(Self.l1)\n\(Self.l2)\nbasura\n").count == 1)
    }

    @Test(arguments: [
        (0.0, SIMD3(7022.46529266, -1400.08296755, 0.03995155), SIMD3(1.893841015, 6.405893759, 4.534807250)),
        (360.0, SIMD3(-7154.03120202, -3783.17682504, -3536.19412294), SIMD3(4.741887409, -4.151817765, -2.093935425)),
    ])
    func testMatchesValladoVectors(minutes: Double, r: SIMD3<Double>, v: SIMD3<Double>) throws {
        let t = try #require(TLE.parse(name: "VANGUARD 1", line1: Self.l1, line2: Self.l2))
        let s = try #require(SGP4(t))
        let out = try #require(s.propagate(minutes: minutes))
        let dr = out.r - r, dv = out.v - v
        #expect((dr * dr).sum().squareRoot() < 1.0, "Δr \(dr)")          // < 1 km
        #expect((dv * dv).sum().squareRoot() < 0.001, "Δv \(dv)")
    }
}

/// Pasos de la ISS sobre Madrid comparados con Skyfield (biblioteca de referencia en Python, SGP4 oficial de Vallado).
struct SatellitePassTests {
    static let iss1 = "1 25544U 98067A   26312.17541007  .00012511  00000+0  23266-3 0  9990"
    static let iss2 = "2 25544  51.6320 307.5621 0007219   1.6306 358.4705 15.49256954594075"
    /// (salida sobre 10°, altura máxima, puesta bajo 10°) del 8 al 13 de noviembre de 2026.
    static let reference: [(Double, Double, Double)] = [
        (1794101573, 24.7, 1794101915), (1794107364, 50.9, 1794107759), (1794167515, 66.8, 1794167913), (1794173377, 21.6, 1794173698), (1794179314, 12.3, 1794179492), (1794185121, 19.0, 1794185422), (1794190899, 89.7, 1794191305), (1794251070, 36.6, 1794251442), (1794256887, 29.1, 1794257245), (1794262825, 12.9, 1794263021), (1794268668, 15.6, 1794268923), (1794274439, 53.2, 1794274837), (1794280291, 17.2, 1794280567), (1794334644, 21.2, 1794334956), (1794340403, 43.0, 1794340789), (1794346326, 14.4, 1794346560), (1794352210, 13.5, 1794352422), (1794357982, 34.2, 1794358357), (1794363795, 29.1, 1794364152), (1794418258, 12.3, 1794418433), (1794423928, 71.5, 1794424328), (1794429824, 17.2, 1794430102), (1794435743, 12.4, 1794435924), (1794441525, 24.4, 1794441866), (1794447316, 51.7, 1794447710), (1794507464, 65.5, 1794507860), (1794513324, 21.7, 1794513645), (1794519262, 12.2, 1794519437), (1794525068, 18.8, 1794525367),
    ]

    @Test func testISSPassesMatchReferenceWithinAMinute() throws {
        let t = try #require(TLE.parse(name: "ISS (ZARYA)", line1: Self.iss1, line2: Self.iss2))
        let start = Date(timeIntervalSince1970: 1794096000)          // 8 nov 2026, 0 h UTC
        let ours = Satellites.passes(t, from: start, days: 5, lat: 40.4168, lon: -3.7038, onlyVisible: false)
        #expect(ours.count == Self.reference.count)
        for (rise, alt, set) in Self.reference {
            let p = ours.min { abs($0.rise.timeIntervalSince1970 - rise) < abs($1.rise.timeIntervalSince1970 - rise) }
            let m = try #require(p)
            #expect(abs(m.rise.timeIntervalSince1970 - rise) < 60, "salida \(rise)")
            #expect(abs(m.set.timeIntervalSince1970 - set) < 60, "puesta \(set)")
            #expect(abs(m.maxAltitude - alt) < 1.5, "altura \(alt) frente a \(m.maxAltitude)")
        }
        // Los visibles son un subconjunto: de noche y con la ISS iluminada.
        let visible = Satellites.passes(t, from: start, days: 5, lat: 40.4168, lon: -3.7038)
        #expect(visible.count < ours.count && visible.allSatisfy(\.sunlit))
    }

    @Test func testCrossingIsDetected() throws {
        let t = try #require(TLE.parse(name: "ISS (ZARYA)", line1: Self.iss1, line2: Self.iss2))
        // Objetivo: donde está la ISS en la culminación del paso casi cenital (89,7°).
        let peak = Date(timeIntervalSince1970: 1794191102)
        let s = try #require(SGP4(t)?.position(at: peak))
        let aa = Satellites.altAz(teme: s, date: peak, lat: 40.4168, lon: -3.7038)
        #expect(aa.alt > 85)
        // De altura/acimut a AR/Dec J2000 (iterando la precesión).
        let radec = Self.raDec(alt: aa.alt, az: aa.az, date: peak, lat: 40.4168, lon: -3.7038)
        let hits = SatelliteStore.crossings([t], raHours: radec.ra, decDeg: radec.dec,
                                            from: peak.addingTimeInterval(-600), to: peak.addingTimeInterval(600),
                                            lat: 40.4168, lon: -3.7038)
        // Este paso es de madrugada con la ISS iluminada o no: solo se exige si lo está.
        if Satellites.sunlitAt(t, peak) {
            #expect(hits.count == 1 && hits[0].sep < 0.5 && abs(hits[0].at.timeIntervalSince(peak)) < 5)
        }
        let c = try #require(Satellites.closestApproach(t, raHours: radec.ra, decDeg: radec.dec,
                                                        from: peak.addingTimeInterval(-600), to: peak.addingTimeInterval(600),
                                                        lat: 40.4168, lon: -3.7038))
        #expect(c.sep < 0.5 && abs(c.at.timeIntervalSince(peak)) < 5)
        // Lejos del objetivo no hay aviso.
        #expect(SatelliteStore.crossings([t], raHours: radec.ra + 6, decDeg: -radec.dec, from: peak.addingTimeInterval(-600),
                                         to: peak.addingTimeInterval(600), lat: 40.4168, lon: -3.7038).isEmpty)
    }

    static func raDec(alt: Double, az: Double, date: Date, lat: Double, lon: Double) -> (ra: Double, dec: Double) {
        let d = Astro.deg
        let dec = asin(sin(alt * d) * sin(lat * d) + cos(alt * d) * cos(lat * d) * cos(az * d))
        let h = atan2(-sin(az * d) * cos(alt * d), sin(alt * d) * cos(lat * d) - cos(alt * d) * sin(lat * d) * cos(az * d))
        let raDate = Astro.norm360(Astro.localSiderealTime(date, longitude: lon) - h / d) / 15
        // Precesión inversa: se corrige con lo que añade precessFromJ2000.
        var ra = raDate, de = dec / d
        for _ in 0..<3 {
            let p = Astro.precessFromJ2000(raHours: ra, decDeg: de, to: date)
            ra -= p.ra - raDate; de -= p.dec - dec / d
        }
        return (ra, de)
    }

    @Test func testStoreAcceptsOnlyCelestrakHTTPS() {
        let text = "ISS (ZARYA)\n\(Self.iss1)\n\(Self.iss2)\n".data(using: .utf8)!
        #expect(SatelliteStore.accept(text, from: URL(string: "https://celestrak.org/x")) != nil)
        #expect(SatelliteStore.accept(text, from: URL(string: "http://celestrak.org/x")) == nil)
        #expect(SatelliteStore.accept(text, from: URL(string: "https://evil.example/x")) == nil)
        #expect(SatelliteStore.accept(Data(count: SatelliteStore.maxBytes + 1), from: URL(string: "https://celestrak.org/x")) == nil)
        #expect(SatelliteStore.accept("<html>".data(using: .utf8)!, from: URL(string: "https://celestrak.org/x")) == nil)
        let dup = TLE.parseList("X\n\(Self.iss1)\n\(Self.iss2)\nISS (ZARYA)\n\(Self.iss1)\n\(Self.iss2)\n")
        #expect(SatelliteStore.merge(dup).count == 1)
    }
}
