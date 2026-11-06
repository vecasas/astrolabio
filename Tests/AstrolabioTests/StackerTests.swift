import Foundation
import Testing
import AVFoundation
import CoreVideo
@testable import Astrolabio

/// Planeta sintético: disco con bandas, desplazado (dx, dy) y, si `blur`, emborronado.
private func planetFrame(size: Int, dx: Double, dy: Double, blur: Bool, seed: Int, noise: Bool = true) -> [Float] {
    var img = [Float](repeating: 0.03, count: size * size)
    let c = Double(size) / 2, r = Double(size) * 0.22
    for y in 0..<size {
        for x in 0..<size {
            let px = Double(x) - c - dx, py = Double(y) - c - dy
            let d = sqrt(px * px + py * py)
            if d < r {
                let band = 0.5 + 0.35 * sin(py / r * 9)
                img[y * size + x] = Float(band * (1 - 0.3 * d / r))
            }
        }
    }
    if blur {
        var out = img
        for y in 2..<(size - 2) { for x in 2..<(size - 2) {
            var s: Float = 0
            for j in -2...2 { for i in -2...2 { s += img[(y + j) * size + x + i] } }
            out[y * size + x] = s / 25
        } }
        img = out
    }
    if !noise { return img }
    var g = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1)
    for i in img.indices {
        g = g &* 6364136223846793005 &+ 1442695040888963407
        img[i] = max(0, min(1, img[i] + Float(Int(g >> 33) % 1000 - 500) / 500 * 0.02))
    }
    return img
}

private func writeSER(_ url: URL, size: Int, frames: [[Float]], colorID: Int, depth: Int) throws {
    var d = Data("LUCAM-RECORDER".utf8)
    func i32(_ v: Int) { var x = Int32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
    i32(0); i32(colorID); i32(0); i32(size); i32(size); i32(depth); i32(frames.count)
    d.append(Data(count: 120)); d.append(Data(count: 16))
    #expect(d.count == 178)
    let planes = colorID == 100 ? 3 : 1
    for f in frames {
        for i in 0..<(size * size) {
            for p in 0..<planes {
                var v = f[i]
                // En Bayer RGGB, los píxeles rojos y azules llevan algo menos de señal.
                if planes == 1 && colorID == 8 { let x = i % size, y = i / size; if (x % 2 == 0) != (y % 2 == 0) { v *= 1 } else { v *= 0.8 } }
                _ = p
                if depth > 8 { let u = UInt16(v * 4095); d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
                else { d.append(UInt8(v * 255)) }
            }
        }
    }
    try d.write(to: url)
}

private func makeFrames(size: Int, count: Int) -> [[Float]] {
    (0..<count).map { i in
        planetFrame(size: size, dx: Double((i * 7) % 11) - 5 + 0.3, dy: Double((i * 5) % 9) - 4 - 0.4, blur: i % 3 != 0, seed: i)
    }
}

private func centroid(_ f: RGBFrame) -> (Double, Double) {
    let l = f.luminance()
    let loc = PlanetaryStacker.locate(l, width: f.width, height: f.height)!
    return (loc.cx, loc.cy)
}

struct StackerTests {
    @Test func testStackRGBSERCentersAndSharpens() throws {
        let size = 128
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_test_rgb.ser")
        try writeSER(url, size: size, frames: makeFrames(size: size, count: 30), colorID: 100, depth: 8)
        let src = try SERFrameSource(url: url)
        #expect(src.estimatedFrames == 30)
        let res = try PlanetaryStacker.stack(source: src, options: StackOptions(keepPercent: 30, refine: true)) { _, _ in }
        #expect(res.analyzed == 30)
        #expect(res.used == 9)
        // Las tomas nítidas (1 de cada 3) deben puntuar más que las borrosas.
        var sharpQ = 0.0, blurQ = 0.0
        for i in 0..<30 {
            if i % 3 == 0 { sharpQ += res.qualities[i] / 10 } else { blurQ += res.qualities[i] / 20 }
        }
        #expect(sharpQ > blurQ * 1.5)
        // El planeta apilado queda centrado en el recorte.
        let (cx, cy) = centroid(res.stacked)
        #expect(abs(cx - Double(res.stacked.width) / 2) < 1.5)
        #expect(abs(cy - Double(res.stacked.height) / 2) < 1.5)
        // El apilado se parece más al planeta real (sin ruido ni desenfoque) que una toma borrosa.
        let l = res.stacked.luminance()
        func gray(_ v: [Float]) -> RGBFrame { RGBFrame(width: size, height: size, r: v, g: v, b: v) }
        let truth = gray(planetFrame(size: size, dx: 0, dy: 0, blur: false, seed: 0, noise: false))
        let tc = centroid(truth)
        let truthCrop = PlanetaryStacker.crop(truth, cx: tc.0, cy: tc.1, size: res.stacked.width).luminance()
        let blurry = gray(planetFrame(size: size, dx: 2.3, dy: -1.7, blur: true, seed: 99))
        let bc = centroid(blurry)
        let blurCrop = PlanetaryStacker.crop(blurry, cx: bc.0, cy: bc.1, size: res.stacked.width).luminance()
        func rms(_ a: [Float], _ b: [Float]) -> Double {
            var s = 0.0
            for i in a.indices { let d = Double(a[i] - b[i]); s += d * d }
            return sqrt(s / Double(a.count))
        }
        #expect(rms(l, truthCrop) < rms(blurCrop, truthCrop) * 0.8)
        // …y reduce el ruido del fondo respecto a un solo fotograma.
        func bgStd(_ v: [Float], _ w: Int) -> Double {
            var s = 0.0, s2 = 0.0, n = 0.0
            for y in 2..<12 { for x in 2..<12 { let a = Double(v[y * w + x]); s += a; s2 += a * a; n += 1 } }
            return sqrt(max(0, s2 / n - (s / n) * (s / n)))
        }
        #expect(bgStd(l, res.stacked.width) < bgStd(res.bestFrame.luminance(), res.bestFrame.width) * 0.7)
        // El procesado final produce una imagen guardable.
        let out = PlanetaryStacker.finish(res.stacked, .init())
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_test.png")
        try PlanetaryStacker.save(out, to: png)
        #expect(FileManager.default.fileExists(atPath: png.path))
        let tif = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_test.tif")
        try PlanetaryStacker.save(out, to: tif)
        #expect(FileManager.default.fileExists(atPath: tif.path))
    }

    @Test func testBayer16SER() throws {
        let size = 96
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_test_bayer.ser")
        try writeSER(url, size: size, frames: makeFrames(size: size, count: 12), colorID: 8, depth: 12)
        let src = try SERFrameSource(url: url)
        let res = try PlanetaryStacker.stack(source: src, options: StackOptions(keepPercent: 50, refine: true)) { _, _ in }
        #expect(res.used == 6)
        let (cx, cy) = centroid(res.stacked)
        #expect(abs(cx - Double(res.stacked.width) / 2) < 2)
        #expect(abs(cy - Double(res.stacked.height) / 2) < 2)
    }

    @Test func testResidualShiftSubpixel() {
        let size = 64
        let a = planetFrame(size: size, dx: 0, dy: 0, blur: true, seed: 1)
        let b = planetFrame(size: size, dx: 1.6, dy: -2.3, blur: true, seed: 1)
        let s = PlanetaryStacker.residualShift(ref: a, img: b, size: size)
        #expect(abs(s.dx - 1.6) < 0.35)
        #expect(abs(s.dy + 2.3) < 0.35)
    }

    @Test func testMP4Video() async throws {
        let size = 128, count = 24
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabio_test.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (i, f) in makeFrames(size: size, count: count).enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<size { for x in 0..<size {
                let v = UInt8(f[y * size + x] * 255)
                let p = base + y * stride + 4 * x
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)

        let src = try await PlanetaryStacker.open(url)
        #expect(src.width == size)
        let res = try PlanetaryStacker.stack(source: src, options: StackOptions(keepPercent: 25, refine: true)) { _, _ in }
        #expect(res.analyzed >= count - 1)
        let (cx, cy) = centroid(res.stacked)
        #expect(abs(cx - Double(res.stacked.width) / 2) < 2)
        #expect(abs(cy - Double(res.stacked.height) / 2) < 2)
    }
}
