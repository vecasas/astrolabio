import Foundation

/// Vigilancia de la noche: nitidez de las estrellas, rocío, avisos oficiales y tormentas.
/// La sesión automática le consulta si debe recoger el telescopio o volver a enfocar.
@MainActor
final class NightGuard: ObservableObject {
    @Published private(set) var focusVerdict: FocusWatch.Verdict = .learning
    @Published private(set) var lastHFR: Double?
    @Published private(set) var dewRisk: DewRisk = .low
    @Published private(set) var warnings: [WeatherWarning] = []
    @Published private(set) var stormReason: String?
    @Published private(set) var lastWarningsFetch: Date?

    /// La sesión automática enfoca de nuevo antes del siguiente objeto o panel.
    var needsRefocus: Bool {
        if case .softening = focusVerdict { return true }
        return false
    }

    private var watch = FocusWatch()
    private var limiter = AlertLimiter(interval: 1800)
    private var heaterOn = false
    private weak var client: SeestarClient?
    private weak var settings: AppSettings?
    private weak var sky: SkyStore?

    func attach(client: SeestarClient, settings: AppSettings, sky: SkyStore, live: LiveViewModel) {
        self.client = client
        self.settings = settings
        self.sky = sky
        live.onStarMetrics = { [weak self] m in self?.handle(m) }
    }

    /// Nueva medida de nitidez de un apilado.
    func handle(_ m: StarMetrics.Result) {
        guard let client, let settings, settings.focusWatch else { return }
        lastHFR = m.hfr
        watch.threshold = settings.focusThresholdPercent / 100
        let target = client.viewTarget ?? ""
        focusVerdict = watch.add(hfr: m.hfr, target: target)
        if case .softening(let pct) = focusVerdict, limiter.shouldSend("focus") {
            var text = tr("⚠️ Las estrellas están un %@ %% menos nítidas que al empezar %@: revisa el enfoque o el rocío.", "\(pct)", target)
            if dewRisk != .low { text += " " + tr("Hay riesgo de rocío: enciende el calentador.") }
            client.addLog(text, .warning)
            settings.notify("Astrolabio", text)
        }
    }

    /// Después de enfocar de nuevo, la referencia vuelve a aprenderse.
    func refocused() {
        watch.reset(target: client?.viewTarget ?? "")
        focusVerdict = .learning
    }

    /// Se llama cada minuto desde el monitor de salud.
    func tick() async {
        guard let client, let settings else { return }
        // Rocío.
        if let t = sky?.currentTemperature, let dp = sky?.currentDewPoint {
            let risk = DewRisk.level(temperature: t, dewPoint: dp)
            if risk != dewRisk { dewRisk = risk }
            if risk == .high && client.isConnected {
                if settings.autoDewHeater && !heaterOn {
                    let power = settings.dewHeaterPower > 0 ? settings.dewHeaterPower : 60
                    if (try? await client.setDewHeater(power: power)) != nil {
                        heaterOn = true
                        client.addLog(tr("Riesgo alto de rocío: calentador encendido al %@ %%.", "\(power)"))
                    }
                } else if !settings.autoDewHeater && limiter.shouldSend("dew") {
                    let text = tr("💧 Riesgo alto de rocío (%@ °C, punto de rocío %@ °C). Enciende el calentador del Seestar.",
                                  String(format: "%.0f", t), String(format: "%.0f", dp))
                    client.addLog(text, .warning)
                    settings.notify("Astrolabio", text)
                }
            }
        }
        // Avisos oficiales cada 15 minutos.
        if Date().timeIntervalSince(lastWarningsFetch ?? .distantPast) > 900 {
            lastWarningsFetch = Date()
            if let all = try? await MeteoAlarm.fetch(country: settings.alertCountry) {
                warnings = all.filter { settings.alertZone.isEmpty ? false : $0.area == settings.alertZone }
            }
        }
        let reason = settings.stormGuard ? StormGuard.reason(warnings: warnings, hours: sky?.hours ?? []) : nil
        if reason != stormReason {
            stormReason = reason
            if let reason, limiter.shouldSend("storm") {
                let text = tr("⛈ %@", reason)
                client.addLog(text, .warning)
                settings.notify("Astrolabio", text)
            }
        }
    }
}
