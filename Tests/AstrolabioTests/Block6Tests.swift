import Testing
import Foundation
@testable import Astrolabio

struct MoonFeatureTests {
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// Meeus, ejemplo 53.a (12 de abril de 1992, 0 h): l = −1,206°, b = +4,194°.
    @Test func testLibrationMatchesMeeus() {
        let g = MoonFeatures.geometry(Self.date(1992, 4, 12))
        print("l \(g.l) b \(g.b) l0 \(g.l0) b0 \(g.b0) c0 \(g.colongitude)")
        #expect(abs(g.l - (-1.206)) < 0.6)
        #expect(abs(g.l0 - 67.89) < 0.5 && abs(g.b0 - 1.46) < 0.2)     // punto subsolar del mismo ejemplo
        #expect(abs(g.b - 4.194) < 0.5)
    }

    @Test func testLibrationStaysInRange() {
        var t = Self.date(2026, 1, 1)
        for _ in 0..<120 {
            let g = MoonFeatures.geometry(t)
            #expect(abs(g.l) < 8.5 && abs(g.b) < 7.2)
            t = t.addingTimeInterval(3 * 86400)
        }
    }

    @Test func testColongitudeFollowsPhase() throws {
        for p in Ephemeris.nextPhases(after: Self.date(2026, 11, 1), count: 4) {
            let c = MoonFeatures.geometry(p.date).colongitude
            let expected = Astro.norm360(p.kind.rawValue - 90 + 360)   // creciente 0, llena 90, menguante 180, nueva 270
            var d = abs(c - expected); if d > 180 { d = 360 - d }
            #expect(d < 10, "\(p.kind) colongitud \(c)")   // difieren en la libración en longitud
        }
    }

    @Test func testTerminatorAndProjection() throws {
        // Cuarto creciente: el Sol sale en el meridiano central; Ptolemaeus (lon −1,8) junto al terminador.
        let fq = try #require(Ephemeris.nextPhases(after: Self.date(2026, 11, 1), count: 4).first { $0.kind == .firstQuarter })
        let g = MoonFeatures.geometry(fq.date)
        let ptol = try #require(MoonFeatures.all.first { $0.name == "Ptolemaeus" })
        #expect(abs(MoonFeatures.sunAltitude(ptol, g)) < 8)
        let crisium = try #require(MoonFeatures.all.first { $0.name == "Mare Crisium" })
        #expect(MoonFeatures.light(crisium, g) == .lit)
        let grimaldi = try #require(MoonFeatures.all.first { $0.name == "Grimaldi" })
        #expect(MoonFeatures.light(grimaldi, g) == .dark)
        // Crisium a la derecha (este), Grimaldi a la izquierda; Plato arriba, Tycho abajo.
        #expect(MoonFeatures.project(crisium, g).x > 0.6 && MoonFeatures.project(grimaldi, g).x < -0.8)
        let plato = MoonFeatures.all.first { $0.name == "Plato" }!, tycho = MoonFeatures.all.first { $0.name == "Tycho" }!
        #expect(MoonFeatures.project(plato, g).y > 0.7 && MoonFeatures.project(tycho, g).y < -0.6)
        #expect(!MoonFeatures.bestNow(g).isEmpty)
        #expect(MoonFeatures.all.count >= 60 && Set(MoonFeatures.all.map(\.name)).count == MoonFeatures.all.count)
    }
}

struct SkyEventTests {
    @Test func testFindsShowersPhasesAndConjunctions() {
        let start = MoonFeatureTests.date(2026, 11, 8)
        let ev = SkyEvents.upcoming(from: start, days: 42, lat: 40.4, lon: -3.7)
        #expect(ev.contains { $0.kind == .meteors && $0.title == tr("Gemínidas") })
        #expect(ev.contains { $0.kind == .meteors && $0.title == tr("Leónidas") })
        #expect(ev.filter { $0.kind == .phase }.count >= 5)
        // La Luna pasa cerca de algún planeta brillante al menos una vez en seis semanas.
        #expect(ev.contains { $0.kind == .conjunction })
        #expect(zip(ev, ev.dropFirst()).allSatisfy { $0.date <= $1.date })
        for e in ev where e.kind != .phase { print(e.date, e.title, e.detail, e.tags) }
    }

    @Test func testMinimaFindsParabolaVertex() {
        let t0 = Date(timeIntervalSince1970: 0)
        let m = SkyEvents.minima(from: t0, to: t0.addingTimeInterval(100), step: 10, limit: 5) { d in
            let x = d.timeIntervalSince(t0) - 43
            return 1 + x * x / 100
        }
        #expect(m.count == 1)
        #expect(abs(m[0].date.timeIntervalSince(t0) - 43) < 0.5 && abs(m[0].value - 1) < 0.01)
    }
}

@MainActor
struct NightSheetTests {
    @Test func testSheetRendersToPNG() throws {
        let defaults = UserDefaults(suiteName: "sheet-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.latitude = 40.4; settings.longitude = -3.7
        let t = try #require(TLE.parse(name: "ISS (ZARYA)", line1: SatellitePassTests.iss1, line2: SatellitePassTests.iss2))
        let start = Date(timeIntervalSince1970: 1794096000)
        // La lista incluye todos los pasos visibles de la ISS (estación tripulada: sin límite de altura).
        let passes = SatellitePassModel.compute([t], lat: 40.4, lon: -3.7, from: start, days: 5)
        #expect(passes == Satellites.passes(t, from: start, days: 5, lat: 40.4, lon: -3.7))
        print("pasos visibles", passes.map { "\($0.rise) \($0.maxAltitude)" })
        let data = NightSheetData.make(settings: settings, tonight: TonightModel(), comets: [], passes: passes, date: start.addingTimeInterval(18 * 3600))
        #expect(data.night.duskStart != nil && !data.events.isEmpty)
        let png = try #require(NightSheetView.png(data))
        #expect(png.count > 50_000)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let moon = try #require(MoonAtlas.snapshot(date: start, place: "Madrid"))
        #expect(moon.count > 50_000)
        // Para revisar a ojo: ASTROLABIO_TEST_OUT=<carpeta> guarda la Luna en cuarto creciente y la hoja.
        if let dir = ProcessInfo.processInfo.environment["ASTROLABIO_TEST_OUT"] {
            let fq = Ephemeris.nextPhases(after: start, count: 4).first { $0.kind == .firstQuarter }!.date
            try MoonAtlas.snapshot(date: fq.addingTimeInterval(-86400), place: "Madrid")?.write(to: URL(fileURLWithPath: dir + "/luna.png"))
            try png.write(to: URL(fileURLWithPath: dir + "/hoja.png"))
        }
    }
}
