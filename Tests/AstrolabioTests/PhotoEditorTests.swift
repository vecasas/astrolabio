import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Astrolabio

/// Retoque de fotos, trazas de satélite, nombres de objetos, GraXpert y copia del álbum.
@MainActor
@Suite(.serialized)
struct PhotoEditorTests {
    private func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pe-\(UUID())-\(name)") }

    /// Cielo de prueba: fondo con ruido, estrellas y, si se pide, una traza recta.
    private func sky(width: Int = 400, height: Int = 300, trail: Bool = false) -> LinearImage {
        var rng: UInt64 = 42
        func rand() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(rng >> 40) / Float(1 << 24) }
        var l = [Float](repeating: 0, count: width * height)
        for i in l.indices { l[i] = 3000 + (rand() - 0.5) * 400 }
        for _ in 0..<60 {
            let cx = Int(rand() * Float(width - 20)) + 10, cy = Int(rand() * Float(height - 20)) + 10
            for dy in -3...3 { for dx in -3...3 { l[(cy + dy) * width + cx + dx] += 30000 * exp(-Float(dx * dx + dy * dy) / 2) } }
        }
        if trail { for x in 0..<width { let y = 40 + x * 200 / width; for d in -1...1 { l[(y + d) * width + x] += 9000 } } }
        return LinearImage(width: width, height: height, r: l, g: l.map { $0 * 1.05 }, b: l.map { $0 * 0.95 })
    }

    @Test func testFITSRoundTripKeepsOrientation() throws {
        var img = sky(width: 40, height: 30)
        img.r[0] = 60000; img.g[0] = 60000; img.b[0] = 60000          // arriba a la izquierda
        let url = tmp("a.fits")
        try ImageProcessing.saveFITS(img, to: url, object: "M 42")
        let back = try PhotoEditor.load(url)
        #expect(back.isLinear && back.image.width == 40 && back.image.height == 30)
        #expect(back.image.r[0] > 50000 && back.image.r[back.image.r.count - 1] < 20000)
        #expect(back.header["OBJECT"] == "M 42")
        #expect(PhotoEditor.readFITS(Data("SIMPLE  =                    T".utf8)) == nil)    // incompleto
        #expect(throws: (any Error).self) { _ = try PhotoEditor.load(self.tmp("no-existe.fits")) }
    }

    @Test func testEditsBehave() throws {
        let src = EditableImage(image: sky(), isLinear: true, name: "prueba")
        var e = PhotoEdit()
        // El fondo estirado queda cerca del brillo pedido.
        let out = PhotoEditor.stretched(PhotoEditor.process(src, e), isLinear: true, e)
        var lum: [Float] = []
        for i in 0..<(out.w * out.h) {
            let r: Float = out.rgb[3 * i], g: Float = out.rgb[3 * i + 1], bl: Float = out.rgb[3 * i + 2]
            lum.append(0.2126 * r + 0.7152 * g + 0.0722 * bl)
        }
        lum.sort()
        #expect(abs(Double(lum[lum.count / 2]) - (0.06 + e.brightness * 0.26)) < 0.08)
        // Recortes.
        e.crop = .square
        #expect(PhotoEditor.cropRect(width: 400, height: 300, e).size == CGSize(width: 300, height: 300))
        e.crop = .wide
        let r = PhotoEditor.cropRect(width: 400, height: 300, e)
        #expect(abs(r.width / r.height - 16.0 / 9) < 0.02)
        // Reducir estrellas baja los picos; el ruido de color baja la diferencia entre canales.
        var stars = src.image
        PhotoEditor.reduceStars(&stars, amount: 1)
        #expect(stars.r.max()! < src.image.r.max()! * 0.95)
        var noisy = src.image
        var rng: UInt64 = 7
        for i in noisy.r.indices {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n = (Float(rng >> 40) / Float(1 << 24) - 0.5) * 1600      // ruido de color sin sesgo
            noisy.r[i] += n; noisy.b[i] -= n
        }
        func chroma(_ x: LinearImage) -> Float { zip(x.r, x.b).map { abs($0 - $1) }.reduce(0, +) }
        let before = chroma(noisy)
        PhotoEditor.reduceColorNoise(&noisy, amount: 1)
        #expect(chroma(noisy) < before * 0.7)
    }

    @Test func testExportFormatsAndCaption() throws {
        let src = EditableImage(image: sky(), isLinear: true, name: "prueba")
        let s = PhotoEditor.stretched(PhotoEditor.process(src, PhotoEdit()), isLinear: true, PhotoEdit())
        let cg8 = try #require(PhotoEditor.cgImage(s)), cg16 = try #require(PhotoEditor.cgImage(s, bits16: true))
        #expect(cg16.bitsPerComponent == 16)
        let cap = try #require(PhotoEditor.addCaption("M 42 · 30 × 10 s", to: cg8))
        #expect(cap.width == cg8.width)
        for (f, cg) in [(PhotoEditor.ExportFormat.jpeg, cg8), (.png, cap), (.tiff16, cg16)] {
            let url = tmp("x.\(f.ext)")
            try PhotoEditor.export(cg, format: f, to: url)
            let back = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(back.width == 400)
            if f == .tiff16 { #expect(back.bitsPerComponent == 16) }
        }
    }

    @Test func testSatelliteTrailDetectionAndRemoval() throws {
        #expect(SatelliteTrails.detect(sky()).isEmpty)                     // solo estrellas: nada
        var img = sky(trail: true)
        let found = SatelliteTrails.detect(img)
        #expect(found.count == 1)
        let t = try #require(found.first)
        #expect(t.length > 300)
        var angle = atan2(t.p2.y - t.p1.y, t.p2.x - t.p1.x) * 180 / .pi
        if angle < 0 { angle += 180 }                       // orientación, sin importar el sentido
        if angle >= 180 { angle -= 180 }
        let expected = atan(200.0 / 400) * 180 / .pi
        #expect(min(abs(angle - expected), abs(angle - expected - 180)) < 3)
        SatelliteTrails.remove(found, from: &img)
        // A lo largo de la traza el valor vuelve a ser de fondo.
        let onLine = (50..<350).map { x -> Float in img.r[(40 + x * 200 / 400) * 400 + x] }.sorted()
        #expect(onLine[onLine.count / 2] < 5000)
        // Una traza desmarcada no se toca.
        var img2 = sky(trail: true)
        var off = t; off.enabled = false
        SatelliteTrails.remove([off], from: &img2)
        #expect(img2.r[(40 + 100 * 200 / 400) * 400 + 100] > 9000)
    }

    @Test func testWCSAndLabels() throws {
        // Estimación: M42 en el centro, norte arriba.
        let w = ImageWCS.estimate(raHours: 5.588, decDeg: -5.39, width: 1080, height: 1920, fovWidthDeg: 0.73)
        let c = try #require(w.pixel(raDeg: 5.588 * 15, decDeg: -5.39))
        #expect(abs(c.x - 540) < 0.5 && abs(c.y - 960) < 0.5)
        let north = try #require(w.pixel(raDeg: 5.588 * 15, decDeg: -5.2))
        #expect(north.y < c.y && abs(north.x - c.x) < 1)
        let east = try #require(w.pixel(raDeg: 5.588 * 15 + 0.1, decDeg: -5.39))
        #expect(east.x < c.x)                                             // este a la izquierda
        #expect(abs(w.arcsecPerPixel - 0.73 * 3600 / 1080) < 0.01)
        let labels = SkyLabels.labels(w, width: 1080, height: 1920)
        #expect(labels.contains { $0.id == "M42" } && labels.contains { $0.id == "M43" })
        let comp = try #require(SkyLabels.compass(w, width: 1080, height: 1920))
        #expect(comp.north.dy < -0.99 && comp.east.dx < -0.99)
        // Cabecera FITS con matriz CD (rotada 90°).
        let h = ["CRVAL1": "83.82", "CRVAL2": "-5.39", "CRPIX1": "540.5", "CRPIX2": "960.5",
                 "CD1_1": "0", "CD1_2": "0.000676", "CD2_1": "0.000676", "CD2_2": "0"]
        let fw = try #require(ImageWCS.fromFITS(h, width: 1080, height: 1920))
        #expect(fw.solved)
        let p = try #require(fw.pixel(raDeg: 83.82, decDeg: -5.39))
        #expect(abs(p.x - 539.5) < 0.5 && abs(p.y - 959.5) < 0.5)
        #expect(ImageWCS.fromFITS(["CRVAL1": "1"], width: 10, height: 10) == nil)
        // Centro a partir del nombre del archivo del Seestar.
        let ctr = try #require(SkyLabels.approximateCenter(header: [:], name: "Stacked_25_M 45_30.0s_IRCUT_20261030-234613"))
        #expect(abs(ctr.raHours - 3.79) < 0.05)
    }

    @Test func testGraXpertArgumentsAndRun() async throws {
        let a = GraXpert.arguments(tool: .denoise, input: URL(fileURLWithPath: "/tmp/a b.fits"), outputBase: URL(fileURLWithPath: "/tmp/out"), strength: 0.7)
        #expect(a == ["/tmp/a b.fits", "-cli", "-cmd", "denoising", "-output", "/tmp/out", "-strength", "0.70"])
        #expect(GraXpert.find(in: [URL(fileURLWithPath: "/no/existe")]) == nil)
        // Programa falso que hace de GraXpert: copia la entrada a la salida.
        let dir = tmp("gx"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("GraXpert")
        try "#!/bin/sh\ncp \"$1\" \"$6.fits\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let img = sky(width: 64, height: 48)
        let out = try await GraXpert.run(.background, image: img, strength: 0.1, executable: fake)
        #expect(out.width == 64 && out.height == 48)
        let bad = dir.appendingPathComponent("Falla")
        try "#!/bin/sh\necho roto >&2\nexit 3\n".write(to: bad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path)
        await #expect(throws: GraXpert.RunError.self) { _ = try await GraXpert.run(.denoise, image: img, strength: 0.5, executable: bad) }
        // Las carpetas temporales se borran.
        let left = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("Astrolabio-GraXpert-") }
        #expect(left.isEmpty)
    }

    @Test func testAlbumIndexParsingIsSafe() {
        let html = #"<a href="../">..</a><a href="Stacked_1_M%2042.jpg">x</a><a href="Stacked_1_M%2042.fit">y</a><a href="/etc/passwd">z</a><a href="http://otro/x.jpg">w</a><a href="..%2F..%2Fx.jpg">v</a><a href=".oculto.jpg">o</a><a href="nota.txt">t</a><a href="Stacked_1_M%2042.jpg">dup</a>"#
        #expect(AlbumCopy.parseIndex(html) == ["Stacked_1_M 42.jpg", "Stacked_1_M 42.fit"])
    }

    @Test func testAlbumCopyResumesAndVerifies() async throws {
        let server = try TinyHTTPServer()
        defer { server.stop() }
        let jpg = Data((0..<5000).map { UInt8($0 % 251) }), fit = Data(repeating: 7, count: 3000)
        server.routes["/MyWorks/M 42/"] = ("text/html", Data(#"<a href="a.jpg">a</a> <a href="a.fit">b</a> <a href="falta.jpg">c</a>"#.utf8))
        server.routes["/MyWorks/M 42/a.jpg"] = ("image/jpeg", jpg)
        server.routes["/MyWorks/M 42/a.fit"] = ("application/octet-stream", fit)
        let base = URL(string: "http://127.0.0.1:\(server.port)/MyWorks/M%2042/")!
        let urls = await AlbumCopy.listFolder(base, knownFull: base.appendingPathComponent("a.jpg"))
        #expect(urls.map(\.lastPathComponent) == ["a.jpg", "a.fit", "falta.jpg"])
        let folder = tmp("copia"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: AlbumCopy.Entry] = [:]
        var results: [AlbumCopy.Outcome] = []
        for u in urls { results.append(await AlbumCopy.copy(u, into: folder, manifest: &manifest)) }
        #expect(results == [.copied, .copied, .missing])
        #expect(try Data(contentsOf: folder.appendingPathComponent("a.jpg")) == jpg)
        #expect(manifest["a.jpg"]?.sha256 == (try AlbumCopy.sha256(of: folder.appendingPathComponent("a.jpg"))))
        AlbumCopy.saveManifest(manifest, folder)
        // Reanudar: lo ya copiado y comprobado no se descarga otra vez.
        let before = server.requests.count
        var m2 = AlbumCopy.loadManifest(folder)
        #expect(await AlbumCopy.copy(urls[0], into: folder, manifest: &m2) == .alreadyThere)
        #expect(server.requests.count == before)
        // Si el archivo local se estropea, se vuelve a copiar.
        try Data("roto".utf8).write(to: folder.appendingPathComponent("a.jpg"))
        #expect(await AlbumCopy.copy(urls[0], into: folder, manifest: &m2) == .copied)
        // Sin índice HTML: la imagen conocida y su FITS.
        let plain = await AlbumCopy.listFolder(URL(string: "http://127.0.0.1:\(server.port)/MyWorks/sin-indice/")!,
                                               knownFull: URL(string: "http://127.0.0.1:\(server.port)/MyWorks/sin-indice/x.jpg")!)
        #expect(plain.map(\.lastPathComponent) == ["x.jpg", "x.fit"])
    }
}

/// Solo con ASTROLABIO_REAL_GRAXPERT=1: prueba con el GraXpert instalado de verdad.
@MainActor
struct RealGraXpertTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ASTROLABIO_REAL_GRAXPERT"] == "1"))
    func testRealGraXpertBackground() async throws {
        let w = 512, h = 384
        var l = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { l[y * w + x] = 3000 + Float(x) * 10 + Float(y) * 4 } }   // gradiente
        let img = LinearImage(width: w, height: h, r: l, g: l, b: l)
        let out = try await GraXpert.run(.background, image: img, strength: 0.1, timeout: 360)
        #expect(out.width == w && out.height == h)
        // El gradiente debe haber bajado mucho.
        let leftRight = { (i: LinearImage) -> Float in abs(i.g[h / 2 * w + w - 10] - i.g[h / 2 * w + 10]) }
        print("GraXpert gradiente antes/después:", leftRight(img), leftRight(out))
        #expect(leftRight(out) < leftRight(img) * 0.5)
    }
}
