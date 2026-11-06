import SwiftUI
import ImageIO

/// Foto real de una zona del cielo (DSS2 rojo, a través de SkyView de la NASA), encuadrada como
/// el campo del Seestar. Si el objeto es más grande que el campo, se aleja la vista y se dibuja
/// el rectángulo de lo que abarca el Seestar.
struct SkyImage: View {
    let raHours: Double         // J2000
    let decDeg: Double
    var sizeArcmin: Double = 0
    var fov: (w: Double, h: Double) = (0.73, 1.29)
    var pixelWidth = 360
    var showCaption = true

    private var scale: Double { max(1, sizeArcmin / 60 * 1.25 / fov.h) }

    static func url(raHours: Double, decDeg: Double, width: Double, height: Double, pixelWidth: Int) -> URL? {
        let px = pixelWidth, py = Int(Double(pixelWidth) * height / width)
        var c = URLComponents(string: "https://skyview.gsfc.nasa.gov/current/cgi/runquery.pl")
        c?.queryItems = [
            .init(name: "Position", value: String(format: "%.5f,%.5f", raHours * 15, decDeg)),
            .init(name: "Survey", value: "DSS2 Red"),
            .init(name: "Pixels", value: "\(px),\(py)"),
            .init(name: "Size", value: String(format: "%.4f,%.4f", width, height)),
            .init(name: "Scaling", value: "Sqrt"),
            .init(name: "Return", value: "JPEG"),
        ]
        return c?.url
    }

    var body: some View {
        let w = fov.w * scale, h = fov.h * scale
        ZStack {
            Color.black
            if let u = Self.url(raHours: raHours, decDeg: decDeg, width: w, height: h, pixelWidth: pixelWidth) {
                StretchedSkyImage(url: u)
            }
            if scale > 1.05 {
                GeometryReader { g in
                    let rw = g.size.width / scale, rh = g.size.height / scale
                    Rectangle().stroke(Theme.warn.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                        .frame(width: rw, height: rh)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }
            if showCaption { VStack {
                Spacer()
                HStack {
                    Text(scale > 1.05 ? tr("Recuadro: campo del Seestar") : tr("Campo del Seestar"))
                    Spacer()
                    Text(tr("DSS2 · NASA SkyView"))
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(6)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            } }
        }
        .aspectRatio(fov.w / fov.h, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }
}

/// Descarga la imagen del cartografiado y la ajusta: negro en el fondo del cielo, blanco en las
/// estrellas brillantes y una curva suave. Funciona igual en campos de estrellas densos (Vía
/// Láctea) que en nebulosas o galaxias aisladas.
struct StretchedSkyImage: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failed = false
    private static let cache = NSCache<NSURL, RemoteImage.CGImageBox>()

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
                    Text(tr("Imagen no disponible (sin internet)")).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) { ProgressView(); Text(tr("Buscando la imagen…")).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: url as NSURL) { image = hit.image; return }
        image = nil
        failed = false
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 45
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { failed = true; return }
            let out = await Task.detached { StretchedSkyImage.process(data) }.value
            if let out {
                Self.cache.setObject(RemoteImage.CGImageBox(out), forKey: url as NSURL)
                image = out
            } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    nonisolated static func process(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        // SkyView responde con una imagen pequeña de aviso si no hay datos en la zona.
        guard w >= 100, h >= 100 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Int](repeating: 0, count: 256)
        for v in px { hist[Int(v)] += 1 }
        func percentile(_ p: Double) -> Int {
            let target = Int(Double(px.count) * p)
            var acc = 0
            for i in 0..<256 { acc += hist[i]; if acc >= target { return i } }
            return 255
        }
        let black = Double(percentile(0.40))
        let white = max(black + 8, Double(percentile(0.997)))
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = max(0, min(1, (Double(i) - black) / (white - black)))
            lut[i] = UInt8(pow(x, 0.75) * 255)
        }
        for i in px.indices { px[i] = lut[Int(px[i])] }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
