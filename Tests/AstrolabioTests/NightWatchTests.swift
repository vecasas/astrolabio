import Testing
import Foundation
@testable import Astrolabio

@MainActor
struct NightWatchTests {
    /// Campo de estrellas gaussianas sobre fondo con ruido.
    private func field(sigma: Double, width: Int = 400, height: Int = 300, stars: Int = 40, seed: UInt64 = 7) -> [Float] {
        var rng = seed
        func rand() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        var img = [Float](repeating: 0.05, count: width * height)
        for i in img.indices { img[i] += Float((rand() - 0.5) * 0.004) }
        for _ in 0..<stars {
            let cx = 20 + rand() * Double(width - 40), cy = 20 + rand() * Double(height - 40)
            let amp = 0.2 + rand() * 0.5
            for y in max(0, Int(cy) - 12)...min(height - 1, Int(cy) + 12) {
                for x in max(0, Int(cx) - 12)...min(width - 1, Int(cx) + 12) {
                    let r2 = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                    img[y * width + x] += Float(amp * exp(-r2 / (2 * sigma * sigma)))
                }
            }
        }
        return img
    }

    @Test func testHFRGrowsWithBlur() throws {
        let sharp = try #require(StarMetrics.measure(field(sigma: 1.2), width: 400, height: 300))
        let soft = try #require(StarMetrics.measure(field(sigma: 2.4), width: 400, height: 300))
        #expect(sharp.stars >= 10)
        // Para una gaussiana, HFR ≈ 1,18·σ.
        #expect(abs(sharp.hfr - 1.18 * 1.2) < 0.35)
        #expect(soft.hfr > sharp.hfr * 1.6)
    }

    @Test func testNoStarsGivesNil() {
        let flat = [Float](repeating: 0.1, count: 400 * 300)
        #expect(StarMetrics.measure(flat, width: 400, height: 300) == nil)
        #expect(StarMetrics.measure([], width: 400, height: 300) == nil)         // datos incompletos
        #expect(StarMetrics.measure(flat, width: 10, height: 10) == nil)
    }

    @Test func testFocusWatch() {
        var w = FocusWatch(threshold: 0.3)
        for h in [2.0, 2.1, 2.0] { #expect(w.add(hfr: h, target: "M 31") == .learning) }
        #expect(w.add(hfr: 2.1, target: "M 31") == .ok)
        _ = w.add(hfr: 2.9, target: "M 31")
        _ = w.add(hfr: 3.0, target: "M 31")
        if case .softening(let pct) = w.add(hfr: 3.1, target: "M 31") { #expect(pct >= 40) } else { Issue.record("debería avisar") }
        // Al cambiar de objeto se aprende otra referencia.
        #expect(w.add(hfr: 3.1, target: "M 45") == .learning)
        // Un empeoramiento pequeño en píxeles no avisa aunque sea un 30 % (estrellas muy finas).
        var tiny = FocusWatch(threshold: 0.3)
        for h in [1.0, 1.0, 1.0, 1.4, 1.4, 1.4] { _ = tiny.add(hfr: h, target: "X") }
        #expect(tiny.add(hfr: 1.4, target: "X") == .ok)
    }

    @Test func testDewRisk() {
        #expect(DewRisk.level(temperature: 10, dewPoint: 2) == .low)
        #expect(DewRisk.level(temperature: 10, dewPoint: 7) == .possible)
        #expect(DewRisk.level(temperature: 10, dewPoint: 8.5) == .high)
    }

    private let meteoalarmJSON = #"""
    {"warnings":[{"alert":{"identifier":"x1","info":[
      {"area":[{"areaDesc":"Campiña de Madrid","geocode":[{"value":"ES281","valueName":"EMMA_ID"}]},{"areaDesc":"Sierra de Madrid","geocode":[{"value":"ES282","valueName":"EMMA_ID"}]}],
       "event":"Aviso de tormentas de nivel amarillo","headline":"Aviso de tormentas de nivel amarillo. Campiña de Madrid",
       "onset":"2026-11-08T18:00:00-00:00","expires":"2026-11-08T23:59:59-00:00",
       "parameter":[{"value":"2; yellow; Moderate","valueName":"awareness_level"},{"value":"3; thunderstorm","valueName":"awareness_type"}]},
      {"area":[{"areaDesc":"Campiña de Madrid"}],"event":"Yellow thunderstorm warning","onset":"2026-11-08T18:00:00-00:00","expires":"2026-11-08T23:59:59-00:00",
       "parameter":[{"value":"2; yellow; Moderate","valueName":"awareness_level"},{"value":"3; thunderstorm","valueName":"awareness_type"}]}]}},
     {"alert":{"identifier":"x2","info":[
      {"area":[{"areaDesc":"Campiña de Madrid"}],"event":"Aviso de niebla","headline":"Niebla","onset":"2026-11-08T18:00:00-00:00","expires":"2026-11-09T06:00:00-00:00",
       "parameter":[{"value":"2; yellow; Moderate","valueName":"awareness_level"},{"value":"4; fog","valueName":"awareness_type"}]}]}},
     {"alert":{"info":[{"area":[],"event":"roto"}]}},
     {"basura":true}]}
    """#

    @Test func testMeteoAlarmParsing() {
        let w = MeteoAlarm.parse(Data(meteoalarmJSON.utf8))
        #expect(w.count == 3)                               // dos zonas de tormenta + niebla; el resto se ignora
        #expect(MeteoAlarm.areas(w) == ["Campiña de Madrid", "Sierra de Madrid"])
        let storm = w.first { $0.type == 3 && $0.area == "Campiña de Madrid" }
        #expect(storm?.level == 2 && storm?.isDangerous == true)
        #expect(w.first { $0.type == 4 }?.isDangerous == false)   // la niebla no obliga a recoger
        #expect(MeteoAlarm.parse(Data("no es json".utf8)).isEmpty)
    }

    @Test func testStormGuard() {
        let w = MeteoAlarm.parse(Data(meteoalarmJSON.utf8)).filter { $0.area == "Campiña de Madrid" }
        let during = ISO8601DateFormatter().date(from: "2026-11-08T20:00:00Z")!
        let before = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        #expect(StormGuard.reason(warnings: w, hours: [], now: during) != nil)
        #expect(StormGuard.reason(warnings: w, hours: [], now: before) == nil)
        func hour(_ t: Date, code: Int = 0, rain: Double = 0, gust: Double = 0) -> WeatherHour {
            WeatherHour(time: t, cloudCover: 50, lowClouds: 0, humidity: 70, temperature: 10, dewPoint: 5, wind: 10,
                        precipitation: rain, gusts: gust, weatherCode: code)
        }
        #expect(StormGuard.reason(warnings: [], hours: [hour(before.addingTimeInterval(1800), code: 95)], now: before) != nil)
        #expect(StormGuard.reason(warnings: [], hours: [hour(before.addingTimeInterval(1800), rain: 1.2)], now: before) != nil)
        #expect(StormGuard.reason(warnings: [], hours: [hour(before.addingTimeInterval(1800), gust: 62)], now: before) != nil)
        #expect(StormGuard.reason(warnings: [], hours: [hour(before.addingTimeInterval(1800), rain: 0.1, gust: 30)], now: before) == nil)
        // Una tormenta dentro de 5 horas no recoge el telescopio todavía.
        #expect(StormGuard.reason(warnings: [], hours: [hour(before.addingTimeInterval(5 * 3600), code: 96)], now: before) == nil)
    }

    @Test func testRainRadar() {
        let json = #"{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":1794128400,"path":"/v2/radar/abc"},{"time":1,"path":"../evil"}]}}"#
        let r = RainRadar.parse(Data(json.utf8))
        #expect(r.host == "https://tilecache.rainviewer.com")
        #expect(r.frames.count == 1)                                   // rutas raras descartadas
        #expect(RainRadar.parse(Data(#"{"host":"http://inseguro","radar":{"past":[]}}"#.utf8)).host.isEmpty)
        let t = RainRadar.tile(lat: 0, lon: 0, zoom: 1)
        #expect(t.x == 1 && t.y == 1)
        let madrid = RainRadar.tile(lat: 40.42, lon: -3.70, zoom: 6)
        #expect(madrid.x == 31 && madrid.y == 24)
    }
}
