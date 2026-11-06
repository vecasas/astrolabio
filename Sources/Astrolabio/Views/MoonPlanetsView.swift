import SwiftUI
import Charts

// MARK: - Luna

@MainActor
struct MoonView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tonight: TonightModel
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let lat = settings.latitude, lon = settings.longitude
        let m = Astro.moon(now)
        let ph = Astro.moonPhase(now)
        let aa = Astro.altAz(raHours: m.ra, decDeg: m.dec, date: now, lat: lat, lon: lon)
        let dist = Ephemeris.moonDistanceKm(now)
        let rs = Ephemeris.riseSet(from: now.addingTimeInterval(-3600), hours: 26, step: 300, h0: 0.125,
                                   altitude: Ephemeris.moonAltitude(lat: lat, lon: lon))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 14) {
                        RealisticMoon(date: now)
                            .frame(width: 250, height: 250)
                            .shadow(color: Theme.accentSoft.opacity(0.25), radius: 30)
                        Text(ph.name).font(.system(.title, design: .rounded).weight(.bold))
                        Text(tr("Iluminada al %.0f %% · %.1f días", m.illumination * 100, ph.age))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 300)
                    .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            StatTile(title: tr("Altura ahora"), value: String(format: "%.0f°", aa.alt), systemImage: "arrow.up.right",
                                     detail: tr("Acimut %.0f° · %@", aa.az, aa.alt > 0 ? tr("sobre el horizonte") : tr("bajo el horizonte")))
                            StatTile(title: tr("Distancia"), value: tr("%.0f km", dist), systemImage: "ruler",
                                     detail: tr("Diámetro aparente %.1f′", 2 * atan(1737.4 / dist) * Astro.rad * 60))
                        }
                        HStack(spacing: 14) {
                            StatTile(title: tr("Sale"), value: rs.rise?.shortTime ?? "—", systemImage: "arrow.up.circle")
                            StatTile(title: tr("Culmina"), value: rs.transit?.shortTime ?? "—", systemImage: "arrow.up.to.line",
                                     detail: String(format: "a %.0f°", rs.maxAltitude))
                            StatTile(title: tr("Se pone"), value: rs.set?.shortTime ?? "—", systemImage: "arrow.down.circle")
                        }
                        Card(title: tr("Y para el cielo profundo…"), systemImage: "sparkles") {
                            Text(deepSkyAdvice(m.illumination, up: aa.alt > 0)).font(.callout)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    Card(title: tr("Próximas fases"), systemImage: "calendar") {
                        ForEach(Ephemeris.nextPhases(after: now), id: \.date) { p in
                            HStack {
                                Image(systemName: p.kind.symbol).foregroundStyle(Theme.accentSoft).frame(width: 22)
                                Text(p.kind.name)
                                Spacer()
                                Text(p.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Loc.shared.locale)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 380)
                    Card(title: tr("Altura esta noche"), systemImage: "chart.xyaxis.line") {
                        BodyAltitudeChart(series: [("Luna", Ephemeris.moonAltitude(lat: lat, lon: lon))], night: tonight.night)
                            .frame(height: 170)
                    }
                }

                Card(title: tr("Los próximos 30 días"), systemImage: "moon.stars") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 10) {
                        ForEach(0..<30, id: \.self) { d in
                            let day = Calendar.current.date(byAdding: .day, value: d, to: Calendar.current.startOfDay(for: now))!
                                .addingTimeInterval(22 * 3600)
                            let mm = Astro.moon(day)
                            VStack(spacing: 3) {
                                RealisticMoon(date: day, pixelSize: 72)
                                    .frame(width: 34, height: 34)
                                Text(day.formatted(.dateTime.day().month(.abbreviated).locale(Loc.shared.locale))).font(.system(size: 9))
                                    .foregroundStyle(mm.illumination < 0.25 ? Theme.good : .secondary)
                            }
                        }
                    }
                    Text(tr("En verde, las noches con poca Luna: las mejores para galaxias y nebulosas débiles."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Card(title: tr("Fotografiar la Luna con el Seestar"), systemImage: "camera") {
                    HStack {
                        Button(tr("Modo Luna del Seestar")) {
                            ActionRunner.run(client, tr("Modo Luna")) { try await client.startMoonView() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(tr("GoTo a la Luna")) {
                            let pos = Astro.moon(Date())
                            ActionRunner.run(client, tr("GoTo Luna")) {
                                _ = try await client.gotoAndWait(name: "Luna", raHours: pos.ra, decDeg: pos.dec)
                            }
                        }
                        Button(tr("Parar")) { ActionRunner.run(client, tr("Parar")) { try await client.stopView() } }
                        Button(tr("Volver al modo cielo profundo")) {
                            ActionRunner.run(client, tr("Modo cielo profundo")) { try await client.startStarView() }
                        }
                    }
                    .disabled(!client.isConnected)
                    Text(aa.alt > 0
                         ? tr("El modo Luna sigue la Luna y muestra la imagen en «Vista en directo». Para un mosaico o un vídeo, graba con la app y apílalo en «Apilador planetario».")
                         : tr("Ahora la Luna está bajo el horizonte."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(tr("Luna"))
        .onReceive(timer) { now = $0 }
    }

    private func deepSkyAdvice(_ illum: Double, up: Bool) -> String {
        switch illum {
        case ..<0.25: return tr("Luna poco iluminada: noche ideal para galaxias y nebulosas débiles.")
        case ..<0.6: return up ? tr("Luna a medias: elige objetos lejos de ella o nebulosas de emisión con el filtro LP.") : tr("La Luna aún no ha salido: aprovecha ahora para los objetos más débiles.")
        default: return up ? tr("Luna brillante: mejor cúmulos, estrellas dobles, planetas… o la propia Luna. Las nebulosas de emisión aguantan con el filtro LP.") : tr("Luna brillante pero bajo el horizonte: aprovecha mientras no sale.")
        }
    }
}

// MARK: - Planetas

@MainActor
struct PlanetsView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tonight: TonightModel
    @State private var now = Date()
    @State private var message = ""
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let lat = settings.latitude, lon = settings.longitude
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(title: tr("Altura de los planetas esta noche"), systemImage: "chart.xyaxis.line") {
                    BodyAltitudeChart(series: Astro.planetNames.map { ($0, Ephemeris.planetAltitude($0, lat: lat, lon: lon)) },
                                      night: tonight.night)
                        .frame(height: 200)
                }
                if !message.isEmpty { Text(message).foregroundStyle(Theme.accentSoft) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(Astro.planetNames, id: \.self) { name in
                        planetCard(name, lat: lat, lon: lon)
                    }
                }
                Card(title: tr("Sol"), systemImage: "sun.max.trianglebadge.exclamationmark") {
                    Text(tr("Para observar el Sol usa la app oficial con el filtro solar puesto. Astrolabio nunca apunta al Sol."))
                        .font(.callout)
                }
            }
            .padding(20)
        }
        .navigationTitle(tr("Planetas"))
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private func planetCard(_ name: String, lat: Double, lon: Double) -> some View {
        if let p = Astro.planet(name, date: now) {
            let aa = Astro.altAz(raHours: p.ra, decDeg: p.dec, date: now, lat: lat, lon: lon)
            let geo = Ephemeris.phaseGeometry(name, date: now)
            let mag = Ephemeris.magnitude(name, date: now)
            let diam = Ephemeris.apparentDiameterArcsec(name, distanceAU: p.distance)
            let rs = Ephemeris.riseSet(from: now.addingTimeInterval(-3600), hours: 26, step: 600, h0: 0,
                                       altitude: Ephemeris.planetAltitude(name, lat: lat, lon: lon))
            let nearSun = (geo?.elongation ?? 90) < 15
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: Ephemeris.planetInfo[name]?.symbol ?? "circle.fill")
                        .font(.title2).foregroundStyle(color(name))
                    Text(planetLabel(name)).font(.title3.bold())
                    Spacer()
                    status(alt: aa.alt, rs: rs, nearSun: nearSun)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        label("Altura"); value(tr("%.0f° (acimut %.0f°)", aa.alt, aa.az))
                    }
                    GridRow { label("Magnitud"); value(mag.map { String(format: "%.1f", $0) } ?? "—") }
                    GridRow { label(tr("Tamaño")); value(diam.map { String(format: "%.1f″", $0) } ?? "—") }
                    GridRow { label("Distancia"); value(tr("%.2f UA · %.0f millones de km", p.distance, p.distance * 149.6)) }
                    GridRow { label(tr("Separación del Sol")); value(geo.map { String(format: "%.0f°", $0.elongation) } ?? "—") }
                    GridRow {
                        label(tr("Sale / culmina / se pone"))
                        value("\(rs.rise?.shortTime ?? "—") · \(rs.transit?.shortTime ?? "—") · \(rs.set?.shortTime ?? "—")")
                    }
                }
                .font(.callout)
                if let note = Ephemeris.planetInfo[name]?.note {
                    Text(tr(note)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        message = tr("Apuntando a %@…", "\(name)")
                        Task {
                            do {
                                let pos = Astro.planet(name, date: Date())!
                                let ok = try await client.gotoAndWait(name: name, raHours: pos.ra, decDeg: pos.dec)
                                message = ok ? tr("%@ centrado. Pulsa «Modo planeta» para seguirlo.", "\(name)") : tr("El GoTo a %@ no terminó bien.", "\(name)")
                            } catch { message = error.localizedDescription }
                        }
                    } label: { Label(tr("GoTo"), systemImage: "scope") }
                        .buttonStyle(.borderedProminent)
                    Button {
                        ActionRunner.run(client, tr("Modo planeta")) { try await client.startPlanetScan() }
                    } label: { Label(tr("Modo planeta"), systemImage: "circle.dotted") }
                }
                .disabled(!client.isConnected || aa.alt < 10 || nearSun)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardStroke))
        }
    }

    private func label(_ t: String) -> some View { Text(t).foregroundStyle(.secondary) }
    private func value(_ t: String) -> some View { Text(t).monospacedDigit() }

    @ViewBuilder
    private func status(alt: Double, rs: Ephemeris.RiseSet, nearSun: Bool) -> some View {
        if nearSun {
            Pill(text: tr("Junto al Sol"), systemImage: "sun.max", color: Theme.warn)
        } else if alt > 10 {
            Pill(text: tr("Visible ahora"), systemImage: "eye", color: Theme.good)
        } else if let r = rs.rise, r > Date() {
            Pill(text: tr("Sale a las %@", "\(r.shortTime)"), systemImage: "arrow.up", color: Theme.accentSoft)
        } else {
            Pill(text: tr("Bajo"), systemImage: "arrow.down", color: .secondary)
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "Mercurio": return .gray
        case "Venus": return Color(red: 1, green: 0.93, blue: 0.75)
        case "Marte": return Color(red: 1, green: 0.5, blue: 0.35)
        case "Júpiter": return Color(red: 0.95, green: 0.8, blue: 0.6)
        case "Saturno": return Color(red: 0.95, green: 0.88, blue: 0.6)
        case "Urano": return Color(red: 0.6, green: 0.9, blue: 0.9)
        default: return Color(red: 0.45, green: 0.6, blue: 1)
        }
    }
}

// MARK: - Piezas comunes

/// Altura de uno o varios astros durante la noche (de la puesta a la salida del Sol).
@MainActor
struct BodyAltitudeChart: View {
    let series: [(String, (Date) -> Double)]
    let night: Astro.Night?

    struct P: Identifiable { let id: String; let name: String; let t: Date; let alt: Double }

    var body: some View {
        let start = night?.sunset ?? Date()
        let end = night?.sunrise ?? start.addingTimeInterval(12 * 3600)
        let pts: [P] = series.flatMap { name, f in
            stride(from: 0.0, through: end.timeIntervalSince(start), by: 900).map { dt in
                let t = start.addingTimeInterval(dt)
                return P(id: "\(name)\(dt)", name: name, t: t, alt: max(-2, f(t)))
            }
        }
        Chart {
            if let d = night?.duskStart, let a = night?.dawnEnd {
                RectangleMark(xStart: .value("Inicio", d), xEnd: .value("Fin", a))
                    .foregroundStyle(Theme.accent.opacity(0.07))
            }
            ForEach(pts) { p in
                LineMark(x: .value("Hora", p.t), y: .value("Altura", p.alt))
                    .foregroundStyle(by: .value("Astro", tr(p.name)))
            }
            if Date() > start && Date() < end {
                RuleMark(x: .value("Ahora", Date())).foregroundStyle(.white.opacity(0.5))
            }
        }
        .chartYScale(domain: 0...90)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
    }
}

@MainActor
struct MoonDisk: View {
    let illumination: Double
    let waxing: Bool

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disk = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(disk, with: .color(Color(red: 0.10, green: 0.14, blue: 0.24)))
            // Terminador: elipse cuya anchura depende de la fase.
            var lit = Path()
            let k = 1 - 2 * illumination      // 1 = nueva, -1 = llena
            let steps = 60
            for i in 0...steps {
                let a = -Double.pi / 2 + Double.pi * Double(i) / Double(steps)
                let pt = CGPoint(x: c.x + r * cos(a) * (waxing ? 1 : -1), y: c.y + r * sin(a))
                if i == 0 { lit.move(to: pt) } else { lit.addLine(to: pt) }
            }
            for i in 0...steps {
                let a = Double.pi / 2 - Double.pi * Double(i) / Double(steps)
                lit.addLine(to: CGPoint(x: c.x + r * cos(a) * k * (waxing ? 1 : -1), y: c.y + r * sin(a)))
            }
            lit.closeSubpath()
            ctx.fill(lit, with: .radialGradient(Gradient(colors: [Color(white: 0.97), Color(red: 0.80, green: 0.84, blue: 0.92)]),
                                                center: CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.25), startRadius: 0, endRadius: r * 1.4))
            // Algunos «mares» suaves para que no parezca un disco plano.
            if r > 40 {
                let maria: [(Double, Double, Double)] = [(-0.25, -0.30, 0.22), (0.10, -0.15, 0.18), (0.28, 0.20, 0.16), (-0.05, 0.30, 0.13), (-0.38, 0.05, 0.12)]
                var ctx2 = ctx
                ctx2.clip(to: lit)
                for (dx, dy, rr) in maria {
                    let rect = CGRect(x: c.x + dx * r - rr * r, y: c.y + dy * r - rr * r, width: 2 * rr * r, height: 2 * rr * r)
                    ctx2.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.55, green: 0.60, blue: 0.70).opacity(0.35)))
                }
            }
            ctx.stroke(disk, with: .color(Theme.accent.opacity(0.25)), lineWidth: 1)
        }
    }
}
