import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Fotograma RGB en coma flotante (0–1).
struct RGBFrame {
    let width: Int
    let height: Int
    var r: [Float]
    var g: [Float]
    var b: [Float]

    func luminance() -> [Float] {
        var l = [Float](repeating: 0, count: width * height)
        for i in l.indices { l[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i] }
        return l
    }
}

/// Origen de fotogramas que se puede recorrer varias veces.
protocol FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var estimatedFrames: Int { get }
    var fps: Double { get }
    func rewind() throws
    func next() -> RGBFrame?
}

enum StackerError: LocalizedError {
    case unsupported(String)
    case noFrames
    case noPlanet

    var errorDescription: String? {
        switch self {
        case .unsupported(let m): return m
        case .noFrames: return tr("El vídeo no tiene fotogramas legibles.")
        case .noPlanet: return tr("No encuentro ningún objeto brillante en el vídeo.")
        }
    }
}

// MARK: - Vídeo (MP4, MOV… vía AVFoundation)

final class VideoFrameSource: FrameSource {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    let width: Int
    let height: Int
    let estimatedFrames: Int
    let fps: Double

    init(url: URL) async throws {
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            throw StackerError.unsupported(tr("El archivo no contiene vídeo."))
        }
        track = t
        let size = try await t.load(.naturalSize)
        let rate = try await t.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        width = Int(abs(size.width))
        height = Int(abs(size.height))
        fps = Double(rate)
        estimatedFrames = max(1, Int(duration.seconds * Double(max(rate, 1))))
    }

    func rewind() throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { throw StackerError.unsupported(r.error?.localizedDescription ?? tr("No se puede leer el vídeo.")) }
        reader = r
        output = o
    }

    func next() -> RGBFrame? {
        guard let output, let sample = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let n = w * h
        var r = [Float](repeating: 0, count: n), g = r, b = r
        let k: Float = 1 / 255
        for y in 0..<h {
            let row = base + y * stride
            for x in 0..<w {
                let p = row + 4 * x
                let i = y * w + x
                b[i] = Float(p[0]) * k; g[i] = Float(p[1]) * k; r[i] = Float(p[2]) * k
            }
        }
        return RGBFrame(width: w, height: h, r: r, g: g, b: b)
    }
}

// MARK: - SER (formato habitual de las cámaras planetarias)

final class SERFrameSource: FrameSource {
    private let data: Data
    let width: Int
    let height: Int
    let estimatedFrames: Int
    let fps: Double = 0
    private let colorID: Int
    private let bytesPerSample: Int
    private let planes: Int
    private let maxValue: Float
    private var index = 0

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        data = d
        guard d.count > 178, String(decoding: d.prefix(14), as: UTF8.self).hasPrefix("LUCAM-RECORDER") else {
            throw StackerError.unsupported(tr("No es un archivo SER válido."))
        }
        func i32(_ o: Int) -> Int {
            Int(Int32(bitPattern: UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24))
        }
        colorID = i32(18)
        width = i32(26)
        height = i32(30)
        let depth = i32(34)
        let count = i32(38)
        bytesPerSample = depth > 8 ? 2 : 1
        planes = (colorID == 100 || colorID == 101) ? 3 : 1
        maxValue = Float((1 << max(1, min(16, depth))) - 1)
        let frameBytes = width * height * planes * bytesPerSample
        guard width > 0, height > 0, frameBytes > 0 else { throw StackerError.unsupported(tr("Cabecera SER no válida.")) }
        estimatedFrames = min(count, (d.count - 178) / frameBytes)
    }

    func rewind() throws { index = 0 }

    func next() -> RGBFrame? {
        guard index < estimatedFrames else { return nil }
        let frameBytes = width * height * planes * bytesPerSample
        let start = 178 + index * frameBytes
        index += 1
        let n = width * height
        var r = [Float](repeating: 0, count: n), g = r, b = r
        let k = 1 / maxValue
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.baseAddress!.advanced(by: start)
            func sample(_ i: Int) -> Float {
                if bytesPerSample == 1 { return Float(p.load(fromByteOffset: i, as: UInt8.self)) * k }
                let lo = UInt16(p.load(fromByteOffset: 2 * i, as: UInt8.self))
                let hi = UInt16(p.load(fromByteOffset: 2 * i + 1, as: UInt8.self))
                return Float(lo | hi << 8) * k
            }
            if planes == 3 {
                let bgr = colorID == 101
                for i in 0..<n {
                    let c0 = sample(3 * i), c1 = sample(3 * i + 1), c2 = sample(3 * i + 2)
                    r[i] = bgr ? c2 : c0; g[i] = c1; b[i] = bgr ? c0 : c2
                }
            } else if (8...11).contains(colorID) {
                // Bayer: cada píxel toma los colores de su bloque 2×2.
                // Posición del rojo en el bloque según el patrón: RGGB, GRBG, GBRG, BGGR.
                let redAt: (Int, Int) = [(0, 0), (1, 0), (0, 1), (1, 1)][colorID - 8]
                for y in 0..<height {
                    let by = y & ~1
                    for x in 0..<width {
                        let bx = x & ~1
                        guard bx + 1 < width, by + 1 < height else { continue }
                        let rr = sample((by + redAt.1) * width + bx + redAt.0)
                        let bb = sample((by + 1 - redAt.1) * width + bx + 1 - redAt.0)
                        let g1 = sample((by + redAt.1) * width + bx + 1 - redAt.0)
                        let g2 = sample((by + 1 - redAt.1) * width + bx + redAt.0)
                        let i = y * width + x
                        r[i] = rr; g[i] = (g1 + g2) / 2; b[i] = bb
                    }
                }
            } else {
                for i in 0..<n { let v = sample(i); r[i] = v; g[i] = v; b[i] = v }
            }
        }
        return RGBFrame(width: width, height: height, r: r, g: g, b: b)
    }
}

// MARK: - Apilado

struct StackOptions {
    var keepPercent: Double = 25        // porcentaje de los mejores fotogramas
    var refine = true                   // ajuste fino de la alineación por correlación
    var maxFrames = 5000
}

struct StackResult {
    let stacked: RGBFrame               // recorte apilado (lineal)
    let bestFrame: RGBFrame             // recorte del mejor fotograma, para comparar
    let qualities: [Double]             // nitidez de cada fotograma analizado (orden original)
    let used: Int
    let analyzed: Int
}

enum PlanetaryStacker {
    typealias Progress = @Sendable (String, Double) -> Void

    static func open(_ url: URL) async throws -> FrameSource {
        if url.pathExtension.lowercased() == "ser" { return try SERFrameSource(url: url) }
        return try await VideoFrameSource(url: url)
    }

    /// Centroide del objeto brillante y su caja (en píxeles).
    static func locate(_ l: [Float], width: Int, height: Int) -> (cx: Double, cy: Double, box: Int)? {
        var lo: Float = .greatestFiniteMagnitude, hi: Float = 0
        var i = 0
        let step = max(1, l.count / 20000)
        var sample: [Float] = []
        while i < l.count { sample.append(l[i]); hi = max(hi, l[i]); i += step }
        sample.sort()
        lo = sample[sample.count / 10]
        guard hi - lo > 0.02 else { return nil }
        let thr = lo + 0.2 * (hi - lo)
        var sx = 0.0, sy = 0.0, sw = 0.0
        var minX = width, maxX = 0, minY = height, maxY = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let v = l[row + x]
                if v > thr {
                    let w = Double(v - thr)
                    sx += w * Double(x); sy += w * Double(y); sw += w
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard sw > 0 else { return nil }
        return (sx / sw, sy / sw, max(maxX - minX, maxY - minY))
    }

    /// Nitidez: energía del laplaciano en la zona del objeto, normalizada por su brillo. Se mide
    /// sobre píxeles agrupados de 2×2 para que el ruido del sensor no cuente como detalle.
    static func sharpness(_ l: [Float], width: Int, height: Int, cx: Double, cy: Double, half: Int) -> Double {
        let x0 = max(0, Int(cx) - half) & ~1, x1 = min(width - 2, Int(cx) + half)
        let y0 = max(0, Int(cy) - half) & ~1, y1 = min(height - 2, Int(cy) + half)
        let bw = (x1 - x0) / 2, bh = (y1 - y0) / 2
        guard bw > 4, bh > 4 else { return 0 }
        var bin = [Float](repeating: 0, count: bw * bh)
        l.withUnsafeBufferPointer { p in
            for by in 0..<bh {
                let r0 = (y0 + 2 * by) * width + x0, r1 = r0 + width
                for bx in 0..<bw {
                    let o = 2 * bx
                    bin[by * bw + bx] = (p[r0 + o] + p[r0 + o + 1] + p[r1 + o] + p[r1 + o + 1]) * 0.25
                }
            }
        }
        var e = 0.0, s = 0.0
        for y in 1..<(bh - 1) {
            let row = y * bw
            for x in 1..<(bw - 1) {
                let c = bin[row + x]
                let lap = 4 * c - bin[row + x - 1] - bin[row + x + 1] - bin[row - bw + x] - bin[row + bw + x]
                e += Double(lap * lap)
                s += Double(c)
            }
        }
        let n = Double((bw - 2) * (bh - 2))
        let mean = s / n
        return mean > 0 ? (e / n) / (mean * mean) : 0
    }

    /// Recorte de `size`×`size` centrado en (cx, cy) con muestreo bilineal (fuera de la imagen = 0).
    static func crop(_ f: RGBFrame, cx: Double, cy: Double, size: Int) -> RGBFrame {
        let n = size * size
        var r = [Float](repeating: 0, count: n), g = r, b = r
        let ox = cx - Double(size) / 2, oy = cy - Double(size) / 2
        let fx0 = Int(floor(ox)), fy0 = Int(floor(oy))
        let tx = Float(ox - Double(fx0)), ty = Float(oy - Double(fy0))
        let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
        let W = f.width
        f.r.withUnsafeBufferPointer { R in
        f.g.withUnsafeBufferPointer { G in
        f.b.withUnsafeBufferPointer { B in
            for y in 0..<size {
                let y0 = fy0 + y
                guard y0 >= 0, y0 + 1 < f.height else { continue }
                for x in 0..<size {
                    let x0 = fx0 + x
                    guard x0 >= 0, x0 + 1 < W else { continue }
                    let i00 = y0 * W + x0, i10 = i00 + 1, i01 = i00 + W, i11 = i01 + 1
                    let o = y * size + x
                    r[o] = R[i00] * w00 + R[i10] * w10 + R[i01] * w01 + R[i11] * w11
                    g[o] = G[i00] * w00 + G[i10] * w10 + G[i01] * w01 + G[i11] * w11
                    b[o] = B[i00] * w00 + B[i10] * w10 + B[i01] * w01 + B[i11] * w11
                }
            }
        } } }
        return RGBFrame(width: size, height: size, r: r, g: g, b: b)
    }

    /// Desplazamiento (subpíxel) que mejor alinea `img` con `ref` en ±`range` píxeles.
    static func residualShift(ref: [Float], img: [Float], size: Int, range: Int = 3) -> (dx: Double, dy: Double) {
        let m = range + 2
        var cost = [[Double]](repeating: [Double](repeating: 0, count: 2 * range + 1), count: 2 * range + 1)
        var best = (0, 0, Double.greatestFiniteMagnitude)
        for dy in -range...range {
            for dx in -range...range {
                var ssd = 0.0
                var y = m
                while y < size - m {
                    let ry = y * size, iy = (y + dy) * size
                    var x = m
                    while x < size - m {
                        let d = Double(ref[ry + x] - img[iy + x + dx])
                        ssd += d * d
                        x += 2
                    }
                    y += 2
                }
                cost[dy + range][dx + range] = ssd
                if ssd < best.2 { best = (dx, dy, ssd) }
            }
        }
        // Ajuste parabólico alrededor del mínimo.
        func para(_ a: Double, _ b: Double, _ c: Double) -> Double {
            let den = a - 2 * b + c
            return den > 1e-12 ? 0.5 * (a - c) / den : 0
        }
        var sx = Double(best.0), sy = Double(best.1)
        let ix = best.0 + range, iy = best.1 + range
        if ix > 0 && ix < 2 * range { sx += para(cost[iy][ix - 1], cost[iy][ix], cost[iy][ix + 1]) }
        if iy > 0 && iy < 2 * range { sy += para(cost[iy - 1][ix], cost[iy][ix], cost[iy + 1][ix]) }
        return (sx, sy)
    }

    /// Analiza la nitidez de todos los fotogramas, se queda con los mejores, los alinea y los promedia.
    static func stack(source: FrameSource, options: StackOptions, progress: Progress) throws -> StackResult {
        // 1) Análisis.
        try source.rewind()
        var info: [(q: Double, cx: Double, cy: Double)] = []
        var half = 0
        let total = Double(min(source.estimatedFrames, options.maxFrames))
        while info.count < options.maxFrames, let f = source.next() {
            let l = f.luminance()
            guard let loc = locate(l, width: f.width, height: f.height) else { info.append((0, 0, 0)); continue }
            if half == 0 { half = max(24, Int(Double(loc.box) * 0.75) + 12) }
            info.append((sharpness(l, width: f.width, height: f.height, cx: loc.cx, cy: loc.cy, half: half), loc.cx, loc.cy))
            if info.count % 10 == 0 { progress(tr("Analizando la nitidez (%@ fotogramas)…", "\(info.count)"), min(0.5, Double(info.count) / total * 0.5)) }
        }
        guard !info.isEmpty else { throw StackerError.noFrames }
        guard half > 0 else { throw StackerError.noPlanet }

        let size = min(2 * half + 32, min(source.width, source.height)) & ~1
        let order = info.indices.filter { info[$0].q > 0 }.sorted { info[$0].q > info[$1].q }
        guard !order.isEmpty else { throw StackerError.noPlanet }
        let keep = max(1, Int(Double(order.count) * options.keepPercent / 100))
        let chosen = Set(order.prefix(keep))
        let bestIndex = order[0]

        // 2) Referencia: el fotograma más nítido.
        try source.rewind()
        var refCrop: RGBFrame?
        var idx = 0
        while let f = source.next() {
            if idx == bestIndex { refCrop = crop(f, cx: info[idx].cx, cy: info[idx].cy, size: size); break }
            idx += 1
        }
        guard let ref = refCrop else { throw StackerError.noFrames }
        let refL = ref.luminance()

        // 3) Alineación y suma.
        try source.rewind()
        let n = size * size
        var sr = [Float](repeating: 0, count: n), sg = sr, sb = sr
        var used = 0
        idx = 0
        while let f = source.next(), idx < info.count {
            defer { idx += 1 }
            guard chosen.contains(idx) else { continue }
            var cx = info[idx].cx, cy = info[idx].cy
            if options.refine && idx != bestIndex {
                let c = crop(f, cx: cx, cy: cy, size: size)
                let s = residualShift(ref: refL, img: c.luminance(), size: size)
                cx += s.dx; cy += s.dy
            }
            let c = crop(f, cx: cx, cy: cy, size: size)
            for i in 0..<n { sr[i] += c.r[i]; sg[i] += c.g[i]; sb[i] += c.b[i] }
            used += 1
            if used % 5 == 0 { progress(tr("Alineando y apilando (%@ de %@)…", "\(used)", "\(keep)"), 0.5 + 0.5 * Double(used) / Double(keep)) }
        }
        let k = 1 / Float(max(1, used))
        for i in 0..<n { sr[i] *= k; sg[i] *= k; sb[i] *= k }
        progress("Hecho", 1)
        return StackResult(stacked: RGBFrame(width: size, height: size, r: sr, g: sg, b: sb),
                           bestFrame: ref, qualities: info.map(\.q), used: used, analyzed: info.count)
    }

    // MARK: Procesado final

    struct Finish: Equatable {
        var fine: Double = 1.2         // realce de detalle fino (σ ≈ 1 px)
        var medium: Double = 0.6       // realce de detalle medio (σ ≈ 2,5 px)
        var gamma: Double = 1.0
        var balance = true             // igualar los canales sobre el planeta
    }

    static func blur(_ c: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        let rad = max(1, Int(ceil(sigma * 3)))
        var k = (-rad...rad).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let s = k.reduce(0, +); k = k.map { $0 / s }
        var tmp = [Float](repeating: 0, count: c.count), out = tmp
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for j in -rad...rad { acc += k[j + rad] * c[y * width + min(width - 1, max(0, x + j))] }
                tmp[y * width + x] = acc
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for j in -rad...rad { acc += k[j + rad] * tmp[min(height - 1, max(0, y + j)) * width + x] }
                out[y * width + x] = acc
            }
        }
        return out
    }

    static func finish(_ f: RGBFrame, _ o: Finish) -> RGBFrame {
        var out = f
        func sharpen(_ c: [Float]) -> [Float] {
            let b1 = blur(c, width: f.width, height: f.height, sigma: 1.0)
            let b2 = blur(c, width: f.width, height: f.height, sigma: 2.5)
            var r = c
            for i in r.indices {
                r[i] = c[i] + Float(o.fine) * (c[i] - b1[i]) + Float(o.medium) * (b1[i] - b2[i])
            }
            return r
        }
        if o.fine > 0 || o.medium > 0 { out.r = sharpen(f.r); out.g = sharpen(f.g); out.b = sharpen(f.b) }

        // Niveles: negro en el fondo, blanco en el percentil 99,9 del planeta.
        let l = out.luminance()
        let sorted = stride(from: 0, to: l.count, by: max(1, l.count / 40000)).map { l[$0] }.sorted()
        let black = sorted[sorted.count / 20]
        let white = max(black + 1e-3, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.999))])
        var gains: (Float, Float, Float) = (1, 1, 1)
        if o.balance {
            let thr = black + 0.25 * (white - black)
            var mr = 0.0, mg = 0.0, mb = 0.0, nn = 0.0
            for i in l.indices where l[i] > thr { mr += Double(out.r[i]); mg += Double(out.g[i]); mb += Double(out.b[i]); nn += 1 }
            if nn > 0 && mr > 0 && mb > 0 { gains = (Float(mg / mr), 1, Float(mg / mb)) }
        }
        let scale = 1 / (white - black)
        let invGamma = Float(1 / max(0.2, o.gamma))
        func lv(_ v: Float, _ gain: Float) -> Float {
            let x = max(0, min(1, (v * gain - black) * scale))
            return invGamma == 1 ? x : pow(x, invGamma)
        }
        for i in l.indices {
            out.r[i] = lv(out.r[i], gains.0); out.g[i] = lv(out.g[i], gains.1); out.b[i] = lv(out.b[i], gains.2)
        }
        return out
    }

    static func cgImage(_ f: RGBFrame, bits16: Bool = false) -> CGImage? {
        let n = f.width * f.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if bits16 {
            var px = [UInt16](repeating: 0, count: n * 3)
            for i in 0..<n {
                px[3 * i] = UInt16(max(0, min(1, f.r[i])) * 65535)
                px[3 * i + 1] = UInt16(max(0, min(1, f.g[i])) * 65535)
                px[3 * i + 2] = UInt16(max(0, min(1, f.b[i])) * 65535)
            }
            let data = px.withUnsafeBytes { Data($0) } as CFData
            guard let prov = CGDataProvider(data: data) else { return nil }
            return CGImage(width: f.width, height: f.height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: f.width * 6,
                           space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                           provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        var px = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            px[4 * i] = UInt8(max(0, min(1, f.r[i])) * 255)
            px[4 * i + 1] = UInt8(max(0, min(1, f.g[i])) * 255)
            px[4 * i + 2] = UInt8(max(0, min(1, f.b[i])) * 255)
            px[4 * i + 3] = 255
        }
        let data = px.withUnsafeBytes { Data($0) } as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.width * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func save(_ f: RGBFrame, to url: URL) throws {
        let tiff = url.pathExtension.lowercased().hasPrefix("tif")
        guard let img = cgImage(f, bits16: tiff),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, (tiff ? UTType.tiff : UTType.png).identifier as CFString, 1, nil) else {
            throw StackerError.unsupported(tr("No se pudo crear la imagen."))
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw StackerError.unsupported(tr("No se pudo guardar %@.", "\(url.lastPathComponent)")) }
    }
}
