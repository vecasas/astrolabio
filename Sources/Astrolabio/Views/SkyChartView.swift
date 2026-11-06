import SwiftUI

/// Algo que se puede señalar en la carta.
enum SkyItem: Equatable {
    case dso(DeepSkyObject)
    case planet(String)
    case moon
    case star(name: String, ra: Double, dec: Double, mag: Double)

    var title: String {
        switch self {
        case .dso(let o): return o.displayName
        case .planet(let n): return planetLabel(n)
        case .moon: return tr("Luna")
        case .star(let n, _, _, _): return n.isEmpty ? tr("Estrella") : n
        }
    }

    /// AR y Dec en grados (J2000 para catálogo y estrellas, de la fecha para Luna y planetas).
    func position(_ date: Date) -> (ra: Double, dec: Double)? {
        switch self {
        case .dso(let o): return (o.raHours * 15, o.decDeg)
        case .planet(let n): return Astro.planet(n, date: date).map { ($0.ra * 15, $0.dec) }
        case .moon: let m = Astro.moon(date); return (m.ra * 15, m.dec)
        case .star(_, let ra, let dec, _): return (ra, dec)
        }
    }
}

/// Carta del cielo visible desde el lugar de observación, con constelaciones, objetos del
/// catálogo, Luna, planetas y la posición del telescopio. Un clic selecciona; el GoTo se lanza
/// solo con el botón del panel.
@MainActor
struct SkyChartView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient

    @State private var hourOffset = 0.0
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var selected: SkyItem?
    @State private var showLines = true
    @State private var showNames = true
    @State private var showDSO = true
    @State private var showGrid = true
    @State private var dsoMagLimit = 10.0
    @State private var message = ""
    @State private var tick = Date()
    @State private var canvasSize = CGSize(width: 800, height: 600)
    @State private var confirmObject: DeepSkyObject?
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var date: Date { tick.addingTimeInterval(hourOffset * 3600) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar.padding(10)
                GeometryReader { geo in
                    chart(size: geo.size)
                        .onAppear { canvasSize = geo.size }
                        .onChange(of: geo.size) { _, s in canvasSize = s }
                }
            }
            .frame(minWidth: 420, idealWidth: 700, maxWidth: .infinity)
            side.frame(minWidth: 240, idealWidth: 270, maxWidth: 320)
        }
        .navigationTitle(tr("Carta estelar"))
        .sheet(item: Binding(get: { confirmObject.map { IdentifiedObject(object: $0) } }, set: { confirmObject = $0?.object })) { w in
            GotoConfirmSheet(object: w.object) { message = $0 }.nightMode()
        }
        .onReceive(timer) { tick = $0 }
    }

    // MARK: Controles

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Loc.shared.locale)))
                    .font(.headline).monospacedDigit()
                Text(hourOffset == 0 ? tr("Ahora") : String(format: "%+.1f h", hourOffset)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            Slider(value: $hourOffset, in: -6...14, step: 0.25).frame(minWidth: 80)
            Button(tr("Ahora")) { hourOffset = 0 }
            Divider().frame(height: 20)
            Button { zoom = max(1, zoom / 1.4); if zoom == 1 { pan = .zero } } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = min(12, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help(tr("Ver todo el cielo"))
            Button { centerOnTelescope() } label: { Image(systemName: "scope") }
                .help(tr("Centrar en el telescopio"))
                .disabled(client.ra == nil)
        }
    }

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: tr("Capas"), systemImage: "square.3.layers.3d") {
                    Toggle(tr("Líneas de constelaciones"), isOn: $showLines)
                    Toggle(tr("Nombres"), isOn: $showNames)
                    Toggle(tr("Cuadrícula de altura"), isOn: $showGrid)
                    Toggle(tr("Objetos de cielo profundo"), isOn: $showDSO)
                    if showDSO {
                        HStack {
                            Text(tr("Hasta mag."))
                            Slider(value: $dsoMagLimit, in: 5...12, step: 0.5)
                            Text(String(format: "%.1f", dsoMagLimit)).monospacedDigit().frame(width: 34)
                        }
                        .font(.callout)
                    }
                }
                if let item = selected { selectionCard(item) }
                else {
                    Card(title: tr("Cómo se usa"), systemImage: "hand.tap") {
                        Text(tr("Haz clic en una estrella, un objeto o un planeta para ver sus datos. Arrastra para moverte, pellizca o usa la lupa para acercarte y mueve la barra para ver el cielo a otra hora."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.accentSoft) }
                legend
            }
            .padding(12)
        }
    }

    private var legend: some View {
        Card(title: tr("Leyenda"), systemImage: "info.circle") {
            ForEach([ObjectKind.galaxy, .nebula, .planetary, .globular, .open, .snr], id: \.self) { k in
                HStack {
                    Circle().stroke(dsoColor(k), lineWidth: 1.5).frame(width: 10, height: 10)
                    Text(k.label).font(.caption)
                }
            }
            HStack {
                Image(systemName: "plus.viewfinder").foregroundStyle(Theme.warn)
                Text(tr("Telescopio y su campo")).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func selectionCard(_ item: SkyItem) -> some View {
        let pos = item.position(date)
        let h = pos.map { p -> (alt: Double, az: Double) in
            SkyProjection(date: date, lat: settings.latitude, lon: settings.longitude, center: .zero, radius: 1)
                .altAz(raDeg: p.ra, decDeg: p.dec)
        }
        Card(title: item.title, systemImage: icon(item)) {
            if case .dso(let o) = item {
                Text(tr("%@ · mag %@ · %@′", "\(o.kind.label)", "\(String(format: "%.1f", o.magnitude))", "\(String(format: "%.0f", o.sizeArcmin))"))
                    .font(.callout).foregroundStyle(.secondary)
                AdviceSummary(object: o)
            }
            if case .star(_, _, _, let mag) = item {
                Text(tr("Estrella de magnitud %.1f", mag)).font(.callout).foregroundStyle(.secondary)
            }
            if let p = pos {
                InfoRow(label: tr("AR / Dec"), value: "\(Astro.formatRA(p.ra / 15))  \(Astro.formatDec(p.dec))")
            }
            if let h {
                InfoRow(label: tr("Altura / acimut"), value: String(format: "%.0f° / %.0f°", h.alt, h.az))
            }
            if let p = pos, case .dso = item {
                let rs = Ephemeris.riseSet(from: date.addingTimeInterval(-3600), hours: 24, step: 600, h0: settings.minAltitude,
                                           altitude: Ephemeris.altitudeOfFixed(raJ2000: p.ra / 15, decJ2000: p.dec,
                                                                               lat: settings.latitude, lon: settings.longitude))
                InfoRow(label: tr("Por encima de %@°", "\(Int(settings.minAltitude))"),
                        value: rs.alwaysUp ? tr("Toda la noche") : (rs.neverUp ? tr("No llega") : "\(rs.rise?.shortTime ?? "—") – \(rs.set?.shortTime ?? "—")"))
            }
            gotoButtons(item, alt: h?.alt ?? -90)
        }
    }

    @ViewBuilder
    private func gotoButtons(_ item: SkyItem, alt: Double) -> some View {
        let canGo = client.isConnected && alt > 10 && hourOffset == 0
        HStack {
            switch item {
            case .dso(let o):
                Button {
                    confirmObject = o
                } label: { Label(tr("Ir y apilar…"), systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGo)
            case .moon, .planet, .star:
                Button {
                    guard let p = item.position(Date()) else { return }
                    let name = item.title
                    message = tr("Apuntando a %@…", "\(name)")
                    Task {
                        do {
                            // Las estrellas vienen en J2000; Luna y planetas ya están en coordenadas de la fecha.
                            var ra = p.ra / 15, dec = p.dec
                            if case .star = item { let n = Astro.precessFromJ2000(raHours: ra, decDeg: dec, to: Date()); ra = n.ra; dec = n.dec }
                            let ok = try await client.gotoAndWait(name: name, raHours: ra, decDeg: dec)
                            message = ok ? tr("Llegó a %@.", "\(name)") : tr("El GoTo a %@ no terminó bien.", "\(name)")
                        } catch { message = error.localizedDescription }
                    }
                } label: { Label(tr("GoTo"), systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGo)
            }
        }
        if !client.isConnected { Text(tr("Conecta el telescopio para apuntar.")).font(.caption).foregroundStyle(.secondary) }
        else if hourOffset != 0 { Text(tr("Vuelve a «Ahora» para apuntar.")).font(.caption).foregroundStyle(.secondary) }
        else if alt <= 10 { Text(tr("Está demasiado bajo para apuntar.")).font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: Dibujo

    private func projection(size: CGSize) -> SkyProjection {
        let base = min(size.width, size.height) / 2 - 24
        let off = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        return SkyProjection(date: date, lat: settings.latitude, lon: settings.longitude,
                             center: CGPoint(x: size.width / 2 + off.width, y: size.height / 2 + off.height),
                             radius: base * zoom * pinch)
    }

    private func chart(size: CGSize) -> some View {
        let proj = projection(size: size)
        let telescope: (ra: Double, dec: Double)? = (client.ra != nil && client.dec != nil && hourOffset == 0) ? (client.ra! * 15, client.dec!) : nil
        return Canvas { ctx, _ in
            draw(ctx: &ctx, proj: proj, telescope: telescope)
        }
        .background(Theme.deep)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height; drag = .zero }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { v in zoom = max(1, min(12, zoom * v.magnification)); pinch = 1 }
        )
        .onTapGesture(coordinateSpace: .local) { pt in selected = hit(pt, proj: proj) }
        .clipped()
    }

    private func draw(ctx: inout GraphicsContext, proj: SkyProjection, telescope: (ra: Double, dec: Double)?) {
        let c = proj.center, R = proj.radius
        let horizon = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        // Color del cielo según la altura del Sol.
        let sunAlt = Astro.sunAltitude(date, lat: settings.latitude, lon: settings.longitude)
        let skyTop: Color = sunAlt > -6 ? Color(red: 0.12, green: 0.22, blue: 0.42) : (sunAlt > -12 ? Color(red: 0.06, green: 0.12, blue: 0.27) : Color(red: 0.02, green: 0.05, blue: 0.13))
        ctx.fill(horizon, with: .radialGradient(Gradient(colors: [skyTop, Color(red: 0.05, green: 0.11, blue: 0.24)]),
                                                center: c, startRadius: 0, endRadius: R))
        var sky = ctx
        sky.clip(to: horizon)

        if showGrid {
            for alt in stride(from: 30.0, through: 60.0, by: 30.0) {
                var p = Path()
                for az in stride(from: 0.0, through: 360.0, by: 5) {
                    let pt = proj.point(alt: alt, az: az)
                    if az == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                sky.stroke(p, with: .color(Theme.accent.opacity(0.13)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
            }
            // Altura mínima configurada.
            var p = Path()
            for az in stride(from: 0.0, through: 360.0, by: 5) {
                let pt = proj.point(alt: settings.minAltitude, az: az)
                if az == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            sky.stroke(p, with: .color(Theme.warn.opacity(0.25)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 4]))
        }

        if showLines {
            for poly in SkyCatalog.lines {
                var path = Path()
                var pen = false
                for v in poly {
                    if let pt = proj.point(raDeg: v.ra, decDeg: v.dec, minAlt: -10) {
                        if pen { path.addLine(to: pt) } else { path.move(to: pt); pen = true }
                    } else { pen = false }
                }
                sky.stroke(path, with: .color(Theme.accent.opacity(0.35)), lineWidth: 0.8)
            }
        }

        // Estrellas.
        let magLimit = zoom > 2.5 ? 5.5 : (zoom > 1.5 ? 5.0 : 4.6)
        for s in SkyCatalog.stars where s.mag <= magLimit {
            guard let pt = proj.point(raDeg: s.ra, decDeg: s.dec) else { continue }
            let r = max(0.6, 3.6 - s.mag * 0.62) * (zoom > 2 ? 1.2 : 1)
            sky.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)), with: .color(starColor(s.bv)))
            if showNames && !s.name.isEmpty && s.mag < (zoom > 1.5 ? 2.6 : 1.6) {
                sky.draw(Text(s.name).font(.system(size: 9)).foregroundColor(.white.opacity(0.55)),
                         at: CGPoint(x: pt.x + r + 3, y: pt.y), anchor: .leading)
            }
        }

        if showNames && showLines {
            for l in SkyCatalog.labels where l.rank <= (zoom > 1.6 ? 3 : 1) {
                guard let pt = proj.point(raDeg: l.ra, decDeg: l.dec, minAlt: 5) else { continue }
                sky.draw(Text(l.name.uppercased()).font(.system(size: 9, weight: .medium)).kerning(1.2)
                    .foregroundColor(Theme.accentSoft.opacity(0.45)), at: pt)
            }
        }

        if showDSO {
            for o in Catalog.objects where o.magnitude <= dsoMagLimit {
                guard let pt = proj.point(raDeg: o.raHours * 15, decDeg: o.decDeg) else { continue }
                let r: CGFloat = max(3.5, min(14, CGFloat(o.sizeArcmin / 60) * proj.radius / 90 * 2.2))
                let rect = CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)
                let shape: Path = o.kind == .galaxy ? Path(ellipseIn: rect.insetBy(dx: 0, dy: r * 0.35)) : Path(ellipseIn: rect)
                sky.stroke(shape, with: .color(dsoColor(o.kind)), lineWidth: 1.2)
                if showNames && (o.id.hasPrefix("M") || zoom > 2) {
                    sky.draw(Text(o.id).font(.system(size: 8.5, weight: .semibold)).foregroundColor(dsoColor(o.kind).opacity(0.9)),
                             at: CGPoint(x: pt.x, y: pt.y + r + 6))
                }
            }
        }

        // Planetas y Luna.
        for name in Astro.planetNames {
            guard let p = Astro.planet(name, date: date), let pt = proj.point(raDeg: p.ra * 15, decDeg: p.dec) else { continue }
            sky.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(Color(red: 1, green: 0.85, blue: 0.55)))
            sky.draw(Text(planetLabel(name)).font(.system(size: 10, weight: .semibold)).foregroundColor(Color(red: 1, green: 0.88, blue: 0.65)),
                     at: CGPoint(x: pt.x + 7, y: pt.y), anchor: .leading)
        }
        let m = Astro.moon(date)
        if let pt = proj.point(raDeg: m.ra * 15, decDeg: m.dec) {
            sky.fill(Path(ellipseIn: CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)), with: .color(Color(white: 0.93)))
            sky.draw(Text(tr("Luna")).font(.system(size: 10, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: pt.x + 12, y: pt.y), anchor: .leading)
        }

        // Telescopio con su campo.
        if let t = telescope, let pt = proj.point(raDeg: t.ra, decDeg: t.dec, minAlt: -5) {
            let w = settings.fovWidthDeg, h = settings.fovHeightDeg
            let cosd = max(0.05, cos(t.dec * Astro.deg))
            let corners = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].compactMap {
                proj.point(raDeg: t.ra + $0.0 / cosd, decDeg: t.dec + $0.1, minAlt: -10)
            }
            if corners.count == 4 {
                var fov = Path()
                fov.addLines(corners)
                fov.closeSubpath()
                sky.stroke(fov, with: .color(Theme.warn), lineWidth: 1.2)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: pt.x - 14, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x - 5, y: pt.y))
            cross.move(to: CGPoint(x: pt.x + 5, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x + 14, y: pt.y))
            cross.move(to: CGPoint(x: pt.x, y: pt.y - 14)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y - 5))
            cross.move(to: CGPoint(x: pt.x, y: pt.y + 5)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 14))
            sky.stroke(cross, with: .color(Theme.warn), lineWidth: 1.5)
            sky.stroke(Path(ellipseIn: CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)), with: .color(Theme.warn), lineWidth: 1)
        }

        // Selección.
        if let item = selected, let p = item.position(date), let pt = proj.point(raDeg: p.ra, decDeg: p.dec, minAlt: -5) {
            sky.stroke(Path(ellipseIn: CGRect(x: pt.x - 16, y: pt.y - 16, width: 32, height: 32)),
                       with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        // Horizonte y puntos cardinales.
        ctx.stroke(horizon, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1.5)
        for (label, az) in [(tr("N"), 0.0), (tr("NE"), 45.0), (tr("E"), 90.0), (tr("SE"), 135.0), (tr("S"), 180.0), (tr("SO"), 225.0), (tr("O"), 270.0), (tr("NO"), 315.0)] {
            let pt = proj.point(alt: -6 / Double(max(1, zoom)), az: az)
            ctx.draw(Text(label).font(.system(size: label.count == 1 ? 13 : 10, weight: .bold))
                .foregroundColor(label.count == 1 ? Theme.accentSoft : Theme.accentSoft.opacity(0.6)), at: pt)
        }
    }

    // MARK: Selección

    private func hit(_ p: CGPoint, proj: SkyProjection) -> SkyItem? {
        var best: (SkyItem, CGFloat)?
        func consider(_ item: SkyItem, _ pt: CGPoint?, bonus: CGFloat = 0) {
            guard let pt else { return }
            let d = hypot(pt.x - p.x, pt.y - p.y) - bonus
            if d < 16 && (best == nil || d < best!.1) { best = (item, d) }
        }
        let m = Astro.moon(date)
        consider(.moon, proj.point(raDeg: m.ra * 15, decDeg: m.dec), bonus: 6)
        for n in Astro.planetNames {
            if let pl = Astro.planet(n, date: date) { consider(.planet(n), proj.point(raDeg: pl.ra * 15, decDeg: pl.dec), bonus: 3) }
        }
        if showDSO {
            for o in Catalog.objects where o.magnitude <= dsoMagLimit {
                consider(.dso(o), proj.point(raDeg: o.raHours * 15, decDeg: o.decDeg), bonus: 2)
            }
        }
        for s in SkyCatalog.stars where s.mag <= 4.5 {
            consider(.star(name: s.name, ra: s.ra, dec: s.dec, mag: s.mag), proj.point(raDeg: s.ra, decDeg: s.dec), bonus: s.mag < 2 ? 1 : -2)
        }
        return best?.0
    }

    private func centerOnTelescope() {
        guard let ra = client.ra, let dec = client.dec else { return }
        zoom = max(zoom, 3)
        let base = min(canvasSize.width, canvasSize.height) / 2 - 24
        let proj = SkyProjection(date: date, lat: settings.latitude, lon: settings.longitude, center: .zero, radius: base * zoom)
        let h = proj.altAz(raDeg: ra * 15, decDeg: dec)
        let pt = proj.point(alt: h.alt, az: h.az)
        pan = CGSize(width: -pt.x, height: -pt.y)
    }

    // MARK: Colores

    private func starColor(_ bv: Double) -> Color {
        switch bv {
        case ..<0.0: return Color(red: 0.75, green: 0.85, blue: 1.0)
        case ..<0.5: return Color(red: 0.92, green: 0.95, blue: 1.0)
        case ..<1.0: return Color(red: 1.0, green: 0.96, blue: 0.85)
        case ..<1.4: return Color(red: 1.0, green: 0.86, blue: 0.68)
        default: return Color(red: 1.0, green: 0.75, blue: 0.6)
        }
    }

    private func dsoColor(_ k: ObjectKind) -> Color {
        switch k {
        case .galaxy: return Color(red: 0.95, green: 0.65, blue: 0.95)
        case .nebula, .snr: return Color(red: 0.45, green: 0.95, blue: 0.75)
        case .planetary: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .globular: return Color(red: 1.0, green: 0.85, blue: 0.45)
        case .open: return Color(red: 1.0, green: 0.95, blue: 0.6)
        case .other: return .gray
        }
    }

    private func icon(_ item: SkyItem) -> String {
        switch item {
        case .dso(let o): return o.kind.symbol
        case .planet: return "globe.europe.africa"
        case .moon: return "moon"
        case .star: return "star"
        }
    }
}

/// Envoltorio para presentar una hoja a partir de un objeto del catálogo.
struct IdentifiedObject: Identifiable {
    let object: DeepSkyObject
    var id: String { object.id }
}
