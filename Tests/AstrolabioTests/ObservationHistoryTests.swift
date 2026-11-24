import Testing
import Foundation
@testable import Astrolabio

@MainActor
struct ObservationHistoryTests {
    @Test func testOldHistoryJSONStillDecodes() throws {
        // Formato de la versión 1.0, sin los campos nuevos.
        let json = #"[{"id":"6F1C4D2E-9C1B-4E55-8B7A-1D2E3F4A5B6C","target":"M 31","start":"2026-11-01T21:00:00Z","end":"2026-11-01T21:30:00Z","frames":180,"exposureMs":10000}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let recs = try d.decode([ObservationRecord].self, from: Data(json.utf8))
        #expect(recs.count == 1)
        #expect(recs[0].gain == nil && recs[0].weather == nil)
        #expect(recs[0].coordinates != nil)            // del catálogo
    }
}
