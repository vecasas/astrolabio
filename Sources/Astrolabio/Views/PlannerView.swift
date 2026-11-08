import SwiftUI
import Charts

@MainActor
struct PlannerView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plan: PlanStore
    @EnvironmentObject var client: SeestarClient
    @State private var confirmObject: DeepSkyObject?
    @State private var goMessage = ""

    @State private var date = Date()
    @State private var forecasts: [TargetForecast] = []
    @State private var weather: [WeatherHour] = []
    @State private var night: Astro.Night?
    @State private var selectedID: String?
    @State private var kindFilter: ObjectKind? = nil
    @State private var fullCatalog = false
    @State private var search = ""
    @State private var loading = false
    @State private var weatherNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            HSplitView {
                table.frame(minWidth: 440, idealWidth: 640)
                detail.frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            }
        }
        .navigationTitle(tr("Planificar la noche"))
        .sheet(item: Binding(get: { confirmObject.map { IdentifiedObject(object: $0) } }, set: { confirmObject = $0?.object })) { w in
            GotoConfirmSheet(object: w.object) { goMessage = $0 }.nightMode()
        }
        .task(id: date) { await recompute() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker(tr("Noche del"), selection: $date, displayedComponents: .date)
                    .frame(width: 220)
                Text(settings.siteName).font(.caption).foregroundStyle(.secondary)
            }
            if let n = night {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Puesta de Sol: %@", "\(n.sunset?.shortTime ?? "—")"))
                    Text(tr("Noche cerrada: %@ – %@", "\(n.duskStart?.shortTime ?? "—")", "\(n.dawnEnd?.shortTime ?? "—")"))
                    Text(tr("Salida del Sol: %@", "\(n.sunrise?.shortTime ?? "—")"))
                }.font(.callout)
                let midnight = n.duskStart.flatMap { s in n.dawnEnd.map { s.addingTimeInterval($0.timeIntervalSince(s) / 2) } } ?? date
                let m = Astro.moon(midnight)
                let ph = Astro.moonPhase(midnight)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Luna: %@", "\(ph.name)"))
                    Text(tr("Iluminada al %.0f %%", m.illumination * 100))
                    Text(weatherNote).foregroundStyle(.secondary)
                }.font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Picker(tr("Tipo"), selection: $kindFilter) {
                    Text(tr("Todos")).tag(ObjectKind?.none)
                    ForEach(ObjectKind.allCases) { k in Text(k.label).tag(Optional(k)) }
                }
                .frame(width: 240)
                TextField(tr("Buscar"), text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                Toggle(tr("Catálogo completo (%@ objetos)", "\(Catalog.objects.count)"), isOn: $fullCatalog)
                    .help(tr("Incluye unos 1 600 objetos NGC e IC más débiles (datos de OpenNGC)."))
            }
            if loading { ProgressView().controlSize(.small) }
        }
    }

    private var filtered: [TargetForecast] {
        forecasts.filter { f in
            (fullCatalog || f.object.magnitude <= 10 || Catalog.featured.contains(f.object) || !search.isEmpty) &&
            (kindFilter == nil || f.object.kind == kindFilter) &&
            (search.isEmpty || f.object.displayName.localizedCaseInsensitiveContains(search))
        }
    }

    private var table: some View {
        Table(filtered, selection: $selectedID) {
            TableColumn(tr("Objeto")) { f in
                Label(f.object.displayName, systemImage: f.object.kind.symbol)
            }
            .width(min: 180, ideal: 240)
            TableColumn(tr("Nota")) { f in
                Text(String(format: "%.0f", f.score)).monospacedDigit()
                    .foregroundStyle(f.score > 50 ? Color.green : (f.score > 25 ? Color.primary : Color.secondary))
            }
            .width(50)
            TableColumn(tr("Tiempo útil")) { f in
                Text(String(format: "%.1f h", f.minutesUsable / 60)).monospacedDigit()
            }
            .width(80)
            TableColumn(tr("Altura máx.")) { f in Text(String(format: "%.0f°", f.maxAltitude)).monospacedDigit() }
                .width(75)
            TableColumn(tr("Mejor hora")) { f in Text(f.bestTime?.shortTime ?? "—") }
                .width(75)
            TableColumn(tr("Luna")) { f in Text(String(format: "%.0f°", f.moonSeparation)).monospacedDigit() }
                .width(50)
            TableColumn(tr("Nubes")) { f in Text(f.meanCloud.map { String(format: "%.0f %%", $0) } ?? "—") }
                .width(55)
            TableColumn(tr("Encuadre")) { f in Text(f.fit.label) }
                .width(90)
            TableColumn("") { f in
                Button(tr("Añadir")) { plan.add(f.object, minutes: suggestedMinutes(f), fit: f.fit) }
                    .buttonStyle(.borderless)
            }
            .width(60)
        }
    }

    private func suggestedMinutes(_ f: TargetForecast) -> Double {
        min(120, max(30, (f.minutesUsable * 0.5 / 15).rounded() * 15))
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let f = forecasts.first(where: { $0.id == id }), let n = night,
           let start = n.sunset, let end = n.sunrise {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(f.object.displayName).font(.title2.bold())
                    Text(tr("%@ · magnitud %@ · %@′", "\(f.object.kind.label)", "\(String(format: "%.1f", f.object.magnitude))", "\(String(format: "%.0f", f.object.sizeArcmin))"))
                        .foregroundStyle(.secondary)
                    AltitudeChart(object: f.object, start: start, end: end, night: n,
                                  lat: settings.latitude, lon: settings.longitude, minAlt: settings.minAltitude)
                        .frame(height: 220)
                    InfoRow(label: tr("AR / Dec (J2000)"), value: "\(Astro.formatRA(f.object.raHours))  \(Astro.formatDec(f.object.decDeg))")
                    InfoRow(label: tr("Ventana útil"), value: "\(f.windowStart?.shortTime ?? "—") – \(f.windowEnd?.shortTime ?? "—")")
                    InfoRow(label: tr("Separación de la Luna"), value: String(format: "%.0f°", f.moonSeparation))
                    InfoRow(label: tr("Encuadre en el Seestar"), value: f.fit.label)
                    Text(tr("Recomendación")).font(.headline).padding(.top, 4)
                    AdviceSummary(object: f.object)
                    Button { confirmObject = f.object } label: { Label(tr("Ir y apilar…"), systemImage: "scope") }
                        .disabled(!client.isConnected)
                    if !goMessage.isEmpty { Text(goMessage).font(.caption).foregroundStyle(Theme.accentSoft) }
                    HStack {
                        Button(tr("Añadir al plan")) { plan.add(f.object, minutes: suggestedMinutes(f), fit: f.fit) }
                            .buttonStyle(.borderedProminent)
                        Button(tr("Añadir sin mosaico")) { plan.add(f.object, minutes: suggestedMinutes(f), fit: nil) }
                    }
                }
                .padding(16)
            }
        } else {
            Text(tr("Elige un objeto para ver su altura durante la noche."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recompute() async {
        loading = true
        defer { loading = false }
        let n = Astro.night(for: date, lat: settings.latitude, lon: settings.longitude)
        night = n
        do {
            weather = try await WeatherService.forecast(lat: settings.latitude, lon: settings.longitude)
            weatherNote = weather.isEmpty ? "" : tr("Previsión de nubes de Open-Meteo")
        } catch {
            weather = []
            weatherNote = tr("Sin previsión del tiempo")
        }
        let lat = settings.latitude, lon = settings.longitude, minAlt = settings.minAltitude
        let fov = (w: settings.fovWidthDeg, h: settings.fovHeightDeg)
        let w = weather
        forecasts = await Task.detached {
            Planner.evaluate(objects: Catalog.objects, night: n, lat: lat, lon: lon,
                             minAltitude: minAlt, fov: fov, weather: w)
        }.value
    }
}

@MainActor
struct AltitudeChart: View {
    let object: DeepSkyObject
    let start: Date
    let end: Date
    let night: Astro.Night
    let lat: Double
    let lon: Double
    let minAlt: Double

    struct Point: Identifiable { let id = UUID(); let t: Date; let alt: Double; let series: String }

    private var points: [Point] {
        var out: [Point] = []
        var t = start
        while t <= end {
            let now = Astro.precessFromJ2000(raHours: object.raHours, decDeg: object.decDeg, to: t)
            out.append(Point(t: t, alt: Astro.altAz(raHours: now.ra, decDeg: now.dec, date: t, lat: lat, lon: lon).alt, series: tr("Objeto")))
            let m = Astro.moon(t)
            out.append(Point(t: t, alt: Astro.altAz(raHours: m.ra, decDeg: m.dec, date: t, lat: lat, lon: lon).alt, series: tr("Luna")))
            t = t.addingTimeInterval(900)
        }
        return out
    }

    var body: some View {
        Chart {
            if let d = night.duskStart, let a = night.dawnEnd {
                RectangleMark(xStart: .value("Inicio", d), xEnd: .value("Fin", a), yStart: .value("Altura", 0.0), yEnd: .value("Altura", 90.0))
                    .foregroundStyle(Color.indigo.opacity(0.12))
            }
            RuleMark(y: .value(tr("Mínima"), minAlt))
                .foregroundStyle(Color.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(points) { p in
                LineMark(x: .value("Hora", p.t), y: .value("Altura", p.alt))
                    .foregroundStyle(by: .value("Serie", p.series))
            }
        }
        .chartYScale(domain: 0...90)
        .chartPlotStyle { $0.clipped() }
        .chartForegroundStyleScale([tr("Objeto"): Color.accentColor, tr("Luna"): Color.gray])
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
    }
}
