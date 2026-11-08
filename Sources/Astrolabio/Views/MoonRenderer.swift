import SwiftUI
import ImageIO

/// Dibuja la Luna tal como se ve: el mapa real de la superficie proyectado sobre una esfera e
/// iluminado desde la dirección del Sol (fase correcta, terminador suave, oscurecimiento hacia
/// el borde y un poco de luz cenicienta en la parte oscura).
enum MoonRenderer {
    private struct Texture { let w: Int; let h: Int; let rgb: [UInt8] }

    private static let texture: Texture? = {
        guard let data = MoonTexture.data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[3 * i] = px[4 * i]; rgb[3 * i + 1] = px[4 * i + 1]; rgb[3 * i + 2] = px[4 * i + 2] }
        return Texture(w: w, h: h, rgb: rgb)
    }()

    /// `elongation`: ángulo Luna−Sol en longitud eclíptica (0 nueva, 90 cuarto creciente,
    /// 180 llena, 270 cuarto menguante). Con `northUp` el creciente se ilumina por la derecha,
    /// como se ve desde el hemisferio norte.
    static func render(size: Int, elongation: Double, earthshine: Double = 0.06) -> CGImage? {
        render(size: size, geometry: MoonGeometry(l: 0, b: 0, l0: 180 - elongation, b0: 0), earthshine: earthshine)
    }

    /// Con libración: la cara que se ve y la luz del Sol corresponden a la fecha de `geometry`. Norte arriba.
    static func render(size: Int, geometry g: MoonGeometry, earthshine: Double = 0.06) -> CGImage? {
        guard let tex = texture, size > 8 else { return nil }
        // Dirección del Sol en el sistema del observador (x a la derecha, y arriba, z hacia nosotros).
        let sun = MoonFeatures.sunInView(g)
        let basis = MoonFeatures.viewBasis(g)
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let r = Double(size) / 2 - 1
        for py in 0..<size {
            let y = (r - Double(py) + 0.5) / r
            for px in 0..<size {
                let x = (Double(px) - r + 0.5) / r
                let d2 = x * x + y * y
                let o = 4 * (py * size + px)
                guard d2 <= 1 else { continue }
                let z = sqrt(1 - d2)
                // Coordenadas selenográficas del punto (con la libración del día).
                let m = x * basis.x + y * basis.y + z * basis.z
                let lon = atan2(m.x, m.z), lat = asin(max(-1, min(1, m.y)))
                let u = (lon / (2 * Double.pi) + 0.5) * Double(tex.w)
                let v = (0.5 - lat / Double.pi) * Double(tex.h)
                let tu = min(tex.w - 1, max(0, Int(u))), tv = min(tex.h - 1, max(0, Int(v)))
                let ti = 3 * (tv * tex.w + tu)
                // Iluminación: ley de Lommel-Seeliger (la Luna no se oscurece como una esfera mate)
                // con un terminador suavizado y luz cenicienta tenue.
                let mu0 = x * sun.x + y * sun.y + z * sun.z           // coseno del ángulo con el Sol
                let mu = z                            // coseno del ángulo con el observador
                let soft = max(0, min(1, (mu0 + 0.04) / 0.08))
                let lit = mu0 > 0 ? 2 * mu0 / (mu0 + mu) : 0
                let light = max(lit * soft, 0) * 1.05 + earthshine * (1 - soft) * (0.6 + 0.4 * mu)
                // Ligero tono neutro-frío para que no parezca sepia en el tema azul.
                let edge = d2 > 0.985 ? max(0, (1 - d2) / 0.015) : 1      // borde suavizado
                out[o] = UInt8(max(0, min(255, Double(tex.rgb[ti]) * light * 0.98)))
                out[o + 1] = UInt8(max(0, min(255, Double(tex.rgb[ti + 1]) * light)))
                out[o + 2] = UInt8(max(0, min(255, Double(tex.rgb[ti + 2]) * light * 1.04)))
                out[o + 3] = UInt8(255 * edge)
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Vista de la Luna realista para una fecha.
struct RealisticMoon: View {
    let date: Date
    var pixelSize = 520
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high) }
            else { Circle().fill(Color(white: 0.12)) }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: Int(date.timeIntervalSince1970 / 600)) {
            let g = MoonFeatures.geometry(date), s = pixelSize
            image = await Task.detached { MoonRenderer.render(size: s, geometry: g) }.value
        }
    }
}
