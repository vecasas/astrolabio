import Foundation

struct PlanItem: Identifiable, Codable, Hashable {
    enum Status: String, Codable { case pending, running, done, skipped, failed }

    var id = UUID()
    var name: String
    var raHours: Double        // J2000
    var decDeg: Double         // J2000
    var minutes: Double = 60
    var lpFilter = false
    var autofocus = true
    var mosaicColumns = 1
    var mosaicRows = 1
    var overlapPercent = 15.0
    var notBefore: Date?
    var status: Status = .pending
    var stackedFrames = 0
    /// Segundos ya apilados (para retomar el plan tras un reinicio).
    var doneSeconds: Double?

    var isMosaic: Bool { mosaicColumns * mosaicRows > 1 }
}

/// Plan de una noche, guardado en Application Support/Astrolabio/plan.json.
@MainActor
final class PlanStore: ObservableObject {
    @Published var items: [PlanItem] = [] { didSet { save() } }

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("plan.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([PlanItem].self, from: data) {
            items = list
        }
    }

    func add(_ obj: DeepSkyObject, minutes: Double = 60, fit: FrameFit? = nil) {
        var item = PlanItem(name: obj.id, raHours: obj.raHours, decDeg: obj.decDeg, minutes: minutes)
        item.lpFilter = [.nebula, .snr, .planetary].contains(obj.kind)
        if case .mosaic(let c, let r)? = fit { item.mosaicColumns = c; item.mosaicRows = r }
        items.append(item)
    }

    func resetStatuses() {
        for i in items.indices { items[i].status = .pending; items[i].stackedFrames = 0; items[i].doneSeconds = nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url) }
    }
}

/// Ejecuta un plan sin vigilancia: espera a la noche, apunta, enfoca, apila el tiempo pedido,
/// pasa al siguiente objeto, se pausa si se prevén nubes y aparca el telescopio al amanecer.
@MainActor
final class SessionRunner: ObservableObject {
    enum Phase: Equatable {
        case idle, waitingDark, waitingTarget, slewing, focusing, stacking, pausedClouds, darks, parking, finished, stopped
        var label: String {
            switch self {
            case .idle: return tr("En espera")
            case .waitingDark: return tr("Esperando a que oscurezca")
            case .waitingTarget: return tr("Esperando a que el objeto suba")
            case .slewing: return tr("Apuntando")
            case .focusing: return tr("Enfocando")
            case .stacking: return tr("Apilando")
            case .pausedClouds: return tr("En pausa por nubes")
            case .darks: return tr("Creando oscuros")
            case .parking: return tr("Aparcando")
            case .finished: return tr("Plan terminado")
            case .stopped: return tr("Detenido")
            }
        }
    }

    struct Options: Codable, Equatable {
        var waitForDark = true
        var pauseForClouds = true
        var stopAtDawn = true
    }

    /// Lo que se guarda para retomar el plan si la app o el ordenador se reinician.
    struct SavedState: Codable, Equatable {
        var startedAt: Date
        var options: Options
    }

    static let stateKey = "sessionRunnerState"

    /// Plan interrumpido que se puede retomar (como mucho 16 horas después de empezar).
    static func pendingResume(defaults: UserDefaults = .standard, now: Date = Date()) -> SavedState? {
        guard let data = defaults.data(forKey: stateKey),
              let st = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        return now.timeIntervalSince(st.startedAt) < 16 * 3600 ? st : nil
    }

    private func saveState(_ st: SavedState?) {
        if let st, let data = try? JSONEncoder().encode(st) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.stateKey) }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentItemID: UUID?
    @Published private(set) var currentPanel = ""
    @Published private(set) var remainingSeconds: Double = 0
    @Published private(set) var messages: [String] = []
    @Published var options = Options()

    var isRunning: Bool { task != nil }

    private var task: Task<Void, Never>?
    private var skipRequested = false
    private weak var client: SeestarClient?
    private weak var settings: AppSettings?
    private weak var plan: PlanStore?
    private var weather: [WeatherHour] = []
    private var weatherFetched = Date.distantPast

    func start(client: SeestarClient, settings: AppSettings, plan: PlanStore, resuming: SavedState? = nil) {
        guard task == nil else { return }
        self.client = client
        self.settings = settings
        self.plan = plan
        messages.removeAll()
        if let resuming { options = resuming.options }
        // Un objeto que estaba en marcha cuando se cerró la app vuelve a la cola (con su tiempo hecho).
        for i in plan.items.indices where plan.items[i].status == .running { plan.items[i].status = .pending }
        saveState(SavedState(startedAt: resuming?.startedAt ?? Date(), options: options))
        if resuming != nil {
            say(tr("Se retoma el plan interrumpido."))
            settings.notify("Astrolabio", tr("Se retoma el plan de la noche tras un reinicio."))
        }
        task = Task { [weak self] in
            await SeestarClient.$unattended.withValue(true) { await self?.run() }
            self?.task = nil
        }
    }

    func stop() {
        saveState(nil)
        task?.cancel()
        say(tr("Detenido por el usuario."))
        phase = .stopped
        if let client {
            Task { try? await client.stopStack(); try? await client.stopView() }
        }
    }

    func skip() {
        skipRequested = true
        say(tr("Saltando al siguiente objeto…"))
    }

    private func say(_ text: String) {
        let f = DateFormatter()
        f.timeStyle = .short
        messages.append("\(f.string(from: Date()))  \(text)")
        client?.addLog(tr("[Sesión] %@", "\(text)"))
    }

    private func lat() -> Double { settings?.latitude ?? 0 }
    private func lon() -> Double { settings?.longitude ?? 0 }

    private func isDarkNow() -> Bool { Astro.isDark(Date(), lat: lat(), lon: lon()) }

    private func refreshWeatherIfNeeded() async {
        guard Date().timeIntervalSince(weatherFetched) > 1800 else { return }
        if let w = try? await WeatherService.forecast(lat: lat(), lon: lon()) {
            weather = w
            weatherFetched = Date()
        }
    }

    private func cloudyNow() async -> Bool {
        guard options.pauseForClouds, let settings else { return false }
        await refreshWeatherIfNeeded()
        guard let c = WeatherService.cloudCover(at: Date(), in: weather) else { return false }
        return c > settings.maxCloudCover
    }

    private func sleep(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)); return true } catch { return false }
    }

    // MARK: Bucle principal

    private func run() async {
        guard let client, let settings, let plan else { return }
        say(tr("Comienza el plan con %@ objetos.", "\(plan.items.filter { $0.status == .pending }.count)"))

        if !client.isConnected {
            say(tr("El telescopio no está conectado."))
            phase = .stopped
            return
        }
        try? await client.setTimeAndLocation(latitude: settings.latitude, longitude: settings.longitude)
        if settings.dewHeaterPower > 0 { try? await client.setDewHeater(power: settings.dewHeaterPower) }

        if options.waitForDark && !isDarkNow() {
            phase = .waitingDark
            let n = Astro.night(for: Date(), lat: lat(), lon: lon())
            if let dusk = n.duskStart { say(tr("Esperando a la noche astronómica (%@).", "\(dusk.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Loc.shared.locale)))")) }
            while !isDarkNow() {
                if !(await sleep(60)) { return }
            }
        }

        var lastFocusDate = Date.distantPast
        for index in plan.items.indices {
            if Task.isCancelled { return }
            guard index < plan.items.count, plan.items[index].status == .pending else { continue }
            if options.stopAtDawn && !isDarkNow() && options.waitForDark {
                say(tr("Ha llegado el amanecer."))
                break
            }
            skipRequested = false
            let item = plan.items[index]
            currentItemID = item.id
            plan.items[index].status = .running

            let ok = await runItem(item, index: index, lastFocus: &lastFocusDate)
            guard index < plan.items.count else { continue }
            if Task.isCancelled { plan.items[index].status = .pending; return }
            plan.items[index].status = ok ? .done : (skipRequested ? .skipped : .failed)
            if !ok && !skipRequested { settings.notify("Astrolabio", tr("No se pudo completar %@.", "\(item.name)")) }
        }

        currentItemID = nil
        currentPanel = ""
        saveState(nil)
        try? await client.stopStack()
        if settings.darksAtEnd {
            phase = .darks
            say(tr("Creando los oscuros…"))
            say(await client.createDarksAndWait() ? tr("Oscuros creados.") : tr("No se pudieron crear los oscuros."))
        }
        switch settings.endAction {
        case .park:
            phase = .parking
            say(tr("Aparcando el telescopio."))
            try? await client.park()
        case .shutdown:
            phase = .parking
            say(tr("Aparcando y apagando el telescopio."))
            try? await client.park()
            try? await Task.sleep(for: .seconds(40))
            try? await client.shutdown()
        case .nothing:
            break
        }
        phase = .finished
        say(tr("Plan terminado."))
        settings.notify("Astrolabio", tr("El plan de la noche ha terminado."))
    }

    private func runItem(_ item: PlanItem, index: Int, lastFocus: inout Date) async -> Bool {
        guard let client, let settings, let plan else { return false }
        let fov = (w: settings.fovWidthDeg, h: settings.fovHeightDeg)
        let panels = item.isMosaic
            ? Planner.mosaicPanels(centerRA: item.raHours, centerDec: item.decDeg, columns: item.mosaicColumns,
                                   rows: item.mosaicRows, overlapPercent: item.overlapPercent, fov: fov)
            : [(label: "", ra: item.raHours, dec: item.decDeg)]
        let remainingByPanel = PlanProgress.remainingPerPanel(totalSeconds: item.minutes * 60, panels: panels.count,
                                                              done: item.doneSeconds ?? 0)
        var anyPanelDone = (item.doneSeconds ?? 0) > 0

        if let nb = item.notBefore, nb > Date() {
            phase = .waitingTarget
            say(tr("%@: esperando hasta %@.", "\(item.name)", "\(nb.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Loc.shared.locale)))"))
            while Date() < nb { if !(await sleep(30)) { return false }; if skipRequested { return false } }
        }

        for (panelIndex, panel) in panels.enumerated() {
            if Task.isCancelled || skipRequested { return anyPanelDone }
            if remainingByPanel[panelIndex] < 5 { continue }   // ya hecho antes del reinicio
            let label = panel.label.isEmpty ? item.name : "\(item.name)_\(panel.label)"
            currentPanel = panel.label

            // ¿Está el objeto lo bastante alto?
            let now = Astro.precessFromJ2000(raHours: panel.ra, decDeg: panel.dec, to: Date())
            var alt = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: Date(), lat: settings.latitude, lon: settings.longitude).alt
            if alt < settings.minAltitude {
                // Si va a subir en menos de 90 minutos, se espera; si no, se salta.
                let rising = (1...9).contains { k in
                    let tm = Date().addingTimeInterval(Double(k) * 600)
                    return Astro.altAz(raHours: now.ra, decDeg: now.dec, date: tm, lat: settings.latitude, lon: settings.longitude).alt >= settings.minAltitude
                        && Astro.isDark(tm, lat: settings.latitude, lon: settings.longitude)
                }
                if !rising {
                    say(tr("%@ está demasiado bajo (%@°). Se salta.", "\(label)", "\(Int(alt))"))
                    continue
                }
                phase = .waitingTarget
                say(tr("%@ está a %@°; esperando a que suba.", "\(label)", "\(Int(alt))"))
                while alt < settings.minAltitude {
                    if !(await sleep(60)) || skipRequested { return anyPanelDone }
                    alt = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: Date(), lat: settings.latitude, lon: settings.longitude).alt
                }
            }

            var remaining = remainingByPanel[panelIndex]
            var needGoto = true
            while remaining > 5 {
                if Task.isCancelled || skipRequested { return anyPanelDone }

                if await cloudyNow() {
                    phase = .pausedClouds
                    say(tr("Se prevén nubes. Pausa de 10 minutos."))
                    settings.notify("Astrolabio", tr("Sesión en pausa por nubes."))
                    try? await client.stopStack()
                    if !(await sleep(600)) { return anyPanelDone }
                    needGoto = true
                    continue
                }

                if needGoto {
                    phase = .slewing
                    say(tr("Apuntando a %@…", "\(label)"))
                    let target = Astro.precessFromJ2000(raHours: panel.ra, decDeg: panel.dec, to: Date())
                    var reached = false
                    for attempt in 1...3 {
                        do {
                            reached = try await client.gotoAndWait(name: label, raHours: target.ra, decDeg: target.dec,
                                                                   lpFilter: item.lpFilter)
                        } catch {
                            say(tr("Error en el GoTo: %@", "\(error.localizedDescription)"))
                        }
                        if reached || Task.isCancelled || skipRequested { break }
                        say(tr("GoTo fallido (intento %@). Reintento en 30 s.", "\(attempt)"))
                        if !(await sleep(30)) { return anyPanelDone }
                    }
                    if !reached { say(tr("No se pudo alcanzar %@.", "\(label)")); break }
                    needGoto = false

                    if item.autofocus && Date().timeIntervalSince(lastFocus) > 3600 {
                        phase = .focusing
                        say(tr("Enfoque automático…"))
                        if await client.autoFocusAndWait(tries: 2) { lastFocus = Date() }
                        else { say(tr("El enfoque falló; se sigue con el enfoque actual.")) }
                    }
                    try? await client.setLPFilter(item.lpFilter)
                    try? await client.setTargetName(label)
                    try? await client.setGain(settings.gain)
                    do {
                        try await client.startStack(restart: true)
                    } catch {
                        say(tr("No se pudo empezar a apilar: %@", "\(error.localizedDescription)"))
                        break
                    }
                    phase = .stacking
                    say(tr("Apilando %@ durante %@ min.", "\(label)", "\(Int(remaining / 60))"))
                }

                // Espera por tramos de 5 s comprobando amanecer, nubes y altura.
                let chunkEnd = Date().addingTimeInterval(min(remaining, 300))
                while Date() < chunkEnd {
                    if !(await sleep(5)) { try? await client.stopStack(); return anyPanelDone }
                    if skipRequested { try? await client.stopStack(); return anyPanelDone }
                    remaining -= 5
                    remainingSeconds = remaining
                    if index < plan.items.count {
                        plan.items[index].stackedFrames = client.stackedFrames
                        plan.items[index].doneSeconds = (plan.items[index].doneSeconds ?? 0) + 5
                    }
                }
                anyPanelDone = true
                if options.stopAtDawn && !isDarkNow() {
                    say(tr("Amanece: fin del apilado."))
                    try? await client.stopStack()
                    return true
                }
                let altNow = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: Date(), lat: settings.latitude, lon: settings.longitude).alt
                if altNow < settings.minAltitude - 5 {
                    say(tr("%@ ha bajado a %@°. Siguiente.", "\(label)", "\(Int(altNow))"))
                    break
                }
            }
            try? await client.stopStack()
            say(tr("Terminado %@.", "\(label)"))
        }
        return anyPanelDone
    }
}
