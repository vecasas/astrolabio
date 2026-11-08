import Testing
import Foundation
@testable import Astrolabio

/// Horizonte propio, línea de tiempo del plan, proyectos y copia de seguridad.
@MainActor
@Suite(.serialized)
struct HorizonPlanTests {
    init() { Notifier.enabled = false }

    @Test func testHorizonInterpolationAndLimits() {
        var h = Horizon.flat
        #expect(h.isFlat)
        h.set(azimuth: 180, altitude: 40)          // un árbol al sur
        #expect(h.altitude(atAzimuth: 180) == 40)
        #expect(h.altitude(atAzimuth: 185) == 20)   // a mitad de camino hacia 190°
        #expect(h.altitude(atAzimuth: 90) == 0)
        h.set(azimuth: 355, altitude: 20)
        #expect(h.altitude(atAzimuth: 359) > 0 && h.altitude(atAzimuth: -2) > 0)   // da la vuelta por el norte
        h.set(azimuth: 0, altitude: 500)
        #expect(h.altitudes[0] == Horizon.maxAltitude)
        #expect(!h.isVisible(altitude: 30, azimuth: 180, minAltitude: 15))
        #expect(h.isVisible(altitude: 30, azimuth: 90, minAltitude: 15))
        #expect(!h.isVisible(altitude: 10, azimuth: 90, minAltitude: 15))       // la altura mínima sigue mandando
        #expect(Horizon(altitudes: [1, 2]).altitudes.count == 36)
        #expect(Horizon(altitudes: [Double.nan] + Array(repeating: 5, count: 40)).altitudes[0] == 0)
    }

    @Test func testHorizonTextRoundTripAndImport() throws {
        var h = Horizon.flat
        h.set(azimuth: 90, altitude: 25)
        #expect(Horizon.parse(h.text()) == h)
        // Otros programas: cualquier paso y separador; los huecos se interpolan.
        let other = try #require(Horizon.parse("# mi horizonte\n0;10\n90,30\n180\t10\n270 30\nbasura\n"))
        #expect(other.altitude(atAzimuth: 45) == 20 && other.altitude(atAzimuth: 315) == 20)
        #expect(Horizon.parse("solo una línea 10 20") == nil)
        #expect(Horizon.parse("") == nil)
    }

    @Test func testPlannerUsesTheHorizon() throws {
        let night = Astro.night(for: ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!, lat: 40.48, lon: -3.36)
        let m42 = try #require(Catalog.find("M42"))
        let open = Planner.evaluate(objects: [m42], night: night, lat: 40.48, lon: -3.36, minAltitude: 15, fov: (0.73, 1.29), weather: [])
        let wall = Horizon(altitudes: (0..<36).map { (9...27).contains($0) ? 60 : 0 })   // muro de 60° entre el E y el O por el sur
        let blocked = Planner.evaluate(objects: [m42], night: night, lat: 40.48, lon: -3.36, minAltitude: 15, fov: (0.73, 1.29), weather: [], horizon: wall)
        #expect(open[0].minutesUsable > 120)
        #expect(blocked[0].minutesUsable < open[0].minutesUsable / 2)
        let limit = SkyLimit(minAltitude: 15, horizon: wall)
        #expect(ObservingLists.usableTonight(m42, night: night, lat: 40.48, lon: -3.36, minAltitude: 15, horizon: limit.horizon)
                < ObservingLists.usableTonight(m42, night: night, lat: 40.48, lon: -3.36, minAltitude: 15))
    }

    @Test func testTimelineSchedule() throws {
        let night = Astro.night(for: ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!, lat: 40.48, lon: -3.36)
        let dusk = try #require(night.duskStart)
        var a = PlanItem(name: "M31", raHours: 0.71, decDeg: 41.27, minutes: 60)
        var b = PlanItem(name: "M42", raHours: 5.59, decDeg: -5.39, minutes: 30)
        b.notBefore = dusk.addingTimeInterval(3 * 3600)                   // espera
        var done = PlanItem(name: "M45", raHours: 3.79, decDeg: 24.1, minutes: 30); done.status = .done
        a.doneSeconds = 30 * 60                                          // ya lleva media hora
        let c = PlanItem(name: "M33", raHours: 1.56, decDeg: 30.66, minutes: 900)   // no cabe en la noche
        let slots = PlanTimeline.schedule([a, done, b, c], night: night, now: dusk.addingTimeInterval(-3600),
                                          limit: SkyLimit(minAltitude: 15), lat: 40.48, lon: -3.36)
        #expect(slots.count == 3)                                       // el hecho no cuenta
        #expect(slots[0].start == dusk)
        #expect(abs(slots[0].end.timeIntervalSince(dusk) - (5 + 30) * 60) < 1)
        #expect(slots[1].start == b.notBefore && slots[1].waitMinutes > 60)
        #expect(slots[2].afterDawn && slots[2].hasWarning)
        #expect(PlanTimeline.snap(13) == 15 && PlanTimeline.snap(-7) == -5)
        let windows = PlanTimeline.visibleWindows(b, from: dusk, to: try #require(night.dawnEnd), limit: SkyLimit(minAltitude: 15), lat: 40.48, lon: -3.36)
        #expect(!windows.isEmpty)
    }

    @Test func testProjectsProgress() {
        let t = Date()
        let recs = [ObservationRecord(target: "M 31", start: t.addingTimeInterval(-86400 * 3), end: t.addingTimeInterval(-86400 * 3 + 3600), frames: 360, exposureMs: 10_000),
                    ObservationRecord(target: "Galaxia de Andrómeda", start: t.addingTimeInterval(-3600), end: t, frames: 180, exposureMs: 10_000),
                    ObservationRecord(target: "M 42", start: t, end: t, frames: 100, exposureMs: 10_000)]
        let p = ProjectStore.progress(of: "M31", in: recs)
        #expect(abs(p.hours - 1.5) < 0.01 && p.nights == 2)
        #expect(p.fraction(of: 3) == 0.5)
        #expect(ProjectStore.minutesForTonight(goalHours: 10, doneHours: 1.5) == 120)
        #expect(ProjectStore.minutesForTonight(goalHours: 2, doneHours: 1.5) == 30)
        #expect(ProjectStore.minutesForTonight(goalHours: 1, doneHours: 1.5) == 0)
        let store = ProjectStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID()).json"))
        store.projects = [Project(objectID: "M31", goalHours: 10)]
        #expect(ProjectStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("proj-otro.json")).projects.isEmpty)
    }

    @Test func testBackupRoundTripNeverIncludesThePEM() throws {
        let d = try #require(UserDefaults(suiteName: "astro-backup-\(UUID())"))
        d.set("/Users/yo/clave.pem", forKey: "pemPath")
        d.set("Casa", forKey: "siteName")
        d.set(40.48, forKey: "latitude")
        d.set(true, forKey: "stormGuard")
        let hz = ["40.480,-3.360": Horizon(altitudes: Array(repeating: 12, count: 36))]
        d.set(try JSONEncoder().encode(hz), forKey: "horizons")
        let rec = ObservationRecord(target: "M 31", start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600), frames: 360, exposureMs: 10_000)
        let b = BackupFile.make(defaults: d, plan: [PlanItem(name: "M42", raHours: 5.59, decDeg: -5.39)],
                                projects: [Project(objectID: "M31", goalHours: 10)], history: [rec])
        let data = try b.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("clave.pem") && !text.contains("pemPath"))
        let back = try BackupFile.decode(data)
        #expect(back.history == [rec] && back.plan.count == 1 && back.projects.first?.goalHours == 10)
        let target = try #require(UserDefaults(suiteName: "astro-restore-\(UUID())"))
        target.set("/otra/clave.pem", forKey: "pemPath")
        back.applySettings(to: target)
        #expect(target.string(forKey: "siteName") == "Casa" && target.double(forKey: "latitude") == 40.48 && target.bool(forKey: "stormGuard"))
        #expect(target.string(forKey: "pemPath") == "/otra/clave.pem")                       // la clave no se toca
        let restored = try JSONDecoder().decode([String: Horizon].self, from: try #require(target.data(forKey: "horizons")))
        #expect(restored == hz)
        #expect(throws: BackupFile.RestoreError.self) { _ = try BackupFile.decode(Data("{}".utf8)) }
        var newer = b; newer.version = 99
        #expect(throws: BackupFile.RestoreError.self) { _ = try BackupFile.decode(try newer.encoded()) }
        // Una copia manipulada con la clave PEM no la escribe.
        var evil = back; evil.settings["pemPath"] = .string("/tmp/mala.pem")
        evil.applySettings(to: target)
        #expect(target.string(forKey: "pemPath") == "/otra/clave.pem")
    }

    /// Plan contra el Seestar simulado: un objeto tapado por el horizonte propio se salta sin apuntar.
    @Test func testRunnerSkipsTargetsBehindTheHorizon() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = SeestarClient()
        c.port = fake.port
        await c.connect(to: "127.0.0.1")
        defer { c.disconnect() }
        let defaults = try #require(UserDefaults(suiteName: "astro-hz-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.endAction = .nothing
        settings.minAltitude = 10
        settings.horizon = Horizon(altitudes: Array(repeating: Horizon.maxAltitude, count: 36))   // tapia altísima en todo el contorno
        let plan = PlanStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).json"))
        var item = PlanItem(name: "Polaris", raHours: 2.53, decDeg: 89.26, minutes: 0.1)    // a ~40° de altura, tapada
        item.autofocus = false
        plan.items = [item]
        let runner = SessionRunner()
        runner.stateDefaults = defaults
        runner.options = .init(waitForDark: false, pauseForClouds: false, stopAtDawn: false)
        runner.start(client: c, settings: settings, plan: plan)
        let end = Date().addingTimeInterval(20)
        while runner.phase != .finished && Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        #expect(runner.phase == .finished)
        #expect(fake.count("iscope_start_view") == 0)
        #expect(runner.messages.contains { $0.contains(tr("%@ está tapado por tu horizonte. Se salta.", "Polaris")) })
    }
}
