import SwiftUI

/// Recomendación de captura para un objeto: duración, exposición, ganancia y filtro LP.
struct CaptureAdvice: Equatable {
    var minutes: Double            // duración sugerida
    var exposureMs: Int            // exposición de cada subtoma
    var gain: Int
    var lpFilter: Bool
    var remainingMinutes: Double   // minutos que le quedan por encima de la altura mínima
    var altitudeNow: Double
    var reasons: [String]

    /// Cálculo sencillo y explicable:
    /// - Duración: el 80 % del tiempo que le queda por encima de la altura mínima (hasta el
    ///   amanecer), entre 20 y 120 minutos.
    /// - Exposición: 10 s para objetos muy brillantes (se saturan), 20 s para los intermedios y
    ///   30 s para los débiles o cuando se usa el filtro LP, que quita luz.
    /// - Filtro LP: nebulosas de emisión, planetarias y restos de supernova.
    static func make(for obj: DeepSkyObject, lat: Double, lon: Double, minAltitude: Double,
                     night: Astro.Night?, gain: Int, maxExposureMs: Int = 30_000, now: Date = Date()) -> CaptureAdvice {
        let alt = Ephemeris.altitudeOfFixed(raJ2000: obj.raHours, decJ2000: obj.decDeg, lat: lat, lon: lon)
        let a0 = alt(now)
        let end = night?.dawnEnd.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(8 * 3600)
        var remaining = 0.0
        var t = now
        while t < end, alt(t) >= minAltitude { remaining += 5; t = t.addingTimeInterval(300) }

        let lp = [.nebula, .snr, .planetary].contains(obj.kind)
        var exp: Int
        var reasons: [String] = []
        if obj.magnitude <= 5.5 || (obj.kind == .open && obj.magnitude <= 7) {
            exp = 10_000
            reasons.append(tr("Es muy brillante (mag %.1f): 10 s evitan que las estrellas se saturen.", obj.magnitude))
        } else if obj.magnitude <= 8.5 && !lp {
            exp = 20_000
            reasons.append(tr("Brillo intermedio (mag %.1f): 20 s por toma.", obj.magnitude))
        } else {
            exp = 30_000
            reasons.append(lp ? tr("Con el filtro LP llega menos luz: mejor tomas largas de 30 s.")
                              : tr("Es débil (mag %.1f): tomas largas de 30 s.", obj.magnitude))
        }
        exp = min(exp, maxExposureMs)
        reasons.append(lp ? tr("%@: el filtro antipolución (LP) realza el gas y oscurece el fondo.", "\(obj.kind.label)")
                          : tr("%@: sin filtro LP, para conservar el color de las estrellas.", "\(obj.kind.label)"))

        var minutes = min(remaining * 0.8, 120)
        minutes = max(20, (minutes / 10).rounded() * 10)
        if a0 < minAltitude {
            reasons.append(tr("Ahora está a %.0f°, por debajo de la altura mínima (%.0f°).", a0, minAltitude))
        } else {
            reasons.append(tr("Le quedan %.1f h por encima de %.0f°: %.0f min de apilado dan buen resultado.",
                                  remaining / 60, minAltitude, minutes))
        }
        return CaptureAdvice(minutes: minutes, exposureMs: exp, gain: gain, lpFilter: lp,
                             remainingMinutes: remaining, altitudeNow: a0, reasons: reasons)
    }
}

/// Para el apilado cuando se cumple la duración elegida (mientras la app siga abierta).
@MainActor
final class StackTimer {
    static let shared = StackTimer()
    private var task: Task<Void, Never>?
    private(set) var target: String?
    private(set) var endsAt: Date?

    func schedule(_ client: SeestarClient, name: String, minutes: Double, settings: AppSettings? = nil) {
        task?.cancel()
        target = name
        endsAt = Date().addingTimeInterval(minutes * 60)
        task = Task { @MainActor [weak client] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let client else { return }
            try? await client.stopStack()
            client.addLog(tr("Duración cumplida: apilado de %@ detenido.", "\(name)"))
            if let settings { settings.notify(tr("Apilado terminado"), tr("%@: %@ minutos completados.", "\(name)", "\(Int(minutes))")) }
            else { Notifier.local(tr("Apilado terminado"), tr("%@: %@ minutos completados.", "\(name)", "\(Int(minutes))")) }
            self.target = nil
            self.endsAt = nil
        }
    }

    func cancel() { task?.cancel(); target = nil; endsAt = nil }
}

/// Hoja «Antes de ir»: muestra (y deja cambiar) duración, exposición, ganancia y filtro LP.
@MainActor
struct GotoConfirmSheet: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var tonight: TonightModel
    @Environment(\.dismiss) private var dismiss

    let object: DeepSkyObject
    var onResult: (String) -> Void = { _ in }

    @State private var advice: CaptureAdvice?
    @State private var minutes = 60.0
    @State private var exposureMs = 30_000
    @State private var gain = 80
    @State private var lp = false
    @State private var stopAtEnd = true
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: object.kind.symbol).font(.largeTitle).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Antes de ir a %@", "\(object.id)")).font(.title2.bold())
                    Text(object.localizedName.isEmpty ? object.kind.label : "\(object.localizedName) · \(object.kind.label)")
                        .foregroundStyle(.secondary)
                }
            }
            if let a = advice {
                HStack(alignment: .top, spacing: 14) {
                    SkyImage(raHours: object.raHours, decDeg: object.decDeg, sizeArcmin: object.sizeArcmin,
                             fov: (settings.fovWidthDeg, settings.fovHeightDeg))
                        .frame(width: 130)
                    VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    StatTile(title: tr("Duración sugerida"), value: tr("%.0f min", a.minutes), systemImage: "timer")
                    StatTile(title: tr("Exposición"), value: "\(a.exposureMs / 1000) s", systemImage: "camera.shutter.button",
                             detail: tr("Ganancia %@", "\(a.gain)"))
                    StatTile(title: tr("Filtro LP"), value: a.lpFilter ? tr("Sí") : tr("No"), systemImage: "camera.filters")
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(a.reasons, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                }
                    }
                }
            }
            Divider()
            Text(tr("Ajustes para esta sesión")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(tr("Duración"))
                    Stepper(tr("%.0f min", minutes), value: $minutes, in: 10...240, step: 10)
                }
                GridRow {
                    Text(tr("Exposición"))
                    Picker("", selection: $exposureMs) {
                        Text("10 s").tag(10_000); Text("20 s").tag(20_000); Text("30 s").tag(30_000)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                }
                GridRow {
                    Text(tr("Ganancia"))
                    HStack {
                        Slider(value: Binding(get: { Double(gain) }, set: { gain = Int($0) }),
                               in: Double(client.gainRange?.lowerBound ?? 0)...Double(max(client.gainRange?.upperBound ?? 120, gain)), step: 5)
                            .frame(width: 180)
                        Text("\(gain)").monospacedDigit()
                    }
                }
                GridRow {
                    Text(tr("Filtro LP"))
                    Toggle(tr("Usar el filtro antipolución"), isOn: $lp)
                }
                GridRow {
                    Text(tr("Al terminar"))
                    Toggle(tr("Parar el apilado al cumplir la duración"), isOn: $stopAtEnd)
                }
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(Theme.accentSoft) }
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button {
                    go()
                } label: { Label(tr("Ir y apilar"), systemImage: "scope").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!client.isConnected || busy || (advice?.altitudeNow ?? 0) < 10)
            }
            if !client.isConnected { Text(tr("Conecta el telescopio para apuntar.")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(width: 760)
        .background(Theme.deep)
        .onAppear(perform: compute)
    }

    private func compute() {
        let g = client.currentGain ?? settings.gain
        let a = CaptureAdvice.make(for: object, lat: settings.latitude, lon: settings.longitude,
                                   minAltitude: settings.minAltitude, night: tonight.night, gain: g)
        advice = a
        minutes = a.minutes
        exposureMs = a.exposureMs
        gain = a.gain
        lp = a.lpFilter
    }

    private func go() {
        busy = true
        status = tr("Aplicando exposición y ganancia…")
        let name = object.id, ra = object.raHours, dec = object.decDeg
        let exp = exposureMs, g = gain, useLP = lp, mins = minutes, stop = stopAtEnd
        Task {
            do {
                try await client.setExposure(ms: exp)
                try await client.setGain(g)
                settings.exposureMs = exp
                settings.gain = g
            } catch {
                client.addLog(tr("No se pudieron aplicar los ajustes: %@", "\(error.localizedDescription)"), .warning)
            }
            status = tr("Apuntando a %@…", "\(name)")
            let result = await client.gotoAndStack(name: name, raJ2000: ra, decJ2000: dec, lpFilter: useLP)
            if stop && result.ok {
                StackTimer.shared.schedule(client, name: name, minutes: mins, settings: settings)
            }
            let msg = result.message + (stop && result.ok ? tr(" Se parará a los %@ min.", "\(Int(mins))") : "")
            onResult(msg)
            busy = false
            dismiss()
        }
    }
}

/// Resumen compacto de la recomendación (para tarjetas y paneles).
@MainActor
struct AdviceSummary: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var tonight: TonightModel
    let object: DeepSkyObject

    var body: some View {
        let a = CaptureAdvice.make(for: object, lat: settings.latitude, lon: settings.longitude,
                                   minAltitude: settings.minAltitude, night: tonight.night,
                                   gain: client.currentGain ?? settings.gain)
        HStack(spacing: 6) {
            Pill(text: tr("%.0f min", a.minutes), systemImage: "timer", color: Theme.accentSoft)
            Pill(text: "\(a.exposureMs / 1000) s", systemImage: "camera.shutter.button", color: Theme.accentSoft)
            Pill(text: a.lpFilter ? tr("Filtro LP") : tr("Sin LP"), systemImage: "camera.filters", color: a.lpFilter ? Theme.good : .secondary)
        }
        .help(a.reasons.joined(separator: "\n"))
    }
}
