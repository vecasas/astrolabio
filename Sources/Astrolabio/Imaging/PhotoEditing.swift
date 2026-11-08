import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Proporción del recorte.
enum CropAspect: String, CaseIterable, Identifiable, Codable {
    case original = "Original", wide = "16:9", square = "Cuadrado", portrait = "4:5", free = "Libre"
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .wide: return 16.0 / 9
        case .square: return 1
        case .portrait: return 4.0 / 5
        default: return nil
        }
    }
}

/// Ajustes del retoque. El original nunca se modifica: todo se aplica a una copia al exportar.
struct PhotoEdit: Codable, Equatable {
    var removeGradient = true
    var neutralBackground = true
    var blackPoint = 0.3          // 0–1
    var brightness = 0.4          // 0–1
    var noise = 0.4               // 0–1, ruido de luminancia en el fondo
    var colorNoise = 0.5          // 0–1
    var sharpen = 0.2             // 0–1
    var saturation = 1.3          // 0–2
    var starReduction = 0.0       // 0–1
    var crop: CropAspect = .original
    /// Recorte libre en coordenadas normalizadas (0–1).
    var freeCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    var caption = false
}

/// Imagen abierta en el editor: los datos (en escala 0–65535) y si son lineales (FITS) o ya estirados (JPEG).
struct EditableImage {
    var image: LinearImage
    let isLinear: Bool
    let name: String
    /// Cabecera FITS, si la hay (para la posición en el cielo).
    var header: [String: String] = [:]
}

enum PhotoEditor {
    /// Imágenes de más de 100 megapíxeles no son del Seestar: se rechazan para no agotar la memoria.
    static let maxPixels = 100_000_000
    static let maxFileBytes = 1_000_000_000

    enum LoadError: LocalizedError {
        case unreadable, tooBig
        var errorDescription: String? {
            switch self {
            case .unreadable: return tr("No se pudo abrir la imagen.")
            case .tooBig: return tr("La imagen es demasiado grande.")
            }
        }
    }

    // MARK: Abrir

    static func load(_ url: URL) throws -> EditableImage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw LoadError.unreadable }
        guard size <= maxFileBytes else { throw LoadError.tooBig }
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        if ["fit", "fits", "fts"].contains(ext) {
            let data = try Data(contentsOf: url)
            guard let (img, header) = readFITS(data) else { throw LoadError.unreadable }
            return EditableImage(image: img, isLinear: true, name: name, header: header)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw LoadError.unreadable }
        guard cg.width * cg.height <= maxPixels else { throw LoadError.tooBig }
        return EditableImage(image: linear(from: cg), isLinear: false, name: name)
    }

    /// CGImage → planos 0–65535 (sin quitar la gamma: la imagen ya viene estirada).
    static func linear(from cg: CGImage) -> LinearImage {
        let w = cg.width, h = cg.height
        var px = [UInt16](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for i in 0..<(w * h) { r[i] = Float(px[4 * i]); g[i] = Float(px[4 * i + 1]); b[i] = Float(px[4 * i + 2]) }
        return LinearImage(width: w, height: h, r: r, g: g, b: b)
    }

    /// Lector FITS para 8/16/32 bits enteros y 32/64 bits flotantes, 2D (gris) o 3D (RGB).
    static func readFITS(_ data: Data) -> (LinearImage, [String: String])? {
        var header: [String: String] = [:]
        var offset = 0
        var ended = false
        while offset + 2880 <= data.count && !ended {
            for k in 0..<36 {
                let start = offset + k * 80
                let card = String(decoding: data[(data.startIndex + start)..<(data.startIndex + start + 80)], as: UTF8.self)
                let key = card.prefix(8).trimmingCharacters(in: .whitespaces)
                if key == "END" { ended = true; break }
                guard card.count >= 10, card.dropFirst(8).hasPrefix("= ") else { continue }
                var value = String(card.dropFirst(10))
                if let slash = value.range(of: " /"), !value.trimmingCharacters(in: .whitespaces).hasPrefix("'") { value = String(value[..<slash.lowerBound]) }
                header[key] = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'")).trimmingCharacters(in: .whitespaces)
            }
            offset += 2880
        }
        guard ended, let bitpix = Int(header["BITPIX"] ?? ""), let naxis = Int(header["NAXIS"] ?? ""), naxis >= 2,
              let w = Int(header["NAXIS1"] ?? ""), let h = Int(header["NAXIS2"] ?? ""), w > 0, h > 0, w * h <= maxPixels else { return nil }
        let planes = naxis >= 3 ? max(1, min(3, Int(header["NAXIS3"] ?? "1") ?? 1)) : 1
        let bytes = abs(bitpix) / 8
        guard [1, 2, 4, 8].contains(bytes), offset + w * h * planes * bytes <= data.count else { return nil }
        let bzero = Double(header["BZERO"] ?? "") ?? 0, bscale = Double(header["BSCALE"] ?? "") ?? 1
        var raw = [Double](repeating: 0, count: w * h * planes)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let base = p.baseAddress!.advanced(by: offset)
            for i in 0..<raw.count {
                let q = base.advanced(by: i * bytes)
                let v: Double
                switch bitpix {
                case 8: v = Double(q.load(as: UInt8.self))
                case 16: v = Double(Int16(bigEndian: q.loadUnaligned(as: Int16.self)))
                case 32: v = Double(Int32(bigEndian: q.loadUnaligned(as: Int32.self)))
                case -32: v = Double(Float(bitPattern: UInt32(bigEndian: q.loadUnaligned(as: UInt32.self))))
                case -64: v = Double(bitPattern: UInt64(bigEndian: q.loadUnaligned(as: UInt64.self)))
                default: v = 0
                }
                raw[i] = v.isFinite ? bzero + bscale * v : 0
            }
        }
        // Escala a 0–65535 (los flotantes suelen venir en 0–1).
        let maxV = raw.max() ?? 1
        let k = bitpix < 0 && maxV <= 1.5 ? 65535.0 : (bitpix == 8 ? 257.0 : (maxV > 65535 ? 65535 / maxV : 1))
        func plane(_ p: Int) -> [Float] { (0..<(w * h)).map { Float(max(0, raw[min(p, planes - 1) * w * h + $0] * k)) } }
        // FITS guarda la primera fila abajo.
        func flip(_ c: [Float]) -> [Float] {
            var o = c
            for y in 0..<h { for x in 0..<w { o[y * w + x] = c[(h - 1 - y) * w + x] } }
            return o
        }
        return (LinearImage(width: w, height: h, r: flip(plane(0)), g: flip(plane(1)), b: flip(plane(2))), header)
    }

    // MARK: Procesado

    /// Pasos sobre los datos (antes del estirado). Las trazas de satélite se quitan primero.
    static func process(_ input: EditableImage, _ e: PhotoEdit, trails: [SatelliteTrail] = []) -> LinearImage {
        var img = input.image
        if !trails.isEmpty { SatelliteTrails.remove(trails, from: &img) }
        if e.removeGradient { ImageProcessing.subtractBackgroundModel(&img) }
        if e.neutralBackground {
            ImageProcessing.neutralizeBackground(&img)
            if input.isLinear { ImageProcessing.calibrateColor(&img); ImageProcessing.neutralizeBackground(&img) }
        }
        if e.colorNoise > 0 { reduceColorNoise(&img, amount: Float(e.colorNoise)) }
        if e.noise > 0 { reduceLuminanceNoise(&img, amount: Float(e.noise)) }
        if e.starReduction > 0 { reduceStars(&img, amount: Float(e.starReduction)) }
        if e.sharpen > 0 { sharpen(&img, amount: Float(e.sharpen)) }
        return img
    }

    static func boxBlur(_ c: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        guard r > 0 else { return c }
        var tmp = c, out = c
        for y in 0..<h {
            var acc: Float = 0
            let row = y * w
            for x in -r...r { acc += c[row + min(w - 1, max(0, x))] }
            for x in 0..<w {
                tmp[row + x] = acc / Float(2 * r + 1)
                acc += c[row + min(w - 1, x + r + 1)] - c[row + max(0, x - r)]
            }
        }
        for x in 0..<w {
            var acc: Float = 0
            for y in -r...r { acc += tmp[min(h - 1, max(0, y)) * w + x] }
            for y in 0..<h {
                out[y * w + x] = acc / Float(2 * r + 1)
                acc += tmp[min(h - 1, y + r + 1) * w + x] - tmp[max(0, y - r) * w + x]
            }
        }
        return out
    }

    static func luminance(_ img: LinearImage) -> [Float] {
        (0..<(img.width * img.height)).map { 0.2126 * img.r[$0] + 0.7152 * img.g[$0] + 0.0722 * img.b[$0] }
    }

    /// Suaviza el color (no la luz): quita las manchas de color del ruido.
    static func reduceColorNoise(_ img: inout LinearImage, amount: Float) {
        let w = img.width, h = img.height
        let l = luminance(img)
        let r = max(1, Int((amount * 4).rounded()))
        let cr = boxBlur(zip(img.r, l).map { $0 - $1 }, w, h, r)
        let cb = boxBlur(zip(img.b, l).map { $0 - $1 }, w, h, r)
        let cg = boxBlur(zip(img.g, l).map { $0 - $1 }, w, h, r)
        for i in 0..<(w * h) {
            let k = min(1, amount * 1.2)
            img.r[i] = max(0, img.r[i] * (1 - k) + (l[i] + cr[i]) * k)
            img.g[i] = max(0, img.g[i] * (1 - k) + (l[i] + cg[i]) * k)
            img.b[i] = max(0, img.b[i] * (1 - k) + (l[i] + cb[i]) * k)
        }
    }

    /// Suaviza el fondo y deja intactas las estrellas y la nebulosa brillante.
    static func reduceLuminanceNoise(_ img: inout LinearImage, amount: Float) {
        let w = img.width, h = img.height, n = w * h
        let l = luminance(img)
        let ls = boxBlur(l, w, h, 1 + Int(amount * 2))
        let (bg, sigma) = backgroundStats(l)
        for i in 0..<n {
            let t = max(0, min(1, (l[i] - bg) / (6 * sigma)))
            let k = amount * 0.8 * (1 - t)
            let target = l[i] * (1 - k) + ls[i] * k
            let f = l[i] > 1 ? target / l[i] : 1
            img.r[i] *= f; img.g[i] *= f; img.b[i] *= f
        }
    }

    static func backgroundStats(_ l: [Float]) -> (Float, Float) {
        var s: [Float] = []
        var i = 0
        let step = max(1, l.count / 20000)
        while i < l.count { s.append(l[i]); i += step }
        s.sort()
        let med = s.isEmpty ? 0 : s[s.count / 2]
        var d = s.map { abs($0 - med) }
        d.sort()
        return (med, max(1, d.isEmpty ? 1 : d[d.count / 2] * 1.4826))
    }

    /// Reduce las estrellas: donde hay una estrella (punto mucho más brillante que su entorno) se
    /// mezcla la imagen con su versión «erosionada» (mínimo 3×3), que las hace más pequeñas y tenues.
    static func reduceStars(_ img: inout LinearImage, amount: Float) {
        let w = img.width, h = img.height
        guard w > 4, h > 4 else { return }
        let l = luminance(img)
        let local = boxBlur(l, w, h, 6)
        let (_, sigma) = backgroundStats(l)
        func erode(_ c: [Float]) -> [Float] {
            var o = c
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                var m = c[y * w + x]
                for dy in -1...1 { for dx in -1...1 { m = min(m, c[(y + dy) * w + x + dx]) } }
                o[y * w + x] = m
            } }
            return o
        }
        var mask = (0..<(w * h)).map { i -> Float in max(0, min(1, (l[i] - local[i] - 4 * sigma) / (10 * sigma))) }
        mask = boxBlur(mask, w, h, 1).map { min(1, $0 * 2) * amount }
        let er = erode(img.r), eg = erode(img.g), eb = erode(img.b)
        for i in 0..<(w * h) {
            let k = mask[i]
            img.r[i] = img.r[i] * (1 - k) + er[i] * k
            img.g[i] = img.g[i] * (1 - k) + eg[i] * k
            img.b[i] = img.b[i] * (1 - k) + eb[i] * k
        }
    }

    /// Enfoque (máscara de desenfoque) sobre la luz, sin realzar el ruido del fondo.
    static func sharpen(_ img: inout LinearImage, amount: Float) {
        let w = img.width, h = img.height
        let l = luminance(img)
        let bl = boxBlur(l, w, h, 2)
        let (bg, sigma) = backgroundStats(l)
        for i in 0..<(w * h) {
            let t = max(0, min(1, (l[i] - bg) / (5 * sigma)))
            let nl = max(0, l[i] + amount * 1.5 * t * (l[i] - bl[i]))
            let f = l[i] > 1 ? nl / l[i] : 1
            img.r[i] *= f; img.g[i] *= f; img.b[i] *= f
        }
    }

    // MARK: Estirado y salida

    static func mtf(_ x: Double, _ m: Double) -> Double { ImageProcessing.mtf(x, m) }

    /// Imagen final en RGB 0–1 (después del estirado, la saturación y el recorte).
    static func stretched(_ img: LinearImage, isLinear: Bool, _ e: PhotoEdit) -> (w: Int, h: Int, rgb: [Float]) {
        let n = img.width * img.height
        var out = [Float](repeating: 0, count: n * 3)
        let l = luminance(img)
        let (bg, sigma) = backgroundStats(l)
        // Lineal: el fondo va a «brillo»; ya estirada: niveles (punto negro) y gamma.
        let target = 0.06 + e.brightness * 0.26
        let c0: Double, m: Double
        if isLinear {
            c0 = max(0, (Double(bg) - (1 + 3 * (1 - e.blackPoint)) * Double(sigma))) / 65535
            let x = (Double(bg) / 65535 - c0) / max(1e-6, 1 - c0)
            m = mtf(x, target)
        } else {
            c0 = e.blackPoint * 0.25
            m = 0.5 - (e.brightness - 0.4) * 0.6
        }
        let sat = Float(e.saturation)
        for i in 0..<n {
            func s(_ v: Float) -> Float { Float(mtf((Double(v) / 65535 - c0) / max(1e-6, 1 - c0), m)) }
            var r = s(img.r[i]), g = s(img.g[i]), b = s(img.b[i])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let t = max(0, min(1, (lum - 0.1) / 0.3))
            let k = 1 + (sat - 1) * t
            r = lum + (r - lum) * k; g = lum + (g - lum) * k; b = lum + (b - lum) * k
            out[3 * i] = max(0, min(1, r)); out[3 * i + 1] = max(0, min(1, g)); out[3 * i + 2] = max(0, min(1, b))
        }
        return crop((img.width, img.height, out), e)
    }

    static func cropRect(width w: Int, height h: Int, _ e: PhotoEdit) -> CGRect {
        switch e.crop {
        case .original: return CGRect(x: 0, y: 0, width: w, height: h)
        case .free:
            let r = e.freeCrop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return CGRect(x: Int(r.minX * Double(w)), y: Int(r.minY * Double(h)),
                          width: max(1, Int(r.width * Double(w))), height: max(1, Int(r.height * Double(h))))
        default:
            let ratio = e.crop.ratio ?? 1
            var cw = Double(w), ch = cw / ratio
            if ch > Double(h) { ch = Double(h); cw = ch * ratio }
            return CGRect(x: (Double(w) - cw) / 2, y: (Double(h) - ch) / 2, width: cw, height: ch).integral
        }
    }

    static func crop(_ img: (w: Int, h: Int, rgb: [Float]), _ e: PhotoEdit) -> (w: Int, h: Int, rgb: [Float]) {
        let r = cropRect(width: img.w, height: img.h, e)
        let x0 = max(0, Int(r.minX)), y0 = max(0, Int(r.minY))
        let cw = min(img.w - x0, Int(r.width)), ch = min(img.h - y0, Int(r.height))
        guard cw > 0, ch > 0, (cw, ch) != (img.w, img.h) else { return img }
        var out = [Float](repeating: 0, count: cw * ch * 3)
        for y in 0..<ch {
            let src = ((y0 + y) * img.w + x0) * 3
            out.replaceSubrange((y * cw * 3)..<((y + 1) * cw * 3), with: img.rgb[src..<(src + cw * 3)])
        }
        return (cw, ch, out)
    }

    static func cgImage(_ img: (w: Int, h: Int, rgb: [Float]), bits16: Bool = false) -> CGImage? {
        let n = img.w * img.h
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if bits16 {
            var px = [UInt16](repeating: 0, count: n * 3)
            for i in 0..<(n * 3) { px[i] = UInt16(img.rgb[i] * 65535).littleEndian }
            guard let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 2) as CFData) else { return nil }
            return CGImage(width: img.w, height: img.h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: img.w * 6,
                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        var px = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            px[4 * i] = UInt8(img.rgb[3 * i] * 255); px[4 * i + 1] = UInt8(img.rgb[3 * i + 1] * 255); px[4 * i + 2] = UInt8(img.rgb[3 * i + 2] * 255)
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: img.w, height: img.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Añade un pie con el objeto, la exposición y la fecha en la esquina inferior izquierda.
    static func addCaption(_ text: String, to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let size = max(12, CGFloat(min(w, h)) * 0.028)
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 0.85)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: size, y: size)
        ctx.setShadow(offset: .zero, blur: size / 3, color: CGColor(gray: 0, alpha: 0.8))
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", png = "PNG", tiff16 = "TIFF 16 bits"
        var id: String { rawValue }
        var ext: String { switch self { case .jpeg: return "jpg"; case .png: return "png"; case .tiff16: return "tif" } }
        var type: UTType { switch self { case .jpeg: return .jpeg; case .png: return .png; case .tiff16: return .tiff } }
    }

    static func export(_ image: CGImage, format: ExportFormat, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
