import SwiftUI
import Charts

/// «Qué mirar»: los mejores objetos de la noche, con su curva de altura y acciones rápidas.
@MainActor
struct TonightView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sky: SkyStore
    @EnvironmentObject var tonight: TonightModel
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var plan: PlanStore

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todo", galaxies = "Galaxias", nebulae = "Nebulosas", clusters = "Cúmulos", planetary = "Planetarias"
        var id: String { rawValue }
        func matches(_ k: ObjectKind) -> Bool {
            switch self {
            case .all: return true
            case .galaxies: return k == .galaxy
            case .nebulae: return k == .nebula || k == .snr
            case .clusters: return k == .open || k == .globular
            case .planetary: return k == .planetary
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var onlyNow = false
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                planetsTonight
                HStack(alignment: .top, spacing: 14) {
                    WeekOutlookCard()
                    CometsTonightCard(night: tonight.night, message: $message)
                }
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text(tr($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    Toggle(tr("Solo lo que está alto ahora"), isOn: $onlyNow).toggleStyle(.switch)
                    Spacer()
                    if tonight.isComputing { ProgressView().controlSize(.small) }
                    Button { Task { await tonight.update(settings: settings, weather: sky.hours, force: true) } } label: {
                        Label(tr("Recalcular"), systemImage: "arrow.clockwise")
                    }
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.accentSoft) }
                if list.isEmpty && !tonight.isComputing {
                    Text(tonight.forecasts.isEmpty ? tr("Calculando la noche…") : tr("Ningún objeto cumple el filtro ahora mismo."))
                        .foregroundStyle(.secondary).padding(.top, 20)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, f in
                        TargetCard(rank: index + 1, forecast: f, night: tonight.night, message: $message)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(tr("Qué mirar"))
        .task(id: sky.lastUpdate) { await tonight.update(settings: settings, weather: sky.hours) }
    }

    private var list: [TargetForecast] {
        let lat = settings.latitude, lon = settings.longitude, minAlt = settings.minAltitude
        return tonight.forecasts
            .filter { $0.score > 0 && filter.matches($0.object.kind) }
            .filter { f in
                guard onlyNow else { return true }
                return Ephemeris.altitudeOfFixed(raJ2000: f.object.raHours, decJ2000: f.object.decDeg, lat: lat, lon: lon)(Date()) >= minAlt
            }
            .prefix(24)
            .map { $0 }
    }

    @ViewBuilder
    private var summary: some View {
        let q = tonight.nightQuality(weather: sky.hours)
        HStack(alignment: .top, spacing: 14) {
            StatTile(title: tr("Calidad de la noche"), value: q.map { String(format: "%.0f", $0.score) } ?? "—",
                     systemImage: "sparkles", detail: q.map { qualityText($0.score) })
            StatTile(title: tr("Noche cerrada"),
                     value: "\(tonight.night?.duskStart?.shortTime ?? "—") – \(tonight.night?.dawnEnd?.shortTime ?? "—")",
                     systemImage: "moon.stars",
                     detail: tr("Puesta de Sol %@ · salida %@", "\(tonight.night?.sunset?.shortTime ?? "—")", "\(tonight.night?.sunrise?.shortTime ?? "—")"))
            StatTile(title: tr("Luna"), value: q.map { String(format: "%.0f %%", $0.moonFactor * 100) } ?? "—",
                     systemImage: "moonphase.waxing.gibbous", detail: Astro.moonPhase(Date()).name)
            StatTile(title: tr("Nubes en la noche"), value: q?.cloud.map { String(format: "%.0f %%", $0) } ?? "—",
                     systemImage: "cloud", detail: sky.error ?? tr("Previsión de Open-Meteo"))
        }
    }

    private func qualityText(_ s: Double) -> String {
        switch s {
        case 70...: return tr("Excelente para cielo profundo")
        case 45...: return tr("Buena noche")
        case 25...: return tr("Regular: mejor objetos brillantes")
        default: return tr("Poco aprovechable")
        }
    }

    @ViewBuilder
    private var planetsTonight: some View {
        let lat = settings.latitude, lon = settings.longitude
        // Ventana de observación: de la puesta a la salida del Sol, desde ahora si ya es de noche.
        let start = max(Date(), tonight.night?.sunset ?? Date())
        let end = tonight.night?.sunrise ?? start.addingTimeInterval(12 * 3600)
        let hours = max(0.5, end.timeIntervalSince(start) / 3600)
        let visible: [(String, String)] = Astro.planetNames.compactMap { name in
            let rs = Ephemeris.riseSet(from: start, hours: hours, step: 600, h0: 15,
                                       altitude: Ephemeris.planetAltitude(name, lat: lat, lon: lon))
            guard rs.maxAltitude > 15 else { return nil }
            let from = rs.alwaysUp || rs.rise == nil ? tr("ya visible") : tr("desde %@", "\(rs.rise!.shortTime)")
            let to = rs.set.map { tr("hasta %@", $0.shortTime) } ?? tr("hasta el amanecer")
            return (name, tr("%@ · %@, %@ · máx. %.0f°", planetLabel(name), from, to, rs.maxAltitude))
        }
        if !visible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label(tr("Planetas:"), systemImage: "globe.europe.africa").foregroundStyle(.secondary)
                    ForEach(visible, id: \.0) { _, text in Pill(text: text, color: Theme.accentSoft) }
                }
            }
            .font(.callout)
        }
    }
}

/// Tarjeta de un objeto recomendado.
@MainActor
struct TargetCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var plan: PlanStore

    let rank: Int
    let forecast: TargetForecast
    let night: Astro.Night?
    @Binding var message: String
    @State private var busy = false
    @State private var confirming = false
    @State private var showInfo = false
    @ObservedObject private var info = ObjectInfoService.shared

    var body: some View {
        let obj = forecast.object
        let altNow = Ephemeris.altitudeOfFixed(raJ2000: obj.raHours, decJ2000: obj.decDeg,
                                               lat: settings.latitude, lon: settings.longitude)(Date())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SkyImage(raHours: obj.raHours, decDeg: obj.decDeg, sizeArcmin: obj.sizeArcmin,
                         fov: (settings.fovWidthDeg, settings.fovHeightDeg), pixelWidth: 240, showCaption: false)
                    .frame(width: 104)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("\(rank)")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(obj.id).font(.headline)
                            Text(obj.localizedName.isEmpty ? obj.kind.label : obj.localizedName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Pill(text: String(format: "%.0f", forecast.score), systemImage: "star.fill", color: Theme.scoreColor(forecast.score))
                    }
                    HStack(spacing: 6) {
                        Pill(text: obj.kind.label, systemImage: obj.kind.symbol)
                        Pill(text: forecast.fit.label, color: Theme.accentSoft)
                    }
                    Text(tr("Magnitud %.1f · tamaño %.0f′", obj.magnitude, obj.sizeArcmin))
                        .font(.caption).foregroundStyle(.secondary)
                    if let sum = info.summary(for: obj) {
                        Text(sum.extract).font(.caption).lineLimit(4).foregroundStyle(.primary.opacity(0.85))
                        Button(tr("Más información…")) { showInfo = true }.buttonStyle(.link).font(.caption)
                            .popover(isPresented: $showInfo, arrowEdge: .trailing) { InfoPopover(object: obj, summary: sum) }
                    } else if info.isMissing(obj) {
                        Text(tr("Sin descripción disponible.")).font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text(tr("Cargando descripción…")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .task(id: obj.id) { await info.load(obj) }
            AltitudeSparkline(object: obj, night: night, minAlt: settings.minAltitude)
                .frame(height: 56)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text(tr("Ahora")).foregroundStyle(.secondary)
                    Text(String(format: "%.0f°", altNow)).foregroundStyle(altNow >= settings.minAltitude ? Theme.good : .secondary)
                    Text(tr("Mejor")).foregroundStyle(.secondary)
                    Text(forecast.bestTime?.shortTime ?? "—")
                }
                GridRow {
                    Text(tr("Útil")).foregroundStyle(.secondary)
                    Text(String(format: "%.1f h", forecast.minutesUsable / 60))
                    Text(tr("Luna")).foregroundStyle(.secondary)
                    Text(String(format: "%.0f°", forecast.moonSeparation))
                }
            }
            .font(.caption).monospacedDigit()
            AdviceSummary(object: obj)
            HStack {
                Button {
                    confirming = true
                } label: { Label(tr("Ir y apilar…"), systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!client.isConnected || busy || altNow < settings.minAltitude)
                Button {
                    plan.add(obj, minutes: min(120, max(30, (forecast.minutesUsable * 0.5 / 15).rounded() * 15)), fit: forecast.fit)
                    message = tr("%@ añadido al plan de la noche.", "\(obj.id)")
                } label: { Label(tr("Al plan"), systemImage: "text.badge.plus") }
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardStroke))
        .sheet(isPresented: $confirming) {
            GotoConfirmSheet(object: obj) { message = $0 }.nightMode()
        }
    }
}

/// Curva de altura compacta para la noche, con la franja de altura mínima y la hora actual.
@MainActor
struct AltitudeSparkline: View {
    let object: DeepSkyObject
    let night: Astro.Night?
    let minAlt: Double
    @EnvironmentObject var settings: AppSettings

    struct P: Identifiable { let id: Int; let t: Date; let alt: Double }

    var body: some View {
        let start = night?.sunset ?? Date()
        let end = night?.sunrise ?? start.addingTimeInterval(12 * 3600)
        let alt = Ephemeris.altitudeOfFixed(raJ2000: object.raHours, decJ2000: object.decDeg,
                                            lat: settings.latitude, lon: settings.longitude)
        let pts: [P] = stride(from: 0.0, through: end.timeIntervalSince(start), by: 1200).enumerated().map { i, dt in
            let t = start.addingTimeInterval(dt)
            return P(id: i, t: t, alt: max(0, alt(t)))
        }
        Chart {
            if let d = night?.duskStart, let a = night?.dawnEnd {
                RectangleMark(xStart: .value("Inicio", d), xEnd: .value("Fin", a))
                    .foregroundStyle(Theme.accent.opacity(0.08))
            }
            RuleMark(y: .value(tr("Mínima"), minAlt))
                .foregroundStyle(Theme.warn.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(pts) { p in
                AreaMark(x: .value("Hora", p.t), y: .value("Altura", p.alt))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Hora", p.t), y: .value("Altura", p.alt))
                    .foregroundStyle(Theme.accentSoft)
            }
            if Date() > start && Date() < end {
                RuleMark(x: .value("Ahora", Date())).foregroundStyle(.white.opacity(0.6))
            }
        }
        .chartYScale(domain: 0...90)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
            }
        }
    }
}

/// Ficha ampliada de un objeto con su descripción completa.
@MainActor
struct InfoPopover: View {
    @EnvironmentObject var settings: AppSettings
    let object: DeepSkyObject
    let summary: ObjectSummary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SkyImage(raHours: object.raHours, decDeg: object.decDeg, sizeArcmin: object.sizeArcmin,
                     fov: (settings.fovWidthDeg, settings.fovHeightDeg))
                .frame(width: 170)
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.title).font(.title3.bold())
                Text(tr("%@ · magnitud %@ · %@′", "\(object.kind.label)", "\(String(format: "%.1f", object.magnitude))", "\(String(format: "%.0f", object.sizeArcmin))"))
                    .font(.callout).foregroundStyle(.secondary)
                InfoRow(label: tr("AR / Dec (J2000)"), value: "\(Astro.formatRA(object.raHours))  \(Astro.formatDec(object.decDeg))")
                ScrollView { Text(summary.extract).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
                HStack {
                    if let u = summary.url, let url = URL(string: u), NetPolicy.isWikipedia(url) { Link(tr("Leer en Wikipedia"), destination: url) }
                    Spacer()
                    Text(tr("Texto: Wikipedia (CC BY-SA)")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
        .nightMode()
    }
}
