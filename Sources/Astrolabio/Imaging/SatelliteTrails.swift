import Foundation
import CoreGraphics

/// Traza recta (satélite o avión) en coordenadas de píxel de la imagen.
struct SatelliteTrail: Identifiable, Equatable {
    let id = UUID()
    var p1: CGPoint
    var p2: CGPoint
    /// Anchura que se limpia a cada lado de la línea (píxeles).
    var halfWidth: Double = 3
    var enabled = true
    var manual = false

    static func == (a: SatelliteTrail, b: SatelliteTrail) -> Bool {
        a.p1 == b.p1 && a.p2 == b.p2 && a.halfWidth == b.halfWidth && a.enabled == b.enabled && a.manual == b.manual
    }

    var length: Double { hypot(p2.x - p1.x, p2.y - p1.y) }
}

enum SatelliteTrails {
    /// Busca líneas rectas largas y brillantes con la transformada de Hough sobre una copia reducida.
    /// Las estrellas son puntos y no forman líneas; las trazas cruzan buena parte de la imagen.
    static func detect(_ img: LinearImage, maxTrails: Int = 6) -> [SatelliteTrail] {
        let scale = max(1, Int(ceil(Double(max(img.width, img.height)) / 700)))
        let w = img.width / scale, h = img.height / scale
        guard w > 32, h > 32 else { return [] }
        // Luminancia reducida y quitado el fondo local.
        var l = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var s: Float = 0
            for dy in 0..<scale { for dx in 0..<scale {
                let i = (y * scale + dy) * img.width + x * scale + dx
                s += 0.2126 * img.r[i] + 0.7152 * img.g[i] + 0.0722 * img.b[i]
            } }
            l[y * w + x] = s / Float(scale * scale)
        } }
        let bgMap = PhotoEditor.boxBlur(l, w, h, 8)
        let resid = zip(l, bgMap).map { $0 - $1 }
        let (_, sigma) = PhotoEditor.backgroundStats(resid)
        // Píxeles brillantes, quitando los núcleos de estrella (muy brillantes y aislados).
        let thr = 2.5 * sigma
        var edge = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where resid[i] > thr { edge[i] = true }
        // Hough: θ en pasos de 1°, ρ en píxeles.
        let nTheta = 180
        let diag = Int(ceil(hypot(Double(w), Double(h))))
        let nRho = 2 * diag + 1
        var acc = [Int32](repeating: 0, count: nTheta * nRho)
        let cosT = (0..<nTheta).map { cos(Double($0) * .pi / 180) }, sinT = (0..<nTheta).map { sin(Double($0) * .pi / 180) }
        for y in 0..<h { for x in 0..<w where edge[y * w + x] {
            for t in 0..<nTheta {
                let rho = Int((Double(x) * cosT[t] + Double(y) * sinT[t]).rounded()) + diag
                acc[t * nRho + rho] += 1
            }
        } }
        let minVotes = Int32(Double(min(w, h)) * 0.25)
        var found: [(t: Int, rho: Int, votes: Int32)] = []
        var a = acc
        for _ in 0..<maxTrails {
            guard let (idx, votes) = a.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }), votes >= minVotes else { break }
            let t = idx / nRho, rho = idx % nRho
            found.append((t, rho, votes))
            // Suprime el entorno para no repetir la misma línea.
            for dt in -8...8 { for dr in -12...12 {
                let tt = (t + dt + nTheta) % nTheta, rr = rho + dr
                if rr >= 0 && rr < nRho { a[tt * nRho + rr] = 0 }
            } }
        }
        // Extremos: primer y último píxel brillante a lo largo de la línea.
        let candidates = found.compactMap { f -> SatelliteTrail? in
            let c = cosT[f.t], s = sinT[f.t], r = Double(f.rho - diag)
            var pts: [CGPoint] = []
            let x0 = c * r, y0 = s * r          // punto de la recta más cercano al origen
            for k in -diag...diag {
                let x = x0 - s * Double(k), y = y0 + c * Double(k)
                let xi = Int(x.rounded()), yi = Int(y.rounded())
                guard xi >= 0, yi >= 0, xi < w, yi < h else { continue }
                var hit = false
                for d in -1...1 {
                    let xx = Int((x + c * Double(d)).rounded()), yy = Int((y + s * Double(d)).rounded())
                    if xx >= 0, yy >= 0, xx < w, yy < h, edge[yy * w + xx] { hit = true }
                }
                if hit { pts.append(CGPoint(x: x, y: y)) }
            }
            guard pts.count >= Int(minVotes) / 2, let first = pts.first, let last = pts.last else { return nil }
            let len = hypot(last.x - first.x, last.y - first.y)
            // Una línea real llena la mayor parte de su longitud (las alineaciones casuales de estrellas no).
            guard len >= Double(min(w, h)) * 0.3, Double(pts.count) >= len * 0.6 else { return nil }
            let sc = CGFloat(scale)
            return SatelliteTrail(p1: CGPoint(x: first.x * sc, y: first.y * sc), p2: CGPoint(x: last.x * sc, y: last.y * sc),
                                  halfWidth: Double(2 * scale + 1))
        }
        // Una traza gruesa da varias líneas casi iguales: se queda la primera (la de más votos).
        var out: [SatelliteTrail] = []
        for c in candidates where !out.contains(where: { isSameLine($0, c, tolerance: Double(4 * scale + 6)) }) {
            out.append(c)
        }
        return out
    }

    /// Distancia de un punto a la recta que pasa por una traza.
    static func distance(_ p: CGPoint, to t: SatelliteTrail) -> Double {
        guard t.length > 0 else { return hypot(p.x - t.p1.x, p.y - t.p1.y) }
        return abs((t.p2.x - t.p1.x) * (t.p1.y - p.y) - (t.p1.x - p.x) * (t.p2.y - t.p1.y)) / t.length
    }

    static func isSameLine(_ a: SatelliteTrail, _ b: SatelliteTrail, tolerance: Double) -> Bool {
        distance(b.p1, to: a) < tolerance && distance(b.p2, to: a) < tolerance
    }

    /// Sustituye los píxeles de cada traza por el fondo de ambos lados de la línea.
    static func remove(_ trails: [SatelliteTrail], from img: inout LinearImage) {
        let w = img.width, h = img.height
        for t in trails where t.enabled && t.length > 1 {
            let dx = (t.p2.x - t.p1.x) / t.length, dy = (t.p2.y - t.p1.y) / t.length
            let nx = -dy, ny = dx
            let hw = t.halfWidth
            let steps = Int(t.length.rounded())
            for k in 0...steps {
                let cx = t.p1.x + dx * Double(k), cy = t.p1.y + dy * Double(k)
                // Fondo: media de dos muestras a cada lado, fuera de la traza.
                func sample(_ off: Double) -> (Float, Float, Float)? {
                    let x = Int((cx + nx * off).rounded()), y = Int((cy + ny * off).rounded())
                    guard x >= 0, y >= 0, x < w, y < h else { return nil }
                    let i = y * w + x
                    return (img.r[i], img.g[i], img.b[i])
                }
                let side = [sample(hw + 3), sample(-(hw + 3)), sample(hw + 5), sample(-(hw + 5))].compactMap { $0 }
                guard !side.isEmpty else { continue }
                let n = Float(side.count)
                let fill = (side.map(\.0).reduce(0, +) / n, side.map(\.1).reduce(0, +) / n, side.map(\.2).reduce(0, +) / n)
                var o = -hw
                while o <= hw {
                    let x = Int((cx + nx * o).rounded()), y = Int((cy + ny * o).rounded())
                    if x >= 0, y >= 0, x < w, y < h {
                        let i = y * w + x
                        img.r[i] = fill.0; img.g[i] = fill.1; img.b[i] = fill.2
                    }
                    o += 0.5
                }
            }
        }
    }
}
