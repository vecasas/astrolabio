import Foundation
import Testing
@testable import Astrolabio

// Swift Testing (incluido en las Command Line Tools); XCTest solo existe con Xcode completo.

struct AstroTests {
    @Test func testJulianDayJ2000() {
        // 1 de enero de 2000, 12:00 UT = JD 2451545.0
        let d = Date(timeIntervalSince1970: 946_728_000)
        #expect(abs(Astro.julianDay(d) - 2451545.0) < 1e-6)
    }

    @Test func testPolarisIsAtLatitude() {
        // La Polar está casi a la altura de la latitud del observador.
        let alt = Astro.altAz(raHours: 2.53, decDeg: 89.26, date: Date(), lat: 40.48, lon: -3.36).alt
        #expect(abs(alt - 40.48) < 1.2)
    }

    @Test func testCatalogHasMessier() {
        #expect(Catalog.objects.filter { $0.id.hasPrefix("M") && !$0.id.contains(" ") }.count == 110)
        #expect(Catalog.find("m31") != nil)
        #expect(Catalog.find("Gran Nebulosa de Orion") != nil)
    }

    @Test func testParseCoordinates() throws {
        #expect(abs(try #require(Astro.parseRA("05h 35m 24s")) - 5.59) < 0.001)
        #expect(abs(try #require(Astro.parseDec("-05° 27′ 00″")) - (-5.45)) < 0.001)
    }

    @Test func testMosaicPanelsCount() {
        let p = Planner.mosaicPanels(centerRA: 21, centerDec: 44, columns: 3, rows: 2, overlapPercent: 15, fov: (0.73, 1.29))
        #expect(p.count == 6)
    }

    @Test func testStoredZip() {
        // ZIP con un archivo "raw_data" sin comprimir que contiene "hola".
        var z = Data()
        func u16(_ v: Int) { z.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        let name = Array("raw_data".utf8), body = Array("hola".utf8)
        u32(0x04034B50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(body.count); u32(body.count)
        u16(name.count); u16(0); z.append(contentsOf: name); z.append(contentsOf: body)
        let cd = z.count
        u32(0x02014B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(body.count); u32(body.count)
        u16(name.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); z.append(contentsOf: name)
        let cdSize = z.count - cd
        u32(0x06054B50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cd); u16(0)
        #expect(ZipReader.extract("raw_data", from: z) == Data(body))
    }

    @Test func testPrecessionAtJ2000IsIdentity() {
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        let p = Astro.precessFromJ2000(raHours: 5.59, decDeg: -5.45, to: j2000)
        #expect(abs(p.ra - 5.59) < 1e-4)
        #expect(abs(p.dec - (-5.45)) < 1e-3)
    }

    @Test func testPrecessionMovesSlowly() {
        // En 26 años la precesión mueve unos 20′ como mucho cerca del ecuador.
        let d = Date(timeIntervalSince1970: 1_793_000_000)   // finales de 2026
        let p = Astro.precessFromJ2000(raHours: 5.59, decDeg: -5.45, to: d)
        let sep = Astro.separation(ra1: 5.59, dec1: -5.45, ra2: p.ra, dec2: p.dec)
        #expect(sep > 0.1 && sep < 0.5)
    }

    @Test func testFormatParseRoundTrip() throws {
        let ra = try #require(Astro.parseRA(Astro.formatRA(13.4983)))
        let dec = try #require(Astro.parseDec(Astro.formatDec(47.195)))
        #expect(abs(ra - 13.4983) < 0.01)
        #expect(abs(dec - 47.195) < 0.05)
    }

    @Test func testMoonIlluminationInRange() {
        let m = Astro.moon(Date())
        #expect(m.illumination >= 0 && m.illumination <= 1)
        #expect(m.dec > -30 && m.dec < 30)
    }

    @Test func testPlanetsResolve() throws {
        for name in Astro.planetNames {
            let p = try #require(Astro.planet(name, date: Date()))
            #expect(p.ra >= 0 && p.ra < 24)
            #expect(abs(p.dec) < 30)
        }
    }
}

@MainActor
struct HistoryTests {
    private func tempLog() -> ObservationLog {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_history_\(UUID().uuidString).json")
        return ObservationLog(storage: url)
    }

    @Test func testImportFromAlbumNames() {
        // Estructura real de get_albums (resumida) de un Seestar S50 Pro.
        let reply: JSONObject = ["result": ["path": "MyWorks", "list": [
            ["group_name": "SolarSystem", "files": [
                ["name": "Lunar_video", "thn": "Lunar_video/Video_Stacked_Lunar_20261030-232121_thn.jpg", "count": 26],
            ]],
            ["group_name": "DeepSky", "files": [
                ["name": "M45_sub", "thn": "M45_sub/Light_M45_30.0s_IRCUT_20261105-231119_thn.jpg", "count": 63],
                ["name": "IC 434", "thn": "IC 434/Stacked_2_IC 434_30.0s_LP_20261031-002108_thn.jpg", "count": 1],
                ["name": "NGC 1981_mosaic", "thn": "NGC 1981_mosaic/Stacked_8_mosaic_NGC 1981_30.0s_IRCUT_20261031-001229_thn.jpg", "count": 1],
                ["name": "M 42", "thn": "M 42/Stacked_18_M 42_30.0s_LP_20261031-000015_thn.jpg", "count": 1],
                ["name": "M 45", "thn": "M 45/Stacked_25_M 45_30.0s_IRCUT_20261030-234613_thn.jpg", "count": 1],
            ]],
        ]]]
        let log = tempLog()
        #expect(log.importFromAlbum(reply) == 4)
        #expect(log.importFromAlbum(reply) == 0)          // no duplica
        let m45 = log.records.first { $0.target == "M 45" }
        #expect(m45?.frames == 25)
        #expect(m45?.exposureMs == 30_000)
        #expect(abs((m45?.integrationMinutes ?? 0) - 12.5) < 0.01)
        #expect(log.records.contains { $0.target == "NGC 1981" && $0.frames == 8 })
        #expect(Catalog.find("M 45") != nil)               // se reconoce en el catálogo
    }

    @Test func testLiveStackEventsMakeOneSession() {
        let log = tempLog()
        let t0 = Date()
        for (i, frames) in [3, 4, 5, 6].enumerated() {
            let ev = SeestarEvent(name: "Stack", data: ["Event": "Stack", "state": "working", "stacked_frame": frames, "target_name": "M31"], received: t0)
            log.handleStack(ev, now: t0.addingTimeInterval(Double(i) * 10))
        }
        #expect(log.current?.frames == 6)
        // Otro objeto cierra la sesión anterior y empieza otra.
        log.handleStack(SeestarEvent(name: "Stack", data: ["Event": "Stack", "stacked_frame": 1, "target_name": "M33"], received: t0), now: t0.addingTimeInterval(100))
        #expect(log.records.count == 1)
        #expect(log.records[0].target == "M31")
        #expect(log.current?.target == "M33")
        log.handleStack(SeestarEvent(name: "Stack", data: ["Event": "Stack", "state": "cancel", "target_name": "M33"], received: t0), now: t0.addingTimeInterval(110))
        #expect(log.current == nil)
        #expect(log.records.count == 1)                    // la de 1 fotograma no cuenta
    }

    @Test func testEphemerisPhasesAndRiseSet() {
        let phases = Ephemeris.nextPhases(after: Date(timeIntervalSince1970: 1_793_000_000), count: 4)
        #expect(phases.count == 4)
        for i in 1..<phases.count {
            let gap = phases[i].date.timeIntervalSince(phases[i - 1].date) / 86400
            #expect(gap > 6 && gap < 8.5)
        }
        // La Polar desde 40° N nunca se pone.
        let rs = Ephemeris.riseSet(from: Date(), hours: 24, altitude: Ephemeris.altitudeOfFixed(raJ2000: 2.53, decJ2000: 89.26, lat: 40.4, lon: -3.7))
        #expect(rs.alwaysUp)
        let d = Ephemeris.moonDistanceKm(Date())
        #expect(d > 355_000 && d < 408_000)
        let jup = Ephemeris.magnitude("Júpiter", date: Date())
        #expect(jup != nil && jup! < -1.5 && jup! > -3.2)
    }

    @Test func testPickForMeAndShortPlan() {
        let lat = 40.48, lon = -3.36
        let night = Astro.night(for: Date(timeIntervalSince1970: 1_793_000_000), lat: lat, lon: lon)
        let f = Planner.evaluate(objects: Catalog.objects, night: night, lat: lat, lon: lon, minAltitude: 30,
                                 fov: (0.73, 1.29), weather: [])
        let mid = night.duskStart!.addingTimeInterval(3 * 3600)
        let s = Picker4Me.suggestions(from: f, night: night, style: .best, lat: lat, lon: lon, minAltitude: 30, now: mid)
        #expect(!s.isEmpty)
        let top = s[0]
        #expect(top.altitudeNow >= 30)
        #expect(top.remainingMinutes >= 40)
        let plan = Picker4Me.shortPlan(from: f, night: night, lat: lat, lon: lon, minAltitude: 30, now: mid)
        #expect(!plan.isEmpty)
        #expect(Set(plan.map(\.name)).count == plan.count)
    }
}

struct LiveProcessingTests {
    /// Imagen sintética: fondo con gradiente y dominante, franja ruidosa de 30 px a la derecha.
    private func synthetic() -> LinearImage {
        let w = 400, h = 600
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        var seed: UInt64 = 7
        func noise(_ amp: Float) -> Float {
            // SplitMix64: sin correlaciones entre píxeles vecinos.
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return (Float(z >> 40) / Float(1 << 24) * 2 - 1) * amp
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let grad = Float(y) / Float(h) * 800          // contaminación que crece hacia abajo
                let band = x >= w - 30
                let a: Float = band ? 120 : 40
                r[i] = 18000 + grad * 1.3 + noise(a) + (band ? -200 : 0)
                g[i] = 18000 + grad + noise(a)
                b[i] = 18000 + grad * 0.6 + noise(a) + (band ? 300 : 0)
            }
        }
        return LinearImage(width: w, height: h, r: r, g: g, b: b)
    }

    @Test func testCropsTiltedBorder() {
        // Franja inclinada (rotación de campo): 0 px de ancho arriba y 40 px abajo, a la derecha.
        let w = 400, h = 600
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        var seed: UInt64 = 3
        func noise(_ a: Float) -> Float {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return (Float(z >> 40) / Float(1 << 24) * 2 - 1) * a
        }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let band = x >= w - Int(Double(y) / Double(h) * 40)
            let a: Float = band ? 130 : 40
            r[i] = 18000 + noise(a) + (band ? -250 : 0); g[i] = 18000 + noise(a); b[i] = 18000 + noise(a) + (band ? 300 : 0)
        } }
        let c = ImageProcessing.cropStackEdges(LinearImage(width: w, height: h, r: r, g: g, b: b))
        #expect(c.width <= w - 30)
        #expect(c.width >= w - 90)
        #expect(c.height >= h - 30)
    }

    @Test func testCropsNoisyStackBorder() {
        let img = synthetic()
        let c = ImageProcessing.cropStackEdges(img)
        #expect(c.width <= img.width - 30)          // la franja desaparece
        #expect(c.width >= img.width - 60)          // sin recortar de más
        #expect(c.height >= img.height - 20)
    }

    @Test func testGradientRemovalFlattensAndNeutralizes() {
        var img = ImageProcessing.cropStackEdges(synthetic())
        ImageProcessing.subtractBackgroundModel(&img)
        ImageProcessing.neutralizeBackground(&img)
        func rowMean(_ c: [Float], _ y: Int) -> Float {
            var s: Float = 0
            for x in 0..<img.width { s += c[y * img.width + x] }
            return s / Float(img.width)
        }
        let top = rowMean(img.g, 10), bottom = rowMean(img.g, img.height - 10)
        #expect(abs(top - bottom) < 40)                               // antes: 800
        #expect(abs(rowMean(img.r, 300) - rowMean(img.b, 300)) < 30)  // fondo neutro
        #expect(ImageProcessing.render(img, options: ProcessingOptions()) != nil)
    }
}

struct CaptureAdviceTests {
    @Test func testAdviceByObjectType() {
        let lat = 40.48, lon = -3.36
        let night = Astro.night(for: Date(timeIntervalSince1970: 1_793_000_000), lat: lat, lon: lon)
        let mid = night.duskStart!.addingTimeInterval(4 * 3600)
        // Pléyades: brillantes → 10 s, sin LP.
        let m45 = CaptureAdvice.make(for: Catalog.find("M45")!, lat: lat, lon: lon, minAltitude: 30, night: night, gain: 80, now: mid)
        #expect(m45.exposureMs == 10_000)
        #expect(!m45.lpFilter)
        // Nebulosa de emisión: LP y 30 s.
        let neb = Catalog.objects.first { $0.kind == .nebula && $0.magnitude > 6 }!
        let a = CaptureAdvice.make(for: neb, lat: lat, lon: lon, minAltitude: 30, night: night, gain: 80, now: mid)
        #expect(a.lpFilter)
        #expect(a.exposureMs == 30_000)
        // Duración entre 20 y 120 min, nunca más que lo que queda de altura útil (salvo el mínimo).
        for adv in [m45, a] {
            #expect(adv.minutes >= 20 && adv.minutes <= 120)
            if adv.remainingMinutes >= 25 { #expect(adv.minutes <= adv.remainingMinutes) }
        }
    }
}
