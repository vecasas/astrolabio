import Testing
import Foundation
@testable import Astrolabio

@MainActor
struct SafetyTests {
    private let madrid = GotoSafety.Limits(latitude: 40.48, longitude: -3.36, minAltitude: 15, minSunSeparation: 30)

    @Test func testBlocksTheSun() {
        let date = Date(timeIntervalSince1970: 1_793_966_400)   // 6 nov 2026, de día
        let sun = Astro.sun(date)
        #expect(GotoSafety.check(raHours: sun.ra, decDeg: sun.dec, date: date, limits: madrid) != nil)
        // Ni siquiera con un límite de 0° se puede apuntar al Sol.
        var noLimit = madrid; noLimit.minSunSeparation = 0; noLimit.minAltitude = -90
        #expect(GotoSafety.check(raHours: sun.ra, decDeg: sun.dec + 10, date: date, limits: noLimit) != nil)
    }

    @Test func testBlocksLowTargetsAndAllowsHighOnes() {
        let date = Date(timeIntervalSince1970: 1_794_002_400)   // 6 nov 2026, 22:00 UTC
        // Polaris: siempre a ~40° en Madrid, lejos del Sol.
        let polaris = Astro.precessFromJ2000(raHours: 2.53, decDeg: 89.26, to: date)
        #expect(GotoSafety.check(raHours: polaris.ra, decDeg: polaris.dec, date: date, limits: madrid) == nil)
        var strict = madrid; strict.minAltitude = 50
        #expect(GotoSafety.check(raHours: polaris.ra, decDeg: polaris.dec, date: date, limits: strict) != nil)
        // Un objeto del hemisferio sur que nunca sale en Madrid.
        #expect(GotoSafety.check(raHours: 6.4, decDeg: -70, date: date, limits: madrid) != nil)
    }

    @Test func testBatteryEstimate() {
        let t0 = Date()
        func rec(_ minutes: Double, _ b1: Int, _ b2: Int) -> ObservationRecord {
            var r = ObservationRecord(target: "M 31", start: t0, end: t0.addingTimeInterval(minutes * 60), frames: 100, exposureMs: 10_000)
            r.batteryStart = b1; r.batteryEnd = b2
            return r
        }
        #expect(BatteryEstimate.drainPerHour([]) == BatteryEstimate.defaultDrainPerHour)
        let drain = BatteryEstimate.drainPerHour([rec(60, 90, 78), rec(120, 80, 56), rec(10, 50, 40)])
        #expect(abs(drain - 12) < 0.01)                   // la de 10 min no cuenta
        #expect(BatteryEstimate.isEnough(battery: 80, charging: false, hours: 4, drainPerHour: 12))
        #expect(!BatteryEstimate.isEnough(battery: 50, charging: false, hours: 4, drainPerHour: 12))
        #expect(BatteryEstimate.isEnough(battery: 5, charging: true, hours: 8, drainPerHour: 12))
        var a = PlanItem(name: "M 31", raHours: 0.7, decDeg: 41, minutes: 120); a.doneSeconds = 3600
        var b = PlanItem(name: "M 45", raHours: 3.8, decDeg: 24, minutes: 60); b.status = .done
        #expect(abs(BatteryEstimate.planHours([a, b]) - 66.0 / 60) < 0.01)
    }

    @Test func testAlertLimiter() {
        var l = AlertLimiter(interval: 1800)
        let t = Date()
        let a1 = l.shouldSend("battery", now: t)
        let a2 = l.shouldSend("battery", now: t.addingTimeInterval(600))
        let a3 = l.shouldSend("storage", now: t.addingTimeInterval(600))
        let a4 = l.shouldSend("battery", now: t.addingTimeInterval(1900))
        #expect(a1 && !a2 && a3 && a4)
    }

    @Test func testHealthIssues() {
        let ok = HealthMonitor.issues(connected: true, battery: 80, charging: false, freeMB: 20_000, planRunning: true, disconnectedFor: 0)
        #expect(ok.isEmpty)
        let low = HealthMonitor.issues(connected: true, battery: 15, charging: false, freeMB: 500, planRunning: false, disconnectedFor: 0)
        #expect(low.map(\.kind) == ["battery", "storage"])
        #expect(HealthMonitor.issues(connected: true, battery: 15, charging: true, freeMB: nil, planRunning: false, disconnectedFor: 0).isEmpty)
        let silent = HealthMonitor.issues(connected: false, battery: nil, charging: false, freeMB: nil, planRunning: true, disconnectedFor: 240)
        #expect(silent.map(\.kind) == ["silent"])
        #expect(HealthMonitor.issues(connected: false, battery: nil, charging: false, freeMB: nil, planRunning: false, disconnectedFor: 900).isEmpty)
    }

    @Test func testRecenterPolicy() {
        let off = RecenterPolicy.offsetArcmin(targetRA: 5.0, targetDec: 20, actualRA: 5.0, actualDec: 20.05)
        #expect(abs(off - 3) < 0.01)
        #expect(RecenterPolicy.decide(offsetArcmin: off, tolerance: 2) == .recenter)
        #expect(RecenterPolicy.decide(offsetArcmin: 1.2, tolerance: 2) == .centered)
        #expect(RecenterPolicy.decide(offsetArcmin: 600, tolerance: 2) == .unreliable)
    }

    @Test func testPlanProgressForResume() {
        #expect(PlanProgress.remainingPerPanel(totalSeconds: 3600, panels: 1, done: 0) == [3600])
        #expect(PlanProgress.remainingPerPanel(totalSeconds: 3600, panels: 4, done: 1200) == [0, 600, 900, 900])
        #expect(PlanProgress.remainingPerPanel(totalSeconds: 3600, panels: 2, done: 4000) == [0, 0])
    }

    @Test func testResumeStateExpires() throws {
        let d = try #require(UserDefaults(suiteName: "astrolabio-tests-\(UUID().uuidString)"))
        let st = SessionRunner.SavedState(startedAt: Date().addingTimeInterval(-3600), options: .init())
        d.set(try JSONEncoder().encode(st), forKey: SessionRunner.stateKey)
        #expect(SessionRunner.pendingResume(defaults: d) == st)
        #expect(SessionRunner.pendingResume(defaults: d, now: Date().addingTimeInterval(20 * 3600)) == nil)
    }

    @Test func testOldPlanJSONStillDecodes() throws {
        let json = #"[{"id":"6F1C4D2E-9C1B-4E55-8B7A-1D2E3F4A5B6C","name":"M 31","raHours":0.71,"decDeg":41.27,"minutes":60,"lpFilter":false,"autofocus":true,"mosaicColumns":1,"mosaicRows":1,"overlapPercent":15,"status":"running","stackedFrames":12}]"#
        let items = try JSONDecoder().decode([PlanItem].self, from: Data(json.utf8))
        #expect(items.first?.doneSeconds == nil)
    }
}
