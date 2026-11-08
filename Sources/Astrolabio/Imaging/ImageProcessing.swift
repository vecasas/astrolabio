import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ProcessingOptions: Equatable {
    var targetBackground: Double = 0.16   // brillo del fondo tras el estirado (0–0,5)
    var shadowsClip: Double = 2.8         // agresividad del recorte de sombras
    var removeGradient = true             // quita la contaminación lumínica (ajuste polinómico)
    var saturation: Double = 1.3
    var denoise = true                    // ruido de color y de fondo
    var linked = true                     // estirado igual en los tres canales (conserva el color)
    var cropEdges = true                  // recorta los bordes que deja el dithering al apilar
    var colorBalance = true               // fondo neutro y equilibrio de color con las estrellas
}

/// Imagen lineal de 16 bits en memoria, en planos RGB.
struct LinearImage {
    let width: Int
    let height: Int
    var r: [Float]
    var g: [Float]
    var b: [Float]
}

enum ImageProcessing {

    // MARK: Conversión a imagen lineal

    static func linear(from frame: RawFrame) -> LinearImage {
        if frame.channels == 3 {
            let n = frame.width * frame.height
            var r = [Float](repeating: 0, count: n)
            var g = r, b = r
            frame.pixels.withUnsafeBufferPointer { p in
                for i in 0..<n {
                    r[i] = Float(p[3 * i])
                    g[i] = Float(p[3 * i + 1])
                    b[i] = Float(p[3 * i + 2])
                }
            }
            return LinearImage(width: frame.width, height: frame.height, r: r, g: g, b: b)
        }
        // Bayer GRBG → superpíxel (mitad de resolución), rápido y sin artefactos de color.
        let w2 = frame.width / 2, h2 = frame.height / 2
        let n = w2 * h2
        var r = [Float](repeating: 0, count: n)
        var g = r, b = r
        let W = frame.width
        frame.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h2 {
                let row0 = 2 * y * W, row1 = row0 + W
                for x in 0..<w2 {
                    let x0 = 2 * x
                    let g1 = Float(p[row0 + x0])
                    let rr = Float(p[row0 + x0 + 1])
                    let bb = Float(p[row1 + x0])
                    let g2 = Float(p[row1 + x0 + 1])
                    let o = y * w2 + x
                    r[o] = rr; g[o] = (g1 + g2) * 0.5; b[o] = bb
                }
            }
        }
        return LinearImage(width: w2, height: h2, r: r, g: g, b: b)
    }

    // MARK: Estadística

    private static func medianMAD(_ data: [Float], step: Int = 7) -> (Float, Float) {
        var sample: [Float] = []
        sample.reserveCapacity(data.count / step + 1)
        var i = 0
        while i < data.count { sample.append(data[i]); i += step }
        guard !sample.isEmpty else { return (0, 1) }
        sample.sort()
        let med = sample[sample.count / 2]
        var dev = sample.map { abs($0 - med) }
        dev.sort()
        let mad = dev[dev.count / 2] * 1.4826
        return (med, max(mad, 1))
    }

    /// Función de transferencia de medios tonos.
    static func mtf(_ x: Double, _ m: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if m == 0.5 { return x }
        return ((m - 1) * x) / ((2 * m - 1) * x - m)
    }

    // MARK: Gradiente de fondo

    /// Resta un fondo suave estimado con medianas en una rejilla de 12×12 celdas.
    static func removeGradient(_ img: inout LinearImage, grid: Int = 12) {
        let w = img.width, h = img.height
        func process(_ ch: inout [Float]) {
            var cells = [Float](repeating: 0, count: grid * grid)
            for gy in 0..<grid {
                for gx in 0..<grid {
                    let x0 = gx * w / grid, x1 = (gx + 1) * w / grid
                    let y0 = gy * h / grid, y1 = (gy + 1) * h / grid
                    var s: [Float] = []
                    var y = y0
                    while y < y1 {
                        var x = x0
                        while x < x1 { s.append(ch[y * w + x]); x += 5 }
                        y += 5
                    }
                    s.sort()
                    // Percentil 30: evita que estrellas y nebulosa suban el fondo.
                    cells[gy * grid + gx] = s.isEmpty ? 0 : s[s.count * 3 / 10]
                }
            }
            let floor = cells.min() ?? 0
            for y in 0..<h {
                let fy = (Float(y) / Float(h)) * Float(grid) - 0.5
                let iy = max(0, min(grid - 2, Int(fy.rounded(.down))))
                let ty = max(0, min(1, fy - Float(iy)))
                for x in 0..<w {
                    let fx = (Float(x) / Float(w)) * Float(grid) - 0.5
                    let ix = max(0, min(grid - 2, Int(fx.rounded(.down))))
                    let tx = max(0, min(1, fx - Float(ix)))
                    let a = cells[iy * grid + ix], b = cells[iy * grid + ix + 1]
                    let c = cells[(iy + 1) * grid + ix], d = cells[(iy + 1) * grid + ix + 1]
                    let bg = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                    let i = y * w + x
                    ch[i] = max(0, ch[i] - bg + floor)
                }
            }
        }
        process(&img.r); process(&img.g); process(&img.b)
    }

    /// Suavizado 3×3 sencillo mezclado con el original (reduce el ruido del fondo).
    static func denoise(_ img: inout LinearImage, amount: Float = 0.5) {
        let w = img.width, h = img.height
        guard w > 2, h > 2 else { return }
        func process(_ ch: inout [Float]) {
            let src = ch
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    var s: Float = 0
                    for dy in -1...1 { for dx in -1...1 { s += src[i + dy * w + dx] } }
                    ch[i] = src[i] * (1 - amount) + (s / 9) * amount
                }
            }
        }
        process(&img.r); process(&img.g); process(&img.b)
    }

    // MARK: Bordes del apilado

    /// Mediana rápida por muestreo.
    private static func quickMedian(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let step = max(1, v.count / 4000)
        var s: [Float] = []
        var i = 0
        while i < v.count { s.append(v[i]); i += step }
        s.sort()
        return s[s.count / 2]
    }

    /// Recorta las franjas de los bordes que deja el apilado con dithering o rotación de campo.
    /// Allí entran menos fotogramas, así que tienen más ruido y otro color: se compara cada fila o
    /// columna del borde con una franja de referencia algo más adentro.
    static func cropStackEdges(_ img: LinearImage) -> LinearImage {
        let w = img.width, h = img.height
        guard w > 128, h > 128 else { return img }
        let maxCut = max(16, min(w, h) / 9)

        /// Por segmentos de la línea (8 trozos): (ruido, croma) de cada uno. Con la rotación de
        /// campo de la montura altacimutal las franjas salen inclinadas y solo ocupan parte de la línea.
        /// Trozos de unos 200 px (al menos 5) a lo largo de cada línea.
        func segmentCount(_ length: Int) -> Int { max(5, length / 200) }
        func metrics(_ count: Int, _ index: (Int) -> Int) -> [(Float, Float)] {
            let segments = segmentCount(count)
            let segLen = count / segments
            return (0..<segments).map { sIdx in
                var diffs: [Float] = [], chroma: [Float] = []
                var k = sIdx * segLen + 2
                let end = (sIdx + 1) * segLen
                while k < end {
                    let i = index(k), j = index(k - 2)
                    diffs.append(abs(img.g[i] - img.g[j]))
                    chroma.append(img.b[i] - img.r[i])
                    k += 2
                }
                diffs.sort(); chroma.sort()
                return diffs.isEmpty ? (0, 0) : (diffs[diffs.count / 2], chroma[chroma.count / 2])
            }
        }
        func rowM(_ y: Int) -> [(Float, Float)] { metrics(w) { y * w + $0 } }
        func colM(_ x: Int) -> [(Float, Float)] { metrics(h) { $0 * w + x } }

        func cut(_ m: (Int) -> [(Float, Float)], size: Int, fromEnd: Bool) -> Int {
            func line(_ k: Int) -> [(Float, Float)] { m(fromEnd ? size - 1 - k : k) }
            let ks = Array(stride(from: maxCut, to: maxCut + 48, by: 4))
            let refs = ks.map(line)
            // Referencia por segmento: ruido mediano y recta del croma (el color del fondo puede
            // cambiar con la contaminación lumínica), que se extrapola hacia el borde.
            let segments = refs[0].count
            var refNoise = [Float](repeating: 0, count: segments)
            var mc = [Double](repeating: 0, count: segments), slope = mc
            let mk = Double(ks.reduce(0, +)) / Double(ks.count)
            for sIdx in 0..<segments {
                refNoise[sIdx] = refs.map { $0[sIdx].0 }.sorted()[refs.count / 2]
                let cs = refs.map { Double($0[sIdx].1) }
                mc[sIdx] = cs.reduce(0, +) / Double(cs.count)
                var sxy = 0.0, sxx = 0.0
                for (k, c) in zip(ks, cs) { sxy += (Double(k) - mk) * (c - mc[sIdx]); sxx += (Double(k) - mk) * (Double(k) - mk) }
                slope[sIdx] = sxx > 0 ? sxy / sxx : 0
            }
            // Métricas de cada línea del borde, suavizadas con la mediana de 5 líneas vecinas:
            // las franjas son continuas y el ruido aleatorio da picos aislados.
            let raw = (0..<(maxCut + 2)).map(line)
            func smoothed(_ k: Int, _ sIdx: Int) -> (Float, Float) {
                let lo = max(0, k - 2), hi = min(raw.count - 1, k + 2)
                let ns = (lo...hi).map { raw[$0][sIdx].0 }.sorted()
                let cs = (lo...hi).map { raw[$0][sIdx].1 }.sorted()
                return (ns[ns.count / 2], cs[cs.count / 2])
            }
            var last = -1, quiet = 0
            for k in 0..<maxCut {
                var flagged = 0
                for sIdx in 0..<segments {
                    let (n, c) = smoothed(k, sIdx)
                    let expected = mc[sIdx] + slope[sIdx] * (Double(k) - mk)
                    if n > refNoise[sIdx] * 1.45 + 1 || abs(Double(c) - expected) > Double(max(30, refNoise[sIdx] * 2.5)) { flagged += 1 }
                }
                if flagged >= 1 { last = k; quiet = 0 }
                else { quiet += 1; if quiet > 12 { break } }
            }
            // Menos de 4 líneas marcadas en el mismo borde no es una franja de apilado.
            return last < 3 ? 0 : last + 1 + 20
        }
        let top = cut(rowM, size: h, fromEnd: false), bottom = cut(rowM, size: h, fromEnd: true)
        let left = cut(colM, size: w, fromEnd: false), right = cut(colM, size: w, fromEnd: true)
        guard top + bottom + left + right > 0, w - left - right > w / 2, h - top - bottom > h / 2 else { return img }
        let nw = w - left - right, nh = h - top - bottom
        func crop(_ c: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                let src = (y + top) * w + left
                for x in 0..<nw { out[y * nw + x] = c[src + x] }
            }
            return out
        }
        return LinearImage(width: nw, height: nh, r: crop(img.r), g: crop(img.g), b: crop(img.b))
    }

    // MARK: Fondo y color

    /// Nivel común al que se lleva el fondo de los tres canales (en unidades de 16 bits).
    static let pedestal: Float = 1500

    /// Ajusta por mínimos cuadrados un polinomio de grado 2 en (x, y) a los valores de fondo de una
    /// rejilla, descartando las celdas con nebulosa o estrellas brillantes, y lo resta.
    /// El fondo de los tres canales queda en el mismo nivel, así que también sale neutro.
    static func subtractBackgroundModel(_ img: inout LinearImage) {
        let w = img.width, h = img.height
        let gx = max(6, w / 64), gy = max(6, h / 64)
        func basis(_ x: Double, _ y: Double) -> [Double] { [1, x, y, x * x, x * y, y * y] }
        func process(_ ch: inout [Float]) {
            var pts: [(x: Double, y: Double, v: Double)] = []
            for cy in 0..<gy {
                for cx in 0..<gx {
                    let x0 = cx * w / gx, x1 = (cx + 1) * w / gx, y0 = cy * h / gy, y1 = (cy + 1) * h / gy
                    var s: [Float] = []
                    var y = y0
                    while y < y1 { var x = x0; while x < x1 { s.append(ch[y * w + x]); x += 3 }; y += 3 }
                    guard s.count > 8 else { continue }
                    s.sort()
                    pts.append((Double(x0 + x1) / Double(w) - 1, Double(y0 + y1) / Double(h) - 1, Double(s[s.count * 3 / 10])))
                }
            }
            guard pts.count >= 12 else { return }
            var active = Array(repeating: true, count: pts.count)
            var coef = [Double](repeating: 0, count: 6)
            for _ in 0..<4 {
                var ata = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
                var atb = [Double](repeating: 0, count: 6)
                for (i, p) in pts.enumerated() where active[i] {
                    let b = basis(p.x, p.y)
                    for r in 0..<6 { atb[r] += b[r] * p.v; for c in 0..<6 { ata[r][c] += b[r] * b[c] } }
                }
                guard let sol = solve(ata, atb) else { return }
                coef = sol
                let res = pts.map { p in p.v - zip(basis(p.x, p.y), coef).map(*).reduce(0, +) }
                let act = res.enumerated().filter { active[$0.offset] }.map { abs($0.element) }.sorted()
                let mad = max(1, act[act.count / 2] * 1.4826)
                for i in pts.indices { active[i] = res[i] < 2.5 * mad && res[i] > -4 * mad }
            }
            for y in 0..<h {
                let fy = (2 * Double(y) + 1) / Double(h) - 1
                let a0 = coef[0] + coef[2] * fy + coef[5] * fy * fy, a1 = coef[1] + coef[4] * fy, a2 = coef[3]
                for x in 0..<w {
                    let fx = (2 * Double(x) + 1) / Double(w) - 1
                    let bg = Float(a0 + a1 * fx + a2 * fx * fx)
                    let i = y * w + x
                    ch[i] = max(0, ch[i] - bg + pedestal)
                }
            }
        }
        process(&img.r); process(&img.g); process(&img.b)
    }

    /// Sistema lineal pequeño por eliminación gaussiana con pivote.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, v = b
        for col in 0..<n {
            guard let piv = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[piv][col]) > 1e-12 else { return nil }
            m.swapAt(col, piv); v.swapAt(col, piv)
            for r in (col + 1)..<n {
                let f = m[r][col] / m[col][col]
                for c in col..<n { m[r][c] -= f * m[col][c] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for c in (r + 1)..<n { s -= m[r][c] * x[c] }
            x[r] = s / m[r][r]
        }
        return x
    }

    /// Sin quitar gradiente: desplaza cada canal para que los tres fondos coincidan.
    static func neutralizeBackground(_ img: inout LinearImage) {
        let meds = [quickMedian(img.r), quickMedian(img.g), quickMedian(img.b)]
        let target = meds.max() ?? 0
        func shift(_ c: inout [Float], _ d: Float) { for i in c.indices { c[i] += d } }
        shift(&img.r, target - meds[0]); shift(&img.g, target - meds[1]); shift(&img.b, target - meds[2])
    }

    /// Equilibrio de color: lleva rojo y azul hacia el verde según la mediana del color de muchas
    /// estrellas no saturadas (la mediana evita que unas pocas estrellas muy azules o rojas, como
    /// las de las Pléyades, lo dominen). La corrección se suaviza para no forzar el color.
    static func calibrateColor(_ img: inout LinearImage) {
        let bgR = quickMedian(img.r), bgG = quickMedian(img.g), bgB = quickMedian(img.b)
        let n = img.width * img.height
        var dev: [Float] = []
        var i = 0
        let step = max(1, n / 20000)
        while i < n { dev.append(abs(img.g[i] - bgG)); i += step }
        dev.sort()
        let sigma = max(1, dev[dev.count / 2] * 1.4826)
        var rr: [Float] = [], rb: [Float] = []
        for i in 0..<n {
            let r = img.r[i] - bgR, g = img.g[i] - bgG, b = img.b[i] - bgB
            guard g > 15 * sigma, g < 300 * sigma, r > 3 * sigma, b > 3 * sigma,
                  max(img.r[i], max(img.g[i], img.b[i])) < 58000 else { continue }
            rr.append(g / r); rb.append(g / b)
        }
        guard rr.count > 200 else { return }
        rr.sort(); rb.sort()
        let kr = Float(max(0.7, min(1.4, sqrt(Double(rr[rr.count / 2])))))
        let kb = Float(max(0.7, min(1.4, sqrt(Double(rb[rb.count / 2])))))
        for i in 0..<n {
            img.r[i] = max(0, (img.r[i] - bgR) * kr + bgR)
            img.b[i] = max(0, (img.b[i] - bgB) * kb + bgB)
        }
    }

    /// Desenfoque de caja separable (radio `r`), dos pasadas ≈ gaussiano.
    private static func boxBlur(_ c: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var a = c, b = c
        let norm = 1 / Float(2 * r + 1)
        for _ in 0..<2 {
            for y in 0..<h {
                let row = y * w
                var acc: Float = 0
                for k in -r...r { acc += a[row + min(w - 1, max(0, k))] }
                for x in 0..<w {
                    b[row + x] = acc * norm
                    acc += a[row + min(w - 1, x + r + 1)] - a[row + max(0, x - r)]
                }
            }
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += b[min(h - 1, max(0, k)) * w + x] }
                for y in 0..<h {
                    a[y * w + x] = acc * norm
                    acc += b[min(h - 1, y + r + 1) * w + x] - b[max(0, y - r) * w + x]
                }
            }
        }
        return a
    }

    /// Reduce el ruido de color (suaviza la diferencia de cada canal con la luminancia) y suaviza
    /// algo la luminancia solo en el fondo, sin tocar estrellas ni detalles brillantes.
    static func reduceNoise(_ img: inout LinearImage) {
        let w = img.width, h = img.height, n = w * h
        guard w > 8, h > 8 else { return }
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n { l[i] = (img.r[i] + img.g[i] + img.b[i]) / 3 }
        var cr = [Float](repeating: 0, count: n), cg = cr, cb = cr
        for i in 0..<n { cr[i] = img.r[i] - l[i]; cg[i] = img.g[i] - l[i]; cb[i] = img.b[i] - l[i] }
        cr = boxBlur(cr, w, h, 2); cg = boxBlur(cg, w, h, 2); cb = boxBlur(cb, w, h, 2)
        let ls = boxBlur(l, w, h, 1)
        let bg = quickMedian(l)
        var dev: [Float] = []
        var i = 0
        while i < n { dev.append(abs(l[i] - bg)); i += max(1, n / 20000) }
        dev.sort()
        let sigma = max(1, dev[dev.count / 2] * 1.4826)
        for i in 0..<n {
            // 1 en el fondo, 0 a partir de 8σ por encima.
            let t = max(0, min(1, (l[i] - bg) / (8 * sigma)))
            let k = 0.6 * (1 - t)
            let lum = l[i] * (1 - k) + ls[i] * k
            img.r[i] = max(0, lum + cr[i]); img.g[i] = max(0, lum + cg[i]); img.b[i] = max(0, lum + cb[i])
        }
    }

    // MARK: Estirado y salida

    static func render(_ input: LinearImage, options: ProcessingOptions) -> CGImage? {
        var img = input
        if options.cropEdges { img = cropStackEdges(img) }
        if options.removeGradient { subtractBackgroundModel(&img) }
        if options.colorBalance {
            neutralizeBackground(&img)
            calibrateColor(&img)
            neutralizeBackground(&img)
        }
        if options.denoise { reduceNoise(&img) }

        let stats = [medianMAD(img.r), medianMAD(img.g), medianMAD(img.b)]
        func params(_ s: (Float, Float)) -> (Double, Double) {
            let med = Double(s.0) / 65535, mad = Double(s.1) / 65535
            let c0 = max(0, med - options.shadowsClip * mad)
            let x = (med - c0) / max(1e-6, 1 - c0)
            let m = mtf(x, options.targetBackground)
            return (c0, m)
        }
        var p = stats.map(params)
        if options.linked {
            let c0 = p.map { $0.0 }.reduce(0, +) / 3
            let m = p.map { $0.1 }.reduce(0, +) / 3
            p = [(c0, m), (c0, m), (c0, m)]
        }
        // Tablas de 4096 entradas para acelerar el estirado.
        let lutSize = 4096
        let luts: [[Float]] = p.map { pair in
            let (c0, m) = pair
            return (0..<lutSize).map { i in
                let x = Double(i) / Double(lutSize - 1)
                let y = mtf((x - c0) / max(1e-6, 1 - c0), m)
                return Float(y)
            }
        }

        let n = img.width * img.height
        var rgba = [UInt8](repeating: 255, count: n * 4)
        let sat = Float(options.saturation)
        let scale = Float(lutSize - 1) / 65535
        rgba.withUnsafeMutableBufferPointer { out in
            for i in 0..<n {
                let ri = min(lutSize - 1, max(0, Int(img.r[i] * scale)))
                let gi = min(lutSize - 1, max(0, Int(img.g[i] * scale)))
                let bi = min(lutSize - 1, max(0, Int(img.b[i] * scale)))
                var r = luts[0][ri], g = luts[1][gi], b = luts[2][bi]
                if sat != 1 {
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // Menos saturación en el fondo oscuro para no realzar el ruido de color.
                    let t = max(0, min(1, (l - 0.12) / 0.35))
                    let k = 1 + (sat - 1) * t * t * (3 - 2 * t)
                    r = l + (r - l) * k; g = l + (g - l) * k; b = l + (b - l) * k
                }
                out[4 * i] = UInt8(max(0, min(255, r * 255)))
                out[4 * i + 1] = UInt8(max(0, min(255, g * 255)))
                out[4 * i + 2] = UInt8(max(0, min(255, b * 255)))
            }
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Guardado

    static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// FITS de 16 bits con los datos lineales, listo para Siril o GraXpert.
    static func saveFITS(_ img: LinearImage, to url: URL, object: String) throws {
        var header = ""
        func card(_ key: String, _ value: String, _ comment: String = "") {
            var line = key.padding(toLength: 8, withPad: " ", startingAt: 0) + "= "
            line += value.count < 20 ? String(repeating: " ", count: 20 - value.count) + value : value
            if !comment.isEmpty { line += " / " + comment }
            header += line.padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        card("SIMPLE", "T")
        card("BITPIX", "16")
        card("NAXIS", "3")
        card("NAXIS1", "\(img.width)")
        card("NAXIS2", "\(img.height)")
        card("NAXIS3", "3")
        card("BZERO", "32768")
        card("BSCALE", "1")
        // FITS solo admite ASCII imprimible y tarjetas de 80 bytes exactos.
        let safeName = String(String.UnicodeScalarView(object.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 && $0 != "'" }))
        card("OBJECT", "'\(safeName.prefix(60))'")
        card("CREATOR", "'Astrolabio'")
        let iso = ISO8601DateFormatter().string(from: Date())
        card("DATE", "'\(iso.prefix(19))'")
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while header.count % 2880 != 0 { header += " " }

        var data = Data(header.utf8)
        let planes = [img.r, img.g, img.b]
        data.reserveCapacity(data.count + img.width * img.height * 6 + 2880)
        for plane in planes {
            // FITS guarda las filas de abajo arriba.
            for y in stride(from: img.height - 1, through: 0, by: -1) {
                var row = [UInt8](repeating: 0, count: img.width * 2)
                for x in 0..<img.width {
                    let v = Int(max(0, min(65535, plane[y * img.width + x]))) - 32768
                    let u = UInt16(bitPattern: Int16(v))
                    row[2 * x] = UInt8(u >> 8)
                    row[2 * x + 1] = UInt8(u & 0xFF)
                }
                data.append(contentsOf: row)
            }
        }
        let pad = (2880 - data.count % 2880) % 2880
        data.append(Data(count: pad))
        try data.write(to: url)
    }
}
