import SwiftUI

/// Las próximas 7 noches valoradas por nubes, Luna y oscuridad, con la mejor destacada.
@MainActor
struct WeekOutlookCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sky: SkyStore

    var body: some View {
        let nights = WeekOutlook.nights(lat: settings.latitude, lon: settings.longitude, weather: sky.hours)
        let best = WeekOutlook.best(nights)
        Card(title: tr("La semana"), systemImage: "calendar") {
            if let best {
                Text(tr("Mejor noche: %@ (%@ puntos)", best.date.formatted(.dateTime.weekday(.wide).day().locale(Loc.shared.locale)), "\(best.score)"))
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.good)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(nights) { n in
                    VStack(spacing: 3) {
                        Text("\(n.score)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(n.id == best?.id ? Theme.good : Theme.accent.opacity(n.cloud == nil ? 0.25 : 0.7))
                            .frame(width: 30, height: max(4, CGFloat(n.score)))
                        Text(n.date.formatted(.dateTime.weekday(.abbreviated).locale(Loc.shared.locale))).font(.caption2)
                        Text(n.cloud.map { "☁︎ \(Int($0)) %" } ?? "—").font(.caption2).foregroundStyle(.secondary)
                        Text("☾ \(Int(n.moonIllumination * 100)) %").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(tr("%@ h de noche cerrada · nubes %@ · Luna al %@ %%, sobre el horizonte el %@ %% de la noche",
                             String(format: "%.1f", n.darkHours), n.cloud.map { "\(Int($0)) %" } ?? "—",
                             "\(Int(n.moonIllumination * 100))", "\(Int(n.moonUpFraction * 100))"))
                }
            }
            .frame(height: 170, alignment: .bottom)
            Text(tr("Puntos: nubes durante la noche (lo que más pesa), Luna y horas de oscuridad. Sin previsión, la barra sale tenue."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Cometas más brillantes que magnitud 12 que se pueden ver esta noche.
@MainActor
struct CometsTonightCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var plan: PlanStore
    @ObservedObject var store = CometStore.shared
    let night: Astro.Night?
    @Binding var message: String
    @State private var list: [Comets.Forecast] = []

    var body: some View {
        Card(title: tr("Cometas esta noche"), systemImage: "moon.dust") {
            if list.isEmpty {
                Text(store.orbits.isEmpty ? (store.error ?? tr("Descargando las órbitas de los cometas…"))
                     : tr("Ningún cometa más brillante que la magnitud 12 sube lo bastante esta noche."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(list.prefix(6)) { c in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.orbit.name).font(.callout.weight(.semibold))
                        Text(tr("mag %@ · máx. %@° a las %@ · a %@ UA de la Tierra",
                                String(format: "%.1f", c.position.magnitude), "\(Int(c.maxAltitude))",
                                c.best?.shortTime ?? "—", String(format: "%.2f", c.position.delta)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Ir y apilar")) { go(c) }.disabled(!client.isConnected)
                    Button(tr("Al plan")) { addToPlan(c) }
                }
            }
            Text(tr("Órbitas del Minor Planet Center, actualizadas cada día. En la sesión automática el telescopio vuelve a apuntar al cometa cuando se ha movido."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .task(id: "\(store.orbits.count)|\(night?.duskStart?.timeIntervalSince1970 ?? 0)") {
            await store.refreshIfNeeded()
            guard let night else { return }
            let orbits = store.orbits, lat = settings.latitude, lon = settings.longitude, minAlt = settings.minAltitude
            list = await Task.detached { Comets.visible(orbits, night: night, lat: lat, lon: lon, minAltitude: minAlt) }.value
        }
    }

    private func go(_ c: Comets.Forecast) {
        let p = Comets.position(c.orbit, date: Date())
        message = tr("Apuntando a %@…", c.orbit.name)
        Task {
            let r = await client.gotoAndStack(name: SafeName.fileComponent(c.orbit.name), raJ2000: p.raHours, decJ2000: p.decDeg, lpFilter: false)
            message = r.message
        }
    }

    private func addToPlan(_ c: Comets.Forecast) {
        var item = PlanItem(name: c.orbit.name, raHours: c.position.raHours, decDeg: c.position.decDeg, minutes: 60)
        item.comet = c.orbit.name
        plan.items.append(item)
        message = tr("%@ añadido al plan.", c.orbit.name)
    }
}
