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
    /// Nombre del cometa: su posición se recalcula y el telescopio le sigue mientras apila.
    var comet: String?

    var isMosaic: Bool { mosaicColumns * mosaicRows > 1 }
}

/// Plan de una noche, guardado en Application Support/Astrolabio/plan.json.
@MainActor
final class PlanStore: ObservableObject {
    @Published var items: [PlanItem] = [] { didSet { save() } }

    private let url: URL

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("plan.json")
    }

    init(url: URL = PlanStore.defaultURL) {
        self.url = url
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
        case idle, waitingDark, waitingTarget, slewing, focusing, stacking, pausedClouds, pausedStorm, darks, parking, finished, stopped
        var label: String {
            switch self {
            case .idle: return tr("En espera")
            case .waitingDark: return tr("Esperando a que oscurezca")
            case .waitingTarget: return tr("Esperando a que el objeto suba")
            case .slewing: return tr("Apuntando")
            case .focusing: return tr("Enfocando")
            case .stacking: return tr("Apilando")
            case .pausedClouds: return tr("En pausa por nubes")
            case .pausedStorm: return tr("Recogido por mal tiempo")
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
    /// Dónde se guarda el estado para retomar el plan (otro en las pruebas).
    var stateDefaults: UserDefaults = .standard

    /// Plan interrumpido que se puede retomar (como mucho 16 horas después de empezar).
    static func pendingResume(defaults: UserDefaults = .standard, now: Date = Date()) -> SavedState? {
        guard let data = defaults.data(forKey: stateKey),
              let st = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        return now.timeIntervalSince(st.startedAt) < 16 * 3600 ? st : nil
    }

    private func saveState(_ st: SavedState?) {
        if let st, let data = try? JSONEncoder().encode(st) { stateDefaults.set(data, forKey: Self.stateKey) }
        else { stateDefaults.removeObject(forKey: Self.stateKey) }
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
    private var connectionLost = false
    private weak var client: SeestarClient?
    private weak var settings: AppSettings?
    private weak var plan: PlanStore?
    /// Vigilancia de enfoque, rocío y tormentas (la pone la app).
    weak var nightGuard: NightGuard?
    private var weather: [WeatherHour] = []
    private var weatherFetched = Date.distantPast

    func start(client: SeestarClient, settings: AppSettings, plan: PlanStore, resuming: SavedState? = nil) {
        guard task == nil else { return }
        self.client = client
        self.settings = settings
        self.plan = plan
        messages.removeAll()
        connectionLost = false
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
            if connectionLost {
                if index < plan.items.count { plan.items[index].status = .pending }
                saveState(nil)
                phase = .stopped
                return
            }
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

    /// Recoge el telescopio por mal tiempo y espera 30 minutos seguidos sin avisos.
    /// Devuelve false si se canceló el plan o llegó el amanecer.
    private func waitOutStorm(_ reason: String) async -> Bool {
        guard let client, let settings else { return false }
        phase = .pausedStorm
        say(tr("Mal tiempo: %@ Se recoge el telescopio.", reason))
        settings.notify("Astrolabio", tr("⛈ Telescopio recogido: %@", reason))
        try? await client.stopStack()
        try? await client.park()
        var calmSince: Date?
        while true {
            if !(await sleep(60)) { return false }
            if options.stopAtDawn && options.waitForDark && !isDarkNow() { return false }
            if nightGuard?.stormReason == nil {
                calmSince = calmSince ?? Date()
                if Date().timeIntervalSince(calmSince!) >= 1800 { break }
            } else {
                calmSince = nil
            }
        }
        say(tr("Ha pasado el mal tiempo: se reanuda el plan."))
        settings.notify("Astrolabio", tr("Ha pasado el mal tiempo: se reanuda el plan."))
        return true
    }

    /// Distancia que puede moverse un cometa antes de volver a apuntar (el campo mide unos 44′ × 77′).
    static let cometRetargetArcmin = 3.0
    /// Órbitas de los cometas (cambia en las pruebas).
    var cometOrbit: (String) -> CometOrbit? = { CometStore.shared.orbit(named: $0) }
    private var cometAim: (ra: Double, dec: Double)?
    /// Cada cuánto se revisan el amanecer, la altura, el cometa… durante el apilado (más corto en las pruebas).
    var chunkSeconds: Double = 300
    /// No se vuelve a apuntar al cometa si queda menos de esto en el objeto.
    var cometMinRemaining: Double = 60

    private func runItem(_ item: PlanItem, index: Int, lastFocus: inout Date) async -> Bool {
        guard let client, let settings, let plan else { return false }
        let fov = (w: settings.fovWidthDeg, h: settings.fovHeightDeg)
        // Cometa: posición de ahora (se mueve entre la planificación y la noche).
        var item = item
        if let name = item.comet, let orbit = cometOrbit(name) {
            let p = Comets.position(orbit, date: Date())
            item.raHours = p.raHours; item.decDeg = p.decDeg
            item.mosaicColumns = 1; item.mosaicRows = 1
        }
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

                if let storm = nightGuard?.stormReason {
                    if !(await waitOutStorm(storm)) { return anyPanelDone }
                    needGoto = true
                    continue
                }

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
                    // Si el telescopio se ha desconectado o reiniciado, se espera a que vuelva (hasta 10 min).
                    if !client.isConnected {
                        say(tr("Sin conexión con el telescopio: esperando a que vuelva…"))
                        guard await client.waitForConnection(timeout: 600) else {
                            say(tr("El telescopio no ha vuelto en 10 minutos. Se detiene el plan."))
                            settings.notify("Astrolabio", tr("El telescopio no responde: se ha detenido el plan."))
                            connectionLost = true
                            return anyPanelDone
                        }
                        say(tr("Conexión recuperada."))
                    }
                    phase = .slewing
                    say(tr("Apuntando a %@…", "\(label)"))
                    var j2000 = (ra: panel.ra, dec: panel.dec)
                    if let name = item.comet, let orbit = cometOrbit(name) {
                        let p = Comets.position(orbit, date: Date())
                        j2000 = (p.raHours, p.decDeg)
                        cometAim = j2000
                    }
                    let target = Astro.precessFromJ2000(raHours: j2000.ra, decDeg: j2000.dec, to: Date())
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

                    if item.autofocus && (Date().timeIntervalSince(lastFocus) > 3600 || nightGuard?.needsRefocus == true) {
                        phase = .focusing
                        say(tr("Enfoque automático…"))
                        if await client.autoFocusAndWait(tries: 2) { lastFocus = Date(); nightGuard?.refocused() }
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
                let epoch = client.connectionCount
                let chunkEnd = Date().addingTimeInterval(min(remaining, chunkSeconds))
                while Date() < chunkEnd {
                    if !(await sleep(5)) { try? await client.stopStack(); return anyPanelDone }
                    if skipRequested { try? await client.stopStack(); return anyPanelDone }
                    if nightGuard?.stormReason != nil { break }
                    // Conexión perdida: el tiempo no cuenta (el telescopio puede haber dejado de apilar).
                    if !client.isConnected || client.connectionCount != epoch { break }
                    remaining -= 5
                    remainingSeconds = remaining
                    if index < plan.items.count {
                        plan.items[index].stackedFrames = client.stackedFrames
                        plan.items[index].doneSeconds = (plan.items[index].doneSeconds ?? 0) + 5
                    }
                }
                anyPanelDone = true
                if nightGuard?.stormReason != nil { continue }   // se recoge al principio del bucle
                // Seguimiento del cometa: si se ha movido más de 3′ desde el último GoTo, se vuelve a apuntar.
                if let name = item.comet, let orbit = cometOrbit(name), let aim = cometAim {
                    let p = Comets.position(orbit, date: Date())
                    let moved = Astro.separation(ra1: aim.ra, dec1: aim.dec, ra2: p.raHours, dec2: p.decDeg) * 60
                    if moved > Self.cometRetargetArcmin && remaining > cometMinRemaining {
                        say(tr("%@ se ha movido %@′: se vuelve a apuntar.", label, String(format: "%.1f", moved)))
                        try? await client.stopStack()
                        needGoto = true
                        continue
                    }
                }
                if !client.isConnected || client.connectionCount != epoch {
                    say(tr("Se perdió la conexión durante el apilado: se volverá a apuntar y apilar."))
                    needGoto = true
                    continue
                }
                // Estrellas menos nítidas: se para, se enfoca y se sigue apilando el tiempo que queda.
                if settings.autoRefocus && item.autofocus && nightGuard?.needsRefocus == true && remaining > 300 {
                    say(tr("Las estrellas han perdido nitidez: se vuelve a enfocar."))
                    try? await client.stopStack()
                    phase = .focusing
                    if await client.autoFocusAndWait(tries: 2) { lastFocus = Date(); nightGuard?.refocused() }
                    try? await client.startStack(restart: true)
                    phase = .stacking
                }
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
