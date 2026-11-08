import Testing
import Foundation
@testable import Astrolabio

/// Catálogo ampliado, listas Messier y Caldwell, maratón, semana y seguimiento de cometas.
@MainActor
@Suite(.serialized)
struct ListsTests {
    init() { Notifier.enabled = false }

    @Test func testExpandedCatalog() throws {
        #expect(Catalog.objects.count > 1500)
        #expect(Catalog.featured.count < 300)
        #expect(Set(Catalog.objects.map { Catalog.normalize($0.id) }).count == Catalog.objects.count)   // sin repetidos
        let n2903 = try #require(Catalog.find("NGC 2903"))
        #expect(n2903.kind == .galaxy && abs(n2903.raHours - 9.536) < 0.01)
        #expect(Catalog.find("ngc2903")?.id == "NGC 2903")
        #expect(Catalog.find("C14")?.id == "NGC 869")          // Doble Cúmulo
        #expect(Catalog.find("M31")?.name == "Galaxia de Andrómeda")   // la lista principal manda
        for k in Catalog.objects { #expect((0..<24).contains(k.raHours) && (-90...90).contains(k.decDeg)) }
    }

    @Test func testListsResolveEveryObject() {
        #expect(ObservingList.messier.entries.allSatisfy { $0.object != nil })
        let caldwell = ObservingList.caldwell.entries
        #expect(caldwell.count == 109)
        #expect(caldwell.filter { $0.object == nil }.isEmpty, "\(caldwell.filter { $0.object == nil }.map(\.label))")
        #expect(Catalog.caldwellNumber(of: "NGC 869") == 14)
        #expect(Catalog.messierNumber(of: "M 42") == 42 && Catalog.messierNumber(of: "NGC 42") == nil)
    }

    @Test func testImagedStatusAndCSV() {
        let t = Date()
        let recs = [ObservationRecord(target: "M 31", start: t, end: t, frames: 10, exposureMs: 10_000),
                    ObservationRecord(target: "NGC 869", start: t, end: t, frames: 10, exposureMs: 10_000)]
        let imaged = ObservingLists.imaged(recs)
        #expect(imaged.contains("M31") && imaged.contains("NGC 869"))
        let csv = ObservingLists.csv(.caldwell, imaged: imaged, tonight: ["NGC 869": 300])
        #expect(csv.split(separator: "\n").count == 110)
        #expect(csv.contains("\"C14\",\"NGC 869\"") && csv.contains("\"sí\",\"300\""))
    }

    @Test func testMarathonOrder() throws {
        // Luna nueva de marzo de 2027 en Madrid: casi todo el catálogo Messier en una noche.
        let date = ISO8601DateFormatter().date(from: "2027-04-05T12:00:00Z")!
        let night = Astro.night(for: date, lat: 40.48, lon: -3.36)
        let r = Marathon.plan(night: night, lat: 40.48, lon: -3.36, minAltitude: 5, minutesPerObject: 3)
        #expect(r.steps.count + r.missed.count == 110)
        #expect(r.steps.count >= 95)
        #expect(zip(r.steps, r.steps.dropFirst()).allSatisfy { $0.time <= $1.time })
        // Los primeros son los que se ponen por el oeste (M74, M77…) y los últimos los que salen al amanecer (M30…).
        let first = Set(r.steps.prefix(8).map(\.object.id)), last = Set(r.steps.suffix(8).map(\.object.id))
        #expect(!first.isDisjoint(with: ["M74", "M77", "M33", "M31", "M32", "M110", "M76", "M103"]))
        #expect(!last.isDisjoint(with: ["M30", "M2", "M72", "M73", "M15", "M55", "M75"]))
    }

    @Test func testWeekOutlook() {
        #expect(WeekOutlook.score(darkHours: 9, cloud: 0, moon: 0, moonUp: 0) == 100)
        #expect(WeekOutlook.score(darkHours: 9, cloud: 90, moon: 0, moonUp: 0) < 10)
        #expect(WeekOutlook.score(darkHours: 9, cloud: 0, moon: 1, moonUp: 1) < 50)
        #expect(WeekOutlook.score(darkHours: 0, cloud: 0, moon: 0, moonUp: 0) == 0)
        let start = Calendar.current.startOfDay(for: Date())
        let hours = (0..<(7 * 24)).map { h -> WeatherHour in
            let t = start.addingTimeInterval(Double(h) * 3600)
            let clear = (3 * 24 + 12 ..< 4 * 24 + 12).contains(h)     // de mediodía a mediodía: la noche del día 3
            return WeatherHour(time: t, cloudCover: clear ? 0 : 80, lowClouds: 0, humidity: 60, temperature: 10, dewPoint: 2, wind: 5)
        }
        let nights = WeekOutlook.nights(from: start, lat: 40.48, lon: -3.36, weather: hours)
        #expect(nights.count == 7)
        #expect(WeekOutlook.best(nights)?.date == Calendar.current.date(byAdding: .day, value: 3, to: start))
    }

    /// Plan con un cometa: el telescopio vuelve a apuntar cuando se ha movido más de 3′.
    @Test func testCometIsTrackedDuringThePlan() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = SeestarClient()
        c.port = fake.port
        await c.connect(to: "127.0.0.1")
        defer { c.disconnect() }
        let defaults = try #require(UserDefaults(suiteName: "astro-comet-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.endAction = .nothing
        settings.minAltitude = -90                  // el cometa de prueba no tiene por qué estar alto
        let orbit = CometOrbit(name: "C/2099 Z1 (Prueba)", perihelionJD: Astro.julianDay(Date()) + 30, q: 1.0, e: 0.9,
                               argPeri: 90, node: 0, incl: 60, h: 8, g: 4)
        var moved = orbit
        moved = CometOrbit(name: orbit.name, perihelionJD: orbit.perihelionJD, q: 1.0, e: 0.9,
                           argPeri: 90, node: 0.5, incl: 60, h: 8, g: 4)        // medio grado más allá
        var calls = 0
        let plan = PlanStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).json"))
        var item = PlanItem(name: orbit.name, raHours: 0, decDeg: 0, minutes: 0.3)
        item.autofocus = false
        item.comet = orbit.name
        plan.items = [item]
        let runner = SessionRunner()
        runner.stateDefaults = defaults
        runner.chunkSeconds = 6
        runner.cometMinRemaining = 0
        runner.cometOrbit = { _ in calls += 1; return calls <= 2 ? orbit : moved }
        runner.options = .init(waitForDark: false, pauseForClouds: false, stopAtDawn: false)
        runner.start(client: c, settings: settings, plan: plan)
        let end = Date().addingTimeInterval(40)
        while runner.phase != .finished && Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        #expect(runner.phase == .finished)
        #expect(fake.count("iscope_start_view") >= 2)                       // GoTo inicial + seguimiento
        #expect(runner.messages.contains { $0.contains("′") })
    }
}
