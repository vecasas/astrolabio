import SwiftUI
import AppKit

// MARK: - Eventos del cielo

@MainActor
struct SkyEventsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var comets = CometStore.shared
    @State private var events: [SkyEvent] = []
    @State private var loading = false
    @State private var kind: SkyEvent.Kind? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Lo que pasa en el cielo en las próximas seis semanas, calculado para tu lugar.")).foregroundStyle(.secondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
                Picker(tr("Tipo"), selection: $kind) {
                    Text(tr("Todos")).tag(SkyEvent.Kind?.none)
                    ForEach(SkyEvent.Kind.allCases, id: \.self) { k in Text(Self.kindName(k)).tag(Optional(k)) }
                }
                .pickerStyle(.segmented).labelsHidden()
                let shown = events.filter { kind == nil || $0.kind == kind }
                if shown.isEmpty && !loading {
                    Card(title: tr("Sin eventos"), systemImage: "calendar") { Text(tr("No hay eventos de este tipo en las próximas seis semanas.")) }
                }
                ForEach(Self.weeks(shown), id: \.start) { week in
                    Card(title: tr("Semana del %@", week.start.formatted(.dateTime.day().month(.wide).locale(Loc.shared.locale))), systemImage: "calendar") {
                        ForEach(week.items) { e in EventRow(event: e) }
                    }
                }
                Text(tr("Las horas son aproximadas (unos minutos). Las conjunciones se dan con la separación mínima vista desde el centro de la Tierra."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle(tr("Eventos del cielo"))
        .task(id: "\(settings.latitude),\(settings.longitude),\(comets.orbits.count)") { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let lat = settings.latitude, lon = settings.longitude, orbits = comets.orbits
        events = await Task.detached(priority: .userInitiated) {
            SkyEvents.upcoming(lat: lat, lon: lon, comets: orbits)
        }.value
        if comets.orbits.isEmpty { await comets.refreshIfNeeded() }
    }

    static func weeks(_ list: [SkyEvent]) -> [(start: Date, items: [SkyEvent])] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let groups = Dictionary(grouping: list) { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.date < $1.date }) }
    }

    static func kindName(_ k: SkyEvent.Kind) -> String {
        switch k {
        case .meteors: return tr("Meteoros")
        case .conjunction: return tr("Luna y planetas")
        case .pair: return tr("Parejas de planetas")
        case .phase: return tr("Fases")
        case .opposition: return tr("Oposiciones")
        case .elongation: return tr("Elongaciones")
        case .comet: return tr("Cometas")
        }
    }
}

struct EventRow: View {
    let event: SkyEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundStyle(Theme.accentSoft).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title).fontWeight(.semibold)
                    Spacer()
                    Text(event.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Loc.shared.locale)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Text(event.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !event.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(event.tags, id: \.self) { t in Pill(text: t.name, color: t.good ? Theme.good : Theme.warn) }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Satélites

@MainActor
final class SatellitePassModel: ObservableObject {
    static let shared = SatellitePassModel()
    @Published private(set) var passes: [SatellitePass] = []
    @Published private(set) var computing = false
    private var key = ""

    func update(tles: [TLE], lat: Double, lon: Double, force: Bool = false) async {
        let k = "\(lat),\(lon),\(tles.count),\(tles.first?.line1 ?? ""),\(Int(Date().timeIntervalSince1970 / 3600))"
        guard force || k != key, !tles.isEmpty else { return }
        key = k
        computing = true
        defer { computing = false }
        passes = await Task.detached(priority: .userInitiated) { Self.compute(tles, lat: lat, lon: lon) }.value
    }

    /// Estaciones tripuladas: todos los pasos visibles. El resto: solo los que suben por encima de 40°.
    nonisolated static func compute(_ tles: [TLE], lat: Double, lon: Double, from: Date = Date(), days: Double = 5) -> [SatellitePass] {
        var out: [SatellitePass] = []
        for t in tles {
            let crewed = isCrewed(t.name)
            out += Satellites.passes(t, from: from, days: days, lat: lat, lon: lon, minAltitude: 10)
                .filter { crewed || $0.maxAltitude >= 40 }
        }
        return out.sorted { $0.rise < $1.rise }.prefix(150).map { $0 }
    }

    nonisolated static func isCrewed(_ name: String) -> Bool {
        name.hasPrefix("ISS (ZARYA)") || name.hasPrefix("CSS (TIANHE)")
    }
}

@MainActor
struct SatellitesView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tonight: TonightModel
    @ObservedObject private var store = SatelliteStore.shared
    @ObservedObject private var model = SatellitePassModel.shared
    @State private var onlyCrewed = false
    @State private var target: String = ""
    @State private var crossings: [(name: String, at: Date, sep: Double)] = []
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Pasos visibles de la Estación Espacial y de los satélites más brillantes en las próximas cinco noches."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.computing { ProgressView().controlSize(.small) }
                    Button(tr("Actualizar órbitas")) { Task { await store.refreshIfNeeded(force: true); await recompute(force: true) } }
                }
                HStack(spacing: 12) {
                    if let u = store.updated {
                        Text(tr("Órbitas de CelesTrak del %@ · %d satélites", u.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Loc.shared.locale)), store.tles.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let e = store.error { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                    Spacer()
                    Toggle(tr("Solo estaciones tripuladas"), isOn: $onlyCrewed).toggleStyle(.checkbox)
                }

                Card(title: tr("¿Cruzará algo mi objetivo esta noche?"), systemImage: "exclamationmark.triangle") {
                    Text(tr("Un satélite iluminado deja una raya en la foto. Elige un objeto para ver qué satélites pasarán a menos de 1° mientras esté a oscuras. Durante una sesión automática el aviso es automático."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Picker(tr("Objeto"), selection: $target) {
                            Text(tr("Elige…")).tag("")
                            ForEach(tonight.forecasts.prefix(25)) { f in Text(f.object.displayName).tag(f.object.id) }
                        }
                        .frame(maxWidth: 360)
                        Button(tr("Comprobar")) { Task { await check() } }.disabled(target.isEmpty || checking || store.tles.isEmpty)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    if !checking && !target.isEmpty {
                        if crossings.isEmpty { Text(tr("Ningún cruce previsto.")).font(.callout).foregroundStyle(Theme.good) }
                        ForEach(Array(crossings.enumerated()), id: \.offset) { _, c in
                            Text(tr("%1$@ a las %2$@, a %3$.1f° del centro", c.name, c.at.shortTime, c.sep)).font(.callout)
                        }
                    }
                }

                let list = model.passes.filter { !onlyCrewed || SatellitePassModel.isCrewed($0.name) }
                Card(title: tr("Próximos pasos"), systemImage: "airplane") {
                    if list.isEmpty {
                        Text(store.tles.isEmpty ? tr("Descargando las órbitas…") : (model.computing ? tr("Calculando…") : tr("No hay pasos visibles en estos días.")))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(list) { p in PassRow(pass: p) }
                }
                Text(tr("Solo se muestran pasos con el satélite iluminado por el Sol y tu cielo a oscuras. Precisión: alrededor de un minuto con órbitas de menos de tres días."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle(tr("Satélites"))
        .task {
            await store.refreshIfNeeded()
            await recompute()
        }
        .onChange(of: target) { _, _ in crossings = [] }
    }

    private func recompute(force: Bool = false) async {
        await model.update(tles: store.tles, lat: settings.latitude, lon: settings.longitude, force: force)
    }

    private func check() async {
        guard let obj = Catalog.objects.first(where: { $0.id == target }) else { return }
        let n = tonight.night ?? Astro.night(for: Date(), lat: settings.latitude, lon: settings.longitude)
        guard let s = n.nauticalDusk ?? n.duskStart, let e = n.nauticalDawn ?? n.dawnEnd else { return }
        checking = true
        defer { checking = false }
        let tles = store.tles, lat = settings.latitude, lon = settings.longitude
        let from = max(s, Date())
        crossings = await Task.detached(priority: .userInitiated) {
            SatelliteStore.crossings(tles, raHours: obj.raHours, decDeg: obj.decDeg, from: from, to: e, lat: lat, lon: lon)
        }.value
    }
}

struct PassRow: View {
    let pass: SatellitePass
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SatellitePassModel.isCrewed(pass.name) ? "person.2.fill" : "circle.fill")
                .font(.caption).foregroundStyle(SatellitePassModel.isCrewed(pass.name) ? Theme.good : Theme.accentSoft).frame(width: 22)
            Text(pass.name).frame(width: 190, alignment: .leading).lineLimit(1)
            Text(pass.rise.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(Loc.shared.locale)))
                .monospacedDigit().frame(width: 130, alignment: .leading)
            Text(tr("%1$@ → %2$@", Compass.name(pass.riseAzimuth), Compass.name(pass.setAzimuth))).frame(width: 90, alignment: .leading)
            Text(tr("máx. %.0f°", pass.maxAltitude)).monospacedDigit().frame(width: 70, alignment: .leading)
            Text(tr("%.0f min", pass.set.timeIntervalSince(pass.rise) / 60)).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }
}

enum Compass {
    static func name(_ az: Double) -> String {
        let n = [tr("N"), tr("NE"), tr("E"), tr("SE"), tr("S"), tr("SO"), tr("O"), tr("NO")]
        return n[Int((Astro.norm360(az) + 22.5) / 45) % 8]
    }
}
