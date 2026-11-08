import Testing
import Foundation
@testable import Astrolabio

/// Datos de servicios externos y registro de sesiones a partir de eventos reales.
@MainActor
@Suite(.serialized)
struct DataTests {
    init() { Notifier.enabled = false }

    @Test func testOpenMeteoParsingSkipsMissingHours() {
        let json = #"""
        {"hourly":{"time":["2026-11-08T20:00","2026-11-08T21:00","2026-11-08T22:00","mal"],
          "cloud_cover":[10,null,80,5],"cloud_cover_low":[0,0,null,0],"relative_humidity_2m":[60,61,62,63],
          "temperature_2m":[9.5,9.0,8.4,8],"dew_point_2m":[2,2,null,2],"wind_speed_10m":[5,5,5,5],
          "precipitation":[0,0,1.4,0],"wind_gusts_10m":[10,12,55,10],"weather_code":[0,1,95,0]}}
        """#
        let h = WeatherService.parse(Data(json.utf8))
        #expect(h.count == 2)                                   // la de nubes null y la de fecha rota no cuentan
        #expect(h[0].cloudCover == 10 && h[0].temperature == 9.5)
        #expect(h[1].precipitation == 1.4 && h[1].gusts == 55 && h[1].weatherCode == 95)
        #expect(h[1].dewPoint < h[1].temperature)               // sin punto de rocío no se inventa rocío
        #expect(WeatherService.parse(Data("{}".utf8)).isEmpty)
        #expect(WeatherService.parse(Data("basura".utf8)).isEmpty)
    }

    @Test func testSessionHistoryIsFilledFromRealEvents() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = SeestarClient()
        c.port = fake.port
        await c.connect(to: "127.0.0.1")
        defer { c.disconnect() }
        let log = ObservationLog(storage: FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID()).json"))
        log.attach(to: c, exposureMs: { 10_000 })
        log.contextProvider = {
            SessionContext(siteName: "Prueba", latitude: 40.48, longitude: -3.36, gain: 80,
                           weather: WeatherSnapshot(cloudCover: 5, temperature: 9, dewPoint: 2, humidity: 60, wind: 4), image: { nil })
        }
        for n in [3, 4, 5, 6] {
            fake.emit("Stack", ["state": "working", "stacked_frame": n, "dropped_frame": 1, "target_name": "M 31"])
            try await Task.sleep(for: .milliseconds(150))
        }
        fake.emit("Stack", ["state": "complete", "stacked_frame": 6, "target_name": "M 31"])
        let end = Date().addingTimeInterval(5)
        while log.records.isEmpty && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        let r = try #require(log.records.first)
        #expect(r.target == "M 31" && r.frames == 6 && r.dropped == 1)
        #expect(r.firmware == "6.45" && r.device == "Seestar S50 simulado" && r.batteryStart == 87)
        #expect(r.siteName == "Prueba" && r.weather?.cloudCover == 5 && r.gain == 80)
        #expect(r.coordinates != nil && r.altitudeStart != nil && r.altitudeEnd != nil)
        #expect(r.events != nil)
    }

    @Test func testComputerDiskAlert() {
        let low = HealthMonitor.issues(connected: true, battery: 90, charging: false, freeMB: 50_000, planRunning: false,
                                       disconnectedFor: 0, computerFreeMB: 300)
        #expect(low.map(\.kind) == ["computer-disk"])
        #expect(HealthMonitor.freeMB(at: FileManager.default.temporaryDirectory) ?? 0 > 0)
    }
}
