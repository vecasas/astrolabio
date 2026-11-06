import SwiftUI

/// «Elige por mí»: propone un objeto concreto (o un plan corto) listo para lanzar.
@MainActor
struct PickForMeView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sky: SkyStore
    @EnvironmentObject var tonight: TonightModel
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var plan: PlanStore
    @EnvironmentObject var nav: AppNavigation

    @State private var style: PickStyle = .best
    @State private var index = 0
    @State private var suggestions: [Suggestion] = []
    @State private var shortPlan: [PlanItem] = []
    @State private var message = ""
    @State private var busy = false
    @State private var confirmObject: DeepSkyObject?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ForEach(PickStyle.allCases) { s in
                        Button {
                            style = s
                            index = 0
                            recompute()
                        } label: {
                            Label(s.label, systemImage: s.symbol)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(style == s ? Theme.accent : Theme.card))
                                .overlay(Capsule().stroke(style == s ? Theme.accentSoft : Theme.cardStroke))
                                .foregroundStyle(style == s ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if tonight.isComputing { ProgressView().controlSize(.small) }
                }

                if let s = current {
                    hero(s)
                } else {
                    Card(title: tr("Sin sugerencias"), systemImage: "moon.zzz") {
                        Text(tonight.forecasts.isEmpty
                             ? tr("Calculando la noche…")
                             : tr("Ahora mismo no hay ningún objeto de este tipo lo bastante alto durante al menos 40 minutos. Prueba otro estilo o baja la altura mínima en Ajustes."))
                            .foregroundStyle(.secondary)
                    }
                }

                if !message.isEmpty { Text(message).foregroundStyle(Theme.accentSoft) }
                planCard
            }
            .padding(20)
        }
        .navigationTitle(tr("Elige por mí"))
        .sheet(item: Binding(get: { confirmObject.map { IdentifiedObject(object: $0) } }, set: { confirmObject = $0?.object })) { w in
            GotoConfirmSheet(object: w.object) { message = $0 }.nightMode()
        }
        .task(id: sky.lastUpdate) {
            await tonight.update(settings: settings, weather: sky.hours)
            recompute()
        }
        .onChange(of: tonight.computedAt) { _, _ in recompute() }
    }

    private var current: Suggestion? {
        suggestions.isEmpty ? nil : suggestions[index % suggestions.count]
    }

    private func recompute() {
        suggestions = Picker4Me.suggestions(from: tonight.forecasts, night: tonight.night, style: style,
                                            lat: settings.latitude, lon: settings.longitude,
                                            minAltitude: settings.minAltitude)
        shortPlan = Picker4Me.shortPlan(from: tonight.forecasts, night: tonight.night,
                                        lat: settings.latitude, lon: settings.longitude,
                                        minAltitude: settings.minAltitude)
    }

    private func hero(_ s: Suggestion) -> some View {
        let obj = s.forecast.object
        let later = s.start > Date().addingTimeInterval(120)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                SkyImage(raHours: obj.raHours, decDeg: obj.decDeg, sizeArcmin: obj.sizeArcmin,
                         fov: (settings.fovWidthDeg, settings.fovHeightDeg))
                    .frame(width: 170)
                    .id(obj.id)
                VStack(alignment: .leading, spacing: 6) {
                    Text(later ? tr("Cuando oscurezca (%@) te propongo…", "\(s.start.shortTime)") : tr("Te propongo…"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(obj.id).font(.system(size: 34, weight: .bold, design: .rounded))
                    if !obj.localizedName.isEmpty { Text(obj.localizedName).font(.title3).foregroundStyle(Theme.accentSoft) }
                    HStack {
                        Pill(text: obj.kind.label, systemImage: obj.kind.symbol)
                        Pill(text: tr("Nota %.0f", s.forecast.score), systemImage: "star.fill", color: Theme.scoreColor(s.forecast.score))
                        Pill(text: tr("mag %.1f · %.0f′", obj.magnitude, obj.sizeArcmin), color: .secondary)
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Por qué")).font(.headline)
                ForEach(s.reasons, id: \.self) { r in
                    Label(r, systemImage: "checkmark.circle").foregroundStyle(.primary.opacity(0.9))
                }
            }
            let adv = CaptureAdvice.make(for: obj, lat: settings.latitude, lon: settings.longitude,
                                         minAltitude: settings.minAltitude, night: tonight.night,
                                         gain: client.currentGain ?? settings.gain, now: s.start)
            HStack(spacing: 14) {
                StatTile(title: tr("Duración sugerida"), value: tr("%.0f min", adv.minutes), systemImage: "timer")
                StatTile(title: tr("Exposición"), value: "\(adv.exposureMs / 1000) s", systemImage: "camera.shutter.button",
                         detail: tr("Ganancia %@", "\(adv.gain)"))
                StatTile(title: tr("Filtro LP"), value: adv.lpFilter ? tr("Sí") : tr("No"), systemImage: "camera.filters")
            }
            AltitudeSparkline(object: obj, night: tonight.night, minAlt: settings.minAltitude).frame(height: 90)
            HStack {
                Button {
                    confirmObject = obj
                } label: { Label(tr("Apuntar y apilar…"), systemImage: "scope").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!client.isConnected || busy || later)
                Button { index += 1 } label: { Label(tr("Otra sugerencia"), systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.large)
                    .disabled(suggestions.count < 2)
                Button {
                    var item = PlanItem(name: obj.id, raHours: obj.raHours, decDeg: obj.decDeg, minutes: s.suggestedMinutes)
                    item.lpFilter = s.useLPFilter
                    plan.items.append(item)
                    message = tr("%@ añadido al plan.", "\(obj.id)")
                } label: { Label(tr("Al plan"), systemImage: "text.badge.plus") }
                    .controlSize(.large)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Text(tr("%@ de %@", "\(index % max(1, suggestions.count) + 1)", "\(suggestions.count)")).font(.caption).foregroundStyle(.secondary)
            }
            if !client.isConnected {
                Text(tr("Conecta el telescopio para apuntar directamente.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Theme.midnight, Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent.opacity(0.35)))
    }

    private var planCard: some View {
        Card(title: tr("O deja que planifique el resto de la noche"), systemImage: "list.bullet.rectangle") {
            if shortPlan.isEmpty {
                Text(tr("No queda suficiente noche para un plan (o aún se está calculando).")).foregroundStyle(.secondary)
            } else {
                ForEach(Array(shortPlan.enumerated()), id: \.element.id) { i, item in
                    HStack {
                        Text("\(i + 1).").foregroundStyle(Theme.accent).frame(width: 22, alignment: .leading)
                        Text(Catalog.find(item.name)?.displayName ?? item.name).fontWeight(.semibold)
                        Spacer()
                        Text(item.notBefore.map { tr("desde las %@", "\($0.shortTime)") } ?? "ahora").foregroundStyle(.secondary)
                        Text(tr("%.0f min", item.minutes)).monospacedDigit()
                        if item.lpFilter { Pill(text: tr("LP"), color: Theme.accentSoft) }
                    }
                }
                HStack {
                    Button {
                        plan.items.append(contentsOf: shortPlan)
                        nav.selection = .session
                    } label: { Label(tr("Añadir al plan y abrir Sesión automática"), systemImage: "moon.stars") }
                        .buttonStyle(.borderedProminent)
                    Text(tr("La sesión automática apunta, enfoca, apila y pasa al siguiente sola."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

