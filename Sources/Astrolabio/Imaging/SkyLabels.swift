import Foundation
import CoreGraphics
import CoreText

/// Solución astrométrica de una imagen (proyección gnomónica TAN), en píxeles de la imagen tal
/// como se muestra (fila 0 arriba).
struct ImageWCS: Equatable {
    var raDeg: Double          // centro de referencia
    var decDeg: Double
    var refX: Double           // píxel de referencia (0 = izquierda)
    var refY: Double           // (0 = arriba)
    /// Matriz CD en grados por píxel, con el eje Y hacia abajo.
    var cd11: Double, cd12: Double, cd21: Double, cd22: Double
    /// true si viene de la cabecera FITS; false si es una estimación (centro + campo, norte arriba).
    var solved: Bool

    /// Lee WCS de una cabecera FITS (CD o CDELT/CROTA2). `height` hace falta para dar la vuelta al eje Y.
    static func fromFITS(_ h: [String: String], width: Int, height: Int) -> ImageWCS? {
        func d(_ k: String) -> Double? { h[k].flatMap { Double($0.replacingOccurrences(of: "D", with: "E")) } }
        guard let ra = d("CRVAL1"), let dec = d("CRVAL2"), let px = d("CRPIX1"), let py = d("CRPIX2") else { return nil }
        var c11 = d("CD1_1"), c12 = d("CD1_2"), c21 = d("CD2_1"), c22 = d("CD2_2")
        if c11 == nil, let s1 = d("CDELT1"), let s2 = d("CDELT2") {
            let rot = (d("CROTA2") ?? 0) * .pi / 180
            c11 = s1 * cos(rot); c12 = -s2 * sin(rot); c21 = s1 * sin(rot); c22 = s2 * cos(rot)
        }
        guard let a = c11, let e = c22 else { return nil }
        let b = c12 ?? 0, c = c21 ?? 0
        guard a != 0 || b != 0 else { return nil }
        // FITS: píxel 1 abajo; aquí la fila 0 está arriba → se invierte el eje Y.
        return ImageWCS(raDeg: ra, decDeg: dec, refX: px - 1, refY: Double(height) - py,
                        cd11: a, cd12: -b, cd21: c, cd22: -e, solved: true)
    }

    /// Estimación sin solución: centro conocido, escala del campo del Seestar y norte arriba, este a la izquierda.
    static func estimate(raHours: Double, decDeg: Double, width: Int, height: Int, fovWidthDeg: Double) -> ImageWCS {
        let scale = fovWidthDeg / Double(min(width, height))
        return ImageWCS(raDeg: raHours * 15, decDeg: decDeg, refX: Double(width) / 2, refY: Double(height) / 2,
                        cd11: -scale, cd12: 0, cd21: 0, cd22: -scale, solved: false)
    }

    /// Cielo → píxel. nil si el punto está detrás del plano de proyección.
    func pixel(raDeg: Double, decDeg: Double) -> CGPoint? {
        let r = Double.pi / 180
        let a = raDeg * r, d = decDeg * r, a0 = raDeg0 * r, d0 = self.decDeg * r
        let cosc = sin(d0) * sin(d) + cos(d0) * cos(d) * cos(a - a0)
        guard cosc > 0.1 else { return nil }
        let xi = cos(d) * sin(a - a0) / cosc / r
        let eta = (cos(d0) * sin(d) - sin(d0) * cos(d) * cos(a - a0)) / cosc / r
        let det = cd11 * cd22 - cd12 * cd21
        guard det != 0 else { return nil }
        let dx = (cd22 * xi - cd12 * eta) / det
        let dy = (-cd21 * xi + cd11 * eta) / det
        return CGPoint(x: refX + dx, y: refY + dy)
    }
    private var raDeg0: Double { raDeg }

    /// Escala media en segundos de arco por píxel.
    var arcsecPerPixel: Double { sqrt(abs(cd11 * cd22 - cd12 * cd21)) * 3600 }
}

struct SkyLabel: Equatable {
    let id: String
    let name: String
    let point: CGPoint
    let radius: Double
}

enum SkyLabels {
    /// Objetos del catálogo que caen dentro de la imagen.
    static func labels(_ wcs: ImageWCS, width: Int, height: Int, maxLabels: Int = 25) -> [SkyLabel] {
        let pxPerArcmin = 60 / max(1e-6, wcs.arcsecPerPixel)
        return Catalog.objects.compactMap { o -> SkyLabel? in
            guard let p = wcs.pixel(raDeg: o.raHours * 15, decDeg: o.decDeg),
                  p.x >= 0, p.y >= 0, p.x < Double(width), p.y < Double(height) else { return nil }
            return SkyLabel(id: o.id, name: o.localizedName, point: p, radius: max(12, o.sizeArcmin * pxPerArcmin / 2))
        }
        .sorted { a, b in (Catalog.find(a.id)?.magnitude ?? 20) < (Catalog.find(b.id)?.magnitude ?? 20) }
        .prefix(maxLabels).map { $0 }
    }

    /// Direcciones del norte y del este (vectores unitarios en la imagen) en el centro.
    static func compass(_ wcs: ImageWCS, width: Int, height: Int) -> (north: CGVector, east: CGVector)? {
        let cx = Double(width) / 2, cy = Double(height) / 2
        // Centro en el cielo: el de referencia (vale para el centro en las estimaciones y aproxima en las soluciones).
        guard let c = wcs.pixel(raDeg: wcs.raDeg, decDeg: wcs.decDeg),
              let n = wcs.pixel(raDeg: wcs.raDeg, decDeg: min(89.9, wcs.decDeg + 0.1)),
              let e = wcs.pixel(raDeg: wcs.raDeg + 0.1 / max(0.05, cos(wcs.decDeg * .pi / 180)), decDeg: wcs.decDeg) else { return nil }
        _ = (cx, cy)
        func unit(_ p: CGPoint) -> CGVector {
            let dx = p.x - c.x, dy = p.y - c.y, l = max(1e-9, hypot(dx, dy))
            return CGVector(dx: dx / l, dy: dy / l)
        }
        return (unit(n), unit(e))
    }

    /// Copia de la imagen con círculos, nombres y la rosa N/E.
    static func draw(on image: CGImage, wcs: ImageWCS) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let size = max(11, CGFloat(min(w, h)) * 0.022)
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let color = CGColor(red: 0.55, green: 0.8, blue: 1, alpha: 0.9)
        func text(_ s: String, _ p: CGPoint) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.textPosition = CGPoint(x: p.x, y: CGFloat(h) - p.y)
            CTLineDraw(line, ctx)
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1, size / 8))
        for l in labels(wcs, width: w, height: h) {
            let r = CGFloat(l.radius)
            ctx.strokeEllipse(in: CGRect(x: l.point.x - r, y: CGFloat(h) - l.point.y - r, width: 2 * r, height: 2 * r))
            text(l.name.isEmpty ? l.id : "\(l.id) · \(l.name)", CGPoint(x: l.point.x + r * 0.75, y: l.point.y - r * 0.75))
        }
        if let c = compass(wcs, width: w, height: h) {
            let o = CGPoint(x: CGFloat(w) - size * 4, y: size * 4)
            let len = size * 2.6
            for (v, name) in [(c.north, "N"), (c.east, "E")] {
                ctx.move(to: CGPoint(x: o.x, y: CGFloat(h) - o.y))
                ctx.addLine(to: CGPoint(x: o.x + v.dx * len, y: CGFloat(h) - (o.y + v.dy * len)))
                ctx.strokePath()
                text(tr(name), CGPoint(x: o.x + v.dx * (len + size * 0.6) - size * 0.3, y: o.y + v.dy * (len + size * 0.6) + size * 0.3))
            }
        }
        if !wcs.solved {
            text(tr("Posiciones aproximadas: la imagen no tiene solución astrométrica"), CGPoint(x: size, y: CGFloat(h) - size))
        }
        return ctx.makeImage()
    }

    /// Centro aproximado de una imagen del Seestar: cabecera (RA/DEC u OBJCTRA) o el objeto del nombre del archivo.
    static func approximateCenter(header: [String: String], name: String) -> (raHours: Double, decDeg: Double)? {
        if let ra = header["RA"].flatMap(Double.init), let dec = header["DEC"].flatMap(Double.init) { return (ra / 15, dec) }
        if let ra = header["OBJCTRA"].flatMap(Astro.parseRA), let dec = header["OBJCTDEC"].flatMap(Astro.parseDec) { return (ra, dec) }
        // «Stacked_25_M 45_30.0s_IRCUT_20261030-234613» → «M 45».
        let parts = name.split(separator: "_").map(String.init)
        for k in parts.indices.reversed() {
            for len in 1...2 where k + len <= parts.count {
                if let o = Catalog.find(parts[k..<(k + len)].joined(separator: " ")) { return (o.raHours, o.decDeg) }
            }
        }
        if let h = header["OBJECT"], let o = Catalog.find(h) { return (o.raHours, o.decDeg) }
        return nil
    }
}
