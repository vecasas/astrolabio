import SwiftUI
import AppKit

/// Radar de lluvia de las últimas dos horas sobre un mapa oscuro, centrado en el lugar de observación.
@MainActor
struct RadarCard: View {
    let latitude: Double
    let longitude: Double

    @State private var host = ""
    @State private var frames: [RainRadar.Frame] = []
    @State private var index = 0
    @State private var playing = false
    @State private var zoom = 6
    @State private var failed = false
    @State private var base: [Int: NSImage] = [:]
    @State private var radar: [String: NSImage] = [:]

    private let grid = 3

    var body: some View {
        Card(title: tr("Radar de lluvia"), systemImage: "cloud.rain") {
            if failed {
                Text(tr("No se pudo cargar el radar (¿sin internet?).")).font(.caption).foregroundStyle(.secondary)
            } else {
                map
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                        .disabled(frames.isEmpty)
                    if !frames.isEmpty {
                        Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                               in: 0...Double(max(1, frames.count - 1)))
                        Text(frames[min(index, frames.count - 1)].time.shortTime).monospacedDigit().frame(width: 52)
                    }
                    Picker("", selection: $zoom) {
                        Text(tr("Cerca")).tag(7); Text(tr("Región")).tag(6); Text(tr("Amplio")).tag(5)
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                }
                Text(tr("Radar: RainViewer. Mapa: © colaboradores de OpenStreetMap. El punto azul es tu lugar de observación."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task(id: zoom) { await load() }
        .task(id: playing) {
            while playing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                if !frames.isEmpty { index = (index + 1) % frames.count }
            }
        }
    }

    private var center: (x: Int, y: Int, fx: Double, fy: Double) {
        RainRadar.tile(lat: latitude, lon: longitude, zoom: zoom)
    }

    private var map: some View {
        GeometryReader { geo in
            let tileSize = geo.size.width / CGFloat(grid)
            let c = center
            let frame = frames.isEmpty ? nil : frames[min(index, frames.count - 1)]
            ZStack(alignment: .topLeading) {
                Color(red: 0.05, green: 0.07, blue: 0.12)
                ForEach(0..<(grid * grid), id: \.self) { k in
                    let dx = k % grid - grid / 2, dy = k / grid - grid / 2
                    let origin = CGPoint(x: CGFloat(k % grid) * tileSize, y: CGFloat(k / grid) * tileSize)
                    Group {
                        if let img = base[k] { Image(nsImage: img).resizable().saturation(0.25).opacity(0.5) }
                        if let frame, let img = radar["\(frame.path)|\(k)"] { Image(nsImage: img).resizable().opacity(0.75) }
                    }
                    .frame(width: tileSize, height: tileSize)
                    .offset(x: origin.x, y: origin.y)
                    .id("\(dx),\(dy)")
                }
                // Lugar de observación.
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: (CGFloat(grid / 2) + c.fx) * tileSize - 5, y: (CGFloat(grid / 2) + c.fy) * tileSize - 5)
            }
        }
    }

    private func load() async {
        failed = false
        base = [:]
        radar = [:]
        guard let r = try? await RainRadar.frames(), !r.frames.isEmpty else { failed = true; return }
        host = r.host
        frames = r.frames
        index = frames.count - 1
        let c = center
        let n = 1 << zoom
        for k in 0..<(grid * grid) {
            let x = ((c.x + k % grid - grid / 2) % n + n) % n, y = c.y + k / grid - grid / 2
            guard y >= 0 && y < n else { continue }
            if let u = RainRadar.baseURL(z: zoom, x: x, y: y), let img = await Self.image(u) { base[k] = img }
        }
        // Primero el fotograma más reciente; después el resto, para la animación.
        for frame in frames.reversed() {
            for k in 0..<(grid * grid) {
                let x = ((c.x + k % grid - grid / 2) % n + n) % n, y = c.y + k / grid - grid / 2
                guard y >= 0 && y < n, let u = RainRadar.radarURL(host: host, frame: frame, z: zoom, x: x, y: y) else { continue }
                if Task.isCancelled { return }
                if let img = await Self.image(u) { radar["\(frame.path)|\(k)"] = img }
            }
        }
    }

    private static let cache = NSCache<NSURL, NSImage>()

    private static func image(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // La política de teselas de OpenStreetMap pide identificar la app.
        req.setValue("Astrolabio/\(AppInfo.version) (+\(AppInfo.repository))", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// Avisos oficiales, guardia de tormenta y riesgo de rocío.
@MainActor
struct NightAlertsCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nightGuard: NightGuard

    var body: some View {
        Card(title: tr("Avisos para esta noche"), systemImage: "exclamationmark.triangle") {
            if let reason = nightGuard.stormReason {
                Label(reason, systemImage: "cloud.bolt.rain").foregroundStyle(Theme.bad)
            } else {
                Label(tr("Sin tormentas, lluvia ni rachas fuertes previstas en la próxima hora y media."), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.good)
            }
            switch nightGuard.dewRisk {
            case .high: Label(tr("Riesgo alto de rocío: enciende el calentador."), systemImage: "drop.fill").foregroundStyle(Theme.warn)
            case .possible: Label(tr("Puede haber rocío más tarde."), systemImage: "drop").foregroundStyle(.secondary)
            case .low: EmptyView()
            }
            if settings.alertZone.isEmpty {
                Text(tr("Elige tu zona de avisos oficiales en Ajustes › Avisos meteorológicos."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if nightGuard.warnings.isEmpty {
                Text(tr("Sin avisos oficiales para %@.", settings.alertZone)).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(nightGuard.warnings) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.headline).font(.callout.weight(.semibold))
                            .foregroundStyle(w.level >= 3 ? Theme.bad : w.level == 2 ? Theme.warn : .secondary)
                        Text("\(w.onset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Loc.shared.locale))) – \(w.expires.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Loc.shared.locale)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(tr("Avisos oficiales: MeteoAlarm (AEMET en España)."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
