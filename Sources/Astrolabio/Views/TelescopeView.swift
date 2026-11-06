import SwiftUI

@MainActor
struct TelescopeView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var live: LiveViewModel

    @State private var discovered: [DiscoveredScope] = []
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        statusCard
                        equipmentCard
                    }
                    VStack(spacing: 16) {
                        GotoCard()
                        StackCard()
                    }
                    VStack(spacing: 16) {
                        JoystickCard()
                        FocusCard()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(tr("Telescopio"))
    }

    private var connectionCard: some View {
        Card(title: tr("Conexión"), systemImage: "wifi") {
            HStack {
                TextField(tr("IP del telescopio"), text: $settings.telescopeHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if client.isConnected {
                    Button(tr("Desconectar")) {
                        live.disconnect()
                        client.disconnect()
                    }
                } else {
                    Button(tr("Conectar")) {
                        Task {
                            await client.connect(to: settings.telescopeHost)
                            if client.isConnected { live.connect(host: settings.telescopeHost) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(client.status == .connecting)
                }
                Button {
                    scanning = true
                    Task {
                        discovered = await SeestarDiscovery.scan()
                        scanning = false
                        if discovered.count == 1 { settings.telescopeHost = discovered[0].ip }
                    }
                } label: {
                    if scanning { ProgressView().controlSize(.small) } else { Text(tr("Buscar en la red")) }
                }
                .disabled(scanning)
                Toggle(tr("Conectar al abrir"), isOn: $settings.autoConnect).toggleStyle(.checkbox)
                Spacer()
                Text(client.status.label).foregroundStyle(.secondary)
            }
            if !discovered.isEmpty {
                HStack {
                    Text(tr("Encontrados:")).foregroundStyle(.secondary)
                    ForEach(discovered) { scope in
                        Button("\(scope.name) (\(scope.ip))") { settings.telescopeHost = scope.ip }
                            .buttonStyle(.link)
                    }
                }
            } else if !scanning && discovered.isEmpty && client.status != .connected {
                Text(tr("El Seestar debe estar en modo estación (unido a tu wifi). Actívalo una vez desde la app oficial."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if client.isConnected && !client.isAuthenticated {
                Label(client.authMessage.isEmpty ? tr("Sin autenticar.") : client.authMessage,
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var statusCard: some View {
        Card(title: tr("Estado"), systemImage: "gauge") {
            InfoRow(label: tr("Nombre"), value: client.deviceName.isEmpty ? "—" : client.deviceName)
            InfoRow(label: tr("Firmware"), value: client.firmwareString.isEmpty ? (client.firmwareVersion > 0 ? "\(client.firmwareVersion)" : "—") : client.firmwareString)
            InfoRow(label: tr("Autenticado"), value: client.isAuthenticated ? tr("Sí") : tr("No"))
            InfoRow(label: tr("Batería"), value: client.battery.map { "\($0) %" } ?? "—")
            InfoRow(label: tr("Carga"), value: client.chargerStatus ?? "—")
            InfoRow(label: tr("Temperatura"), value: client.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
            InfoRow(label: tr("Espacio libre"), value: client.freeStorageMB.map { tr("%.1f GB", $0 / 1024) } ?? "—")
            InfoRow(label: tr("Montura"), value: client.isEQMode ? tr("Ecuatorial") : tr("Altacimutal"))
            InfoRow(label: tr("AR"), value: client.ra.map(Astro.formatRA) ?? "—")
            InfoRow(label: tr("Dec"), value: client.dec.map(Astro.formatDec) ?? "—")
            if let ra = client.ra, let dec = client.dec {
                let aa = Astro.altAz(raHours: ra, decDeg: dec, date: Date(), lat: settings.latitude, lon: settings.longitude)
                InfoRow(label: tr("Altura / acimut"), value: String(format: "%.1f° / %.1f°", aa.alt, aa.az))
            }
            InfoRow(label: tr("Fotogramas apilados"), value: tr("%@ (descartados %@)", "\(client.stackedFrames)", "\(client.droppedFrames)"))
            Button(tr("Actualizar")) { Task { await client.refreshDeviceState() } }.disabled(!client.isConnected)
        }
        .frame(minWidth: 260)
    }

    private var equipmentCard: some View {
        Card(title: tr("Equipo"), systemImage: "wrench.and.screwdriver") {
            HStack {
                Button(tr("Abrir brazo")) { ActionRunner.run(client, tr("Abrir brazo")) { try await client.openArm() } }
                Button(tr("Aparcar")) { ActionRunner.run(client, tr("Aparcar")) { try await client.park() } }
            }
            Button(tr("Enviar hora y ubicación del Mac")) {
                ActionRunner.run(client, tr("Hora y ubicación")) {
                    try await client.setTimeAndLocation(latitude: settings.latitude, longitude: settings.longitude)
                }
            }
            HStack {
                Text(tr("Calentador")).fixedSize()
                Slider(value: Binding(get: { Double(settings.dewHeaterPower) },
                                      set: { settings.dewHeaterPower = Int($0) }), in: 0...100, step: 10)
                Text("\(settings.dewHeaterPower) %").monospacedDigit().frame(width: 44)
                Button(tr("Aplicar")) {
                    ActionRunner.run(client, tr("Calentador")) { try await client.setDewHeater(power: settings.dewHeaterPower) }
                }
            }
            Button(tr("Tomar oscuros")) { ActionRunner.run(client, tr("Oscuros")) { try await client.createDarks() } }
            HStack {
                Button(tr("Alineación polar")) { ActionRunner.run(client, tr("Alineación polar")) { try await client.startPolarAlign() } }
                Button(tr("Parar")) { ActionRunner.run(client, tr("Parar alineación polar")) { try await client.stopPolarAlign() } }
            }
            Button(tr("Apagar el telescopio…"), role: .destructive) {
                let alert = NSAlert()
                alert.messageText = tr("¿Apagar el Seestar?")
                alert.informativeText = tr("Tendrás que encenderlo a mano con el botón.")
                alert.addButton(withTitle: tr("Apagar"))
                alert.addButton(withTitle: tr("Cancelar"))
                if alert.runModal() == .alertFirstButtonReturn {
                    ActionRunner.run(client, tr("Apagar")) { try await client.shutdown() }
                }
            }
        }
        .disabled(!client.isConnected)
        .frame(minWidth: 260)
    }
}

// MARK: - GoTo

@MainActor
struct GotoCard: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings

    @State private var query = ""
    @State private var raText = ""
    @State private var decText = ""
    @State private var targetName = ""
    @State private var lp = false
    @State private var stackAfter = true
    @State private var resolving = false
    @State private var message = ""
    @State private var catalogObject: DeepSkyObject?
    @State private var confirming = false

    var body: some View {
        Card(title: tr("Ir a un objeto"), systemImage: "location.north.line") {
            HStack {
                TextField(tr("M42, NGC 7000, Andrómeda…"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(lookup)
                Button(action: lookup) {
                    if resolving { ProgressView().controlSize(.small) } else { Text(tr("Buscar")) }
                }
            }
            HStack {
                TextField(tr("AR (h m s)"), text: $raText).textFieldStyle(.roundedBorder)
                TextField(tr("Dec (° ′ ″)"), text: $decText).textFieldStyle(.roundedBorder)
            }
            TextField(tr("Nombre para las fotos"), text: $targetName).textFieldStyle(.roundedBorder)
            Toggle(tr("Filtro antipolución (LP)"), isOn: $lp)
            Toggle(tr("Empezar a apilar al llegar"), isOn: $stackAfter)
            if let ra = Astro.parseRA(raText), let dec = Astro.parseDec(decText) {
                let now = Astro.precessFromJ2000(raHours: ra, decDeg: dec, to: Date())
                let aa = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: Date(), lat: settings.latitude, lon: settings.longitude)
                Text(tr("Ahora a %.0f° de altura, acimut %.0f°", aa.alt, aa.az))
                    .font(.caption).foregroundStyle(aa.alt < settings.minAltitude ? Color.orange : Color.secondary)
            }
            if let ra = Astro.parseRA(raText), let dec = Astro.parseDec(decText) {
                SkyImage(raHours: ra, decDeg: dec, sizeArcmin: catalogObject?.sizeArcmin ?? 0,
                         fov: (settings.fovWidthDeg, settings.fovHeightDeg))
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                    .id("\(raText)|\(decText)")
            }
            if let o = catalogObject, Astro.parseRA(raText) != nil {
                HStack {
                    AdviceSummary(object: o)
                    Button(tr("Ir y apilar…")) { confirming = true }.disabled(!client.isConnected)
                }
            }
            HStack {
                Button(tr("GoTo")) { goto() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!client.isConnected || Astro.parseRA(raText) == nil || Astro.parseDec(decText) == nil)
                Button(tr("Parar")) { ActionRunner.run(client, tr("Parar GoTo")) { try await client.stopGoto() } }
                    .disabled(!client.isConnected)
                Button(tr("Sincronizar aquí")) { syncHere() }
                    .help(tr("Indica al telescopio que está apuntando a estas coordenadas."))
                    .disabled(!client.isConnected || Astro.parseRA(raText) == nil || Astro.parseDec(decText) == nil)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text(tr("Las coordenadas son J2000; se pasan a la fecha antes de enviarlas."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(minWidth: 300)
        .sheet(isPresented: $confirming) {
            if let o = catalogObject { GotoConfirmSheet(object: o) { message = $0 }.nightMode() }
        }
    }

    private func lookup() {
        catalogObject = nil
        if let obj = Catalog.find(query) {
            catalogObject = obj
            apply(name: obj.id, ra: obj.raHours, dec: obj.decDeg)
            lp = [.nebula, .snr, .planetary].contains(obj.kind)
            message = obj.displayName
            return
        }
        resolving = true
        message = tr("Buscando en SIMBAD…")
        let q = query
        Task {
            defer { resolving = false }
            do {
                if let r = try await NameResolver.resolve(q) {
                    apply(name: q, ra: r.ra, dec: r.dec)
                    message = tr("Encontrado en SIMBAD.")
                } else {
                    message = tr("No se encontró %@.", "\(q)")
                }
            } catch {
                message = tr("Sin conexión a internet para buscar %@.", "\(q)")
            }
        }
    }

    private func apply(name: String, ra: Double, dec: Double) {
        raText = Astro.formatRA(ra)
        decText = Astro.formatDec(dec)
        targetName = name
    }

    private func syncHere() {
        guard let ra = Astro.parseRA(raText), let dec = Astro.parseDec(decText) else { return }
        let now = Astro.precessFromJ2000(raHours: ra, decDeg: dec, to: Date())
        ActionRunner.run(client, tr("Sincronizar")) { try await client.sync(raHours: now.ra, decDeg: now.dec) }
    }

    private func goto() {
        guard let ra = Astro.parseRA(raText), let dec = Astro.parseDec(decText) else { return }
        let now = Astro.precessFromJ2000(raHours: ra, decDeg: dec, to: Date())
        let name = targetName.isEmpty ? "Objetivo" : targetName
        let lpOn = lp, stack = stackAfter
        message = tr("Apuntando a %@…", "\(name)")
        Task {
            do {
                let ok = try await client.gotoAndWait(name: name, raHours: now.ra, decDeg: now.dec, lpFilter: lpOn)
                if ok {
                    message = tr("Llegó a %@.", "\(name)")
                    if stack {
                        try await client.setTargetName(name)
                        try await client.startStack()
                        message = tr("Apilando %@.", "\(name)")
                    }
                } else {
                    message = tr("El GoTo no terminó bien (¿nubes o poca altura?).")
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Apilado

@MainActor
struct StackCard: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Card(title: tr("Apilado"), systemImage: "square.stack.3d.up") {
            Picker(tr("Exposición"), selection: $settings.exposureMs) {
                Text("10 s").tag(10_000)
                Text("20 s").tag(20_000)
                Text("30 s").tag(30_000)
            }
            .pickerStyle(.segmented)
            HStack {
                Text(tr("Ganancia"))
                Slider(value: Binding(get: { Double(settings.gain) }, set: { settings.gain = Int($0) }),
                       in: Double(client.gainRange?.lowerBound ?? 0)...Double(max(client.gainRange?.upperBound ?? 120, settings.gain)), step: 5)
                Text("\(settings.gain)").monospacedDigit().frame(width: 34)
            }
            Toggle(tr("Dithering"), isOn: $settings.ditherEnabled)
            if settings.ditherEnabled {
                HStack {
                    Stepper(tr("%@ px", "\(settings.ditherPixels)"), value: $settings.ditherPixels, in: 10...300, step: 10)
                    Stepper(tr("cada %@", "\(settings.ditherInterval)"), value: $settings.ditherInterval, in: 1...50)
                }
                .font(.callout)
            }
            Toggle(tr("Enfoque automático antes de apilar"), isOn: $settings.autoFocusBeforeStack)
            HStack {
                Button(tr("Aplicar")) {
                    let s = settings
                    ActionRunner.run(client, tr("Ajustes de apilado")) {
                        try await client.setExposure(ms: s.exposureMs)
                        try await client.setGain(s.gain)
                        try await client.setDither(enabled: s.ditherEnabled, pixels: s.ditherPixels, interval: s.ditherInterval)
                        try await client.setAutoFocusBeforeStack(s.autoFocusBeforeStack)
                    }
                }
                Button(tr("Empezar")) { ActionRunner.run(client, tr("Empezar a apilar")) { try await client.startStack() } }
                    .buttonStyle(.borderedProminent)
                Button(tr("Parar")) { ActionRunner.run(client, tr("Parar el apilado")) { try await client.stopStack() } }
            }
            Text(tr("%@ fotogramas · %@ min", "\(client.stackedFrames)", "\(client.stackedFrames * (client.stackExposureMs ?? settings.exposureMs) / 60_000)")
                 + (client.viewTarget.map { " · \($0)" } ?? ""))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .disabled(!client.isConnected)
        // Los controles muestran lo que tiene configurado el telescopio.
        .onChange(of: client.stackExposureMs) { _, v in if let v, [10_000, 20_000, 30_000].contains(v) { settings.exposureMs = v } }
        .onChange(of: client.currentGain) { _, v in if let v { settings.gain = v } }
        .onChange(of: client.autoFocusBeforeStackSetting) { _, v in if let v { settings.autoFocusBeforeStack = v } }
        .onChange(of: client.ditherSetting?.pixels) { _, _ in
            if let d = client.ditherSetting {
                settings.ditherEnabled = d.enabled; settings.ditherPixels = d.pixels; settings.ditherInterval = d.interval
            }
        }
        .frame(minWidth: 300)
    }
}

// MARK: - Mando

@MainActor
struct JoystickCard: View {
    @EnvironmentObject var client: SeestarClient
    @State private var speed = 2000.0

    var body: some View {
        Card(title: tr("Mover"), systemImage: "dpad") {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 44, height: 44)
                    arrow("arrow.up", angle: 90)
                    Color.clear.frame(width: 44, height: 44)
                }
                GridRow {
                    arrow("arrow.left", angle: 180)
                    Button { ActionRunner.run(client, tr("Parar")) { try await client.stopMove() } } label: {
                        Image(systemName: "stop.fill").frame(width: 36, height: 36)
                    }
                    arrow("arrow.right", angle: 0)
                }
                GridRow {
                    Color.clear.frame(width: 44, height: 44)
                    arrow("arrow.down", angle: 270)
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            HStack {
                Text(tr("Velocidad"))
                Slider(value: $speed, in: 200...5000, step: 100)
            }
            Text(tr("Cada pulsación mueve el telescopio un segundo.")).font(.caption2).foregroundStyle(.tertiary)
        }
        .disabled(!client.isConnected)
        .frame(minWidth: 220)
    }

    private func arrow(_ icon: String, angle: Int) -> some View {
        Button {
            let s = Int(speed)
            ActionRunner.run(client, tr("Mover")) { try await client.move(angle: angle, speed: s, seconds: 1) }
        } label: {
            Image(systemName: icon).frame(width: 36, height: 36)
        }
    }
}

// MARK: - Enfoque

@MainActor
struct FocusCard: View {
    @EnvironmentObject var client: SeestarClient
    @State private var position: Int?
    @State private var busy = false

    var body: some View {
        Card(title: tr("Enfoque"), systemImage: "scope") {
            Button(tr("Enfoque automático")) {
                busy = true
                Task {
                    let ok = await client.autoFocusAndWait(tries: 1)
                    client.addLog(ok ? tr("Enfoque automático completado.") : tr("El enfoque automático falló."), ok ? .info : .warning)
                    position = try? await client.focuserPositionNow()
                    busy = false
                }
            }
            .disabled(busy)
            HStack {
                ForEach([-100, -20, 20, 100], id: \.self) { step in
                    Button(step > 0 ? "+\(step)" : "\(step)") { nudge(step) }
                }
            }
            Text(tr("Posición: %@", "\(position.map(String.init) ?? client.focuserPosition.map(String.init) ?? "—")"))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .disabled(!client.isConnected)
        .frame(minWidth: 220)
    }

    private func nudge(_ step: Int) {
        Task {
            do {
                let current = try await client.focuserPositionNow() ?? client.focuserPosition ?? 0
                try await client.moveFocuser(to: current + step)
                position = try await client.focuserPositionNow()
            } catch {
                client.addLog(tr("Enfoque: %@", "\(error.localizedDescription)"), .error)
            }
        }
    }
}
