import Testing
import Foundation
import PDFKit
@testable import Astrolabio

@MainActor
struct ReportTests {
    private func record(_ target: String, _ start: Date, minutes: Double, frames: Int) -> ObservationRecord {
        ObservationRecord(target: target, start: start, end: start.addingTimeInterval(minutes * 60), frames: frames, exposureMs: 10_000)
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    @Test func testGroupsByNightNewestFirst() {
        let recs = [
            record("M 31", date("2026-11-01T22:00:00"), minutes: 30, frames: 180),
            record("M 45", date("2026-11-02T01:30:00"), minutes: 20, frames: 120),   // misma noche (pasada la medianoche)
            record("M 42", date("2026-11-03T23:00:00"), minutes: 10, frames: 60),
        ]
        let nights = NightSession.group(recs)
        #expect(nights.count == 2)
        #expect(nights[0].targets == ["M 42"])
        #expect(nights[1].targets == ["M 31", "M 45"])
        #expect(nights[1].frames == 300)
        #expect(abs(nights[1].integrationMinutes - 50) < 0.01)
    }

    @Test func testOldHistoryJSONStillDecodes() throws {
        // Formato de la versión 1.0, sin los campos nuevos.
        let json = #"[{"id":"6F1C4D2E-9C1B-4E55-8B7A-1D2E3F4A5B6C","target":"M 31","start":"2026-11-01T21:00:00Z","end":"2026-11-01T21:30:00Z","frames":180,"exposureMs":10000}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let recs = try d.decode([ObservationRecord].self, from: Data(json.utf8))
        #expect(recs.count == 1)
        #expect(recs[0].gain == nil && recs[0].weather == nil)
        #expect(recs[0].coordinates != nil)            // del catálogo
    }

    @Test func testReportContentAndPDF() throws {
        Loc.shared.setLanguage(.es)
        var r = record("M 31", date("2026-11-01T22:00:00"), minutes: 30, frames: 180)
        r.gain = 80; r.lpFilter = true; r.dropped = 4; r.ditherEnabled = true; r.ditherPixels = 50; r.ditherInterval = 10
        r.focusPosition = 1620; r.batteryStart = 92; r.batteryEnd = 81; r.firmware = "4.43"; r.device = "Seestar S50"
        r.weather = WeatherSnapshot(cloudCover: 12, temperature: 8.5, dewPoint: 2.1, humidity: 64, wind: 7)
        r.events = (0..<120).map { "22:\(String(format: "%02d", $0 % 60))  [Sesión] evento \($0)" }
        let night = NightSession.group([r])[0]
        let doc = ReportDocument.make(night, site: ("Casa", 40.48, -3.36))
        #expect(doc.summary.contains { $0.label == "Integración total" && $0.value == "30 min" })
        #expect(doc.conditions.contains { $0.label == "Nubes" && $0.value == "12 %" })
        #expect(doc.objects.first?.rows.contains { $0.label == "Filtro LP" && $0.value == "Sí" } == true)
        #expect(doc.objects.first?.rows.contains { $0.label == "Fotogramas apilados" && $0.value.contains("4") } == true)
        #expect(doc.device.contains { $0.value == "92 % / 81 %" })

        let data = ReportPDF.render(doc)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 2)                      // 120 eventos no caben en una página
        let text = pdf.string ?? ""
        #expect(text.contains("Astrolabio"))
        #expect(text.contains("M 31"))
        #expect(text.contains("Informe de sesión"))
        let page = try #require(pdf.page(at: 0))
        #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 0.5)   // A4
    }

    @Test func testReportTranslated() {
        defer { Loc.shared.setLanguage(.es) }
        Loc.shared.setLanguage(.en)
        let night = NightSession.group([record("M 42", date("2026-11-03T23:00:00"), minutes: 10, frames: 60)])[0]
        let doc = ReportDocument.make(night)
        #expect(doc.title != "Informe de sesión")
        #expect(doc.summary.first?.label != "Fecha")
    }
}
