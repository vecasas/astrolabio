import SwiftUI
import Charts
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Tiempo

@MainActor
struct WeatherView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var hours: [WeatherHour] = []
    @State private var error = ""
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Previsión para %@", "\(settings.siteName)")).font(.title3.bold())
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button(tr("Actualizar")) { Task { await load() } }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Card(title: tr("Nubes (%)"), systemImage: "cloud") {
                    Chart(hours) { h in
                        AreaMark(x: .value("Hora", h.time), y: .value("Nubes", h.cloudCover))
                            .foregroundStyle(Color.gray.opacity(0.5))
                        LineMark(x: .value("Hora", h.time), y: .value("Bajas", h.lowClouds))
                            .foregroundStyle(Color.blue)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 180)
                    darkBands
                }
                Card(title: tr("Temperatura y punto de rocío (°C)"), systemImage: "thermometer") {
                    Chart {
                        ForEach(hours) { h in
                            LineMark(x: .value("Hora", h.time), y: .value("°C", h.temperature))
                                .foregroundStyle(by: .value("Serie", tr("Temperatura")))
                            LineMark(x: .value("Hora", h.time), y: .value("°C", h.dewPoint))
                                .foregroundStyle(by: .value("Serie", tr("Punto de rocío")))
                        }
                    }
                    .frame(height: 160)
                    Text(tr("Si la temperatura se acerca al punto de rocío, enciende el calentador para que no se empañe."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: tr("Humedad (%) y viento (km/h)"), systemImage: "wind") {
                    Chart {
                        ForEach(hours) { h in
                            LineMark(x: .value("Hora", h.time), y: .value("Valor", h.humidity))
                                .foregroundStyle(by: .value("Serie", tr("Humedad")))
                            LineMark(x: .value("Hora", h.time), y: .value("Valor", h.wind))
                                .foregroundStyle(by: .value("Serie", tr("Viento")))
                        }
                    }
                    .frame(height: 160)
                }
                Text(tr("Datos de Open-Meteo.")).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle(tr("Tiempo"))
        .task { await load() }
    }

    private var darkBands: some View {
        let n = Astro.night(for: Date(), lat: settings.latitude, lon: settings.longitude)
        return Text(tr("Noche cerrada hoy: %@ – %@", "\(n.duskStart?.shortTime ?? "—")", "\(n.dawnEnd?.shortTime ?? "—")"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let all = try await WeatherService.forecast(lat: settings.latitude, lon: settings.longitude)
            let from = Date().addingTimeInterval(-3600)
            hours = all.filter { $0.time >= from }.prefix(48).map { $0 }
            error = ""
        } catch {
            self.error = tr("No se pudo descargar la previsión: %@", "\(error.localizedDescription)")
        }
    }
}

// MARK: - Registro y diagnóstico

@MainActor
struct LogView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @State private var checks: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle(tr("Mostrar tráfico de red"), isOn: $client.logTraffic).toggleStyle(.checkbox)
                Spacer()
                Button(tr("Diagnóstico")) { Task { await diagnose() } }
                Button(tr("Copiar")) {
                    let text = client.log.map { "\($0.date.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: Loc.shared.locale))) \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(tr("Borrar")) { client.log.removeAll() }
            }
            .padding(10)
            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(checks, id: \.self) { Text($0).font(.callout) }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                List(client.log) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: Loc.shared.locale)))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Text(entry.text).foregroundStyle(color(entry.level)).textSelection(.enabled)
                    }
                    .font(.caption.monospaced())
                    .id(entry.id)
                }
                .onChange(of: client.log.count) { _, _ in
                    if let last = client.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(tr("Registro"))
    }

    private func color(_ l: LogEntry.Level) -> Color {
        switch l {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .traffic: return .secondary
        }
    }

    /// Repasa los problemas habituales: red, autenticación, firmware, batería y espacio.
    private func diagnose() async {
        var out: [String] = []
        out.append(client.isConnected ? tr("✅ Conectado a %@.", "\(client.host)") : tr("❌ Sin conexión. Comprueba que el Mac y el Seestar están en la misma wifi y que la IP es correcta."))
        if settings.pemPath.isEmpty {
            out.append(tr("⚠️ No hay clave PEM. Con firmware reciente el telescopio ignorará las órdenes."))
        } else if settings.makeSigner() == nil {
            out.append(tr("❌ La clave PEM no se puede leer: %@", "\(settings.pemPath)"))
        } else {
            out.append(client.isAuthenticated ? tr("✅ Autenticado.") : tr("⚠️ Clave cargada pero sin autenticar: %@", "\(client.authMessage)"))
        }
        if client.firmwareVersion > 0 { out.append(tr("ℹ️ Firmware %@ (%@).", "\(client.firmwareString)", "\(client.firmwareVersion)")) }
        if let b = client.battery { out.append(b < 20 ? tr("⚠️ Batería baja (%@ %%).", "\(b)") : tr("✅ Batería %@ %%.", "\(b)")) }
        if let f = client.freeStorageMB { out.append(f < 2000 ? tr("⚠️ Queda poco espacio (%@ MB).", "\(Int(f))") : tr("✅ Espacio libre suficiente.")) }
        if client.isConnected {
            let t0 = Date()
            if (try? await client.send("test_connection", timeout: 5)) != nil {
                out.append(tr("✅ Responde a las órdenes (%.0f ms).", Date().timeIntervalSince(t0) * 1000))
            } else {
                out.append(tr("❌ No responde a las órdenes. Si no estás autenticado, revisa la clave PEM."))
            }
        }
        checks = out
    }
}

// MARK: - Ajustes

@MainActor
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient
    @State private var testMessage = ""

    var body: some View {
        Form {
            SwiftUI.Section(tr("Idioma")) {
                LanguagePicker()
            }
            SwiftUI.Section(tr("Acerca de")) {
                LabeledContent(tr("Versión"), value: "\(AppInfo.bundleVersion) (\(AppInfo.build))")
                LabeledContent(tr("Autor"), value: AppInfo.author)
                LabeledContent(tr("Contacto")) { Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!) }
                AboutButton()
            }
            SwiftUI.Section(tr("Lugar de observación")) {
                TextField(tr("Nombre"), text: $settings.siteName)
                TextField(tr("Latitud (°, norte positivo)"), value: $settings.latitude, format: .number.precision(.fractionLength(4)))
                TextField(tr("Longitud (°, este positivo)"), value: $settings.longitude, format: .number.precision(.fractionLength(4)))
                Stepper(tr("Altura mínima: %@°", "\(Int(settings.minAltitude))"), value: $settings.minAltitude, in: 10...60, step: 5)
                Stepper(tr("Nubes máximas: %@ %%", "\(Int(settings.maxCloudCover))"), value: $settings.maxCloudCover, in: 10...100, step: 10)
            }
            SwiftUI.Section(tr("Telescopio")) {
                TextField(tr("IP"), text: $settings.telescopeHost)
                HStack {
                    TextField(tr("Clave PEM"), text: $settings.pemPath)
                    Button(tr("Elegir…")) { choosePEM() }
                }
                Text(tr("El firmware reciente del Seestar exige que el cliente firme un reto con una clave privada. Indica aquí el archivo .pem que uses con seestar_alp (opción interop_pem)."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(tr("Campo de visión (°)"))
                    Spacer()
                    TextField("", value: $settings.fovWidthDeg, format: .number, prompt: Text("ancho"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("×")
                    TextField("", value: $settings.fovHeightDeg, format: .number, prompt: Text("alto"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                }
                Text(tr("Seestar S50: 0,73° × 1,29°.")).font(.caption2).foregroundStyle(.tertiary)
            }
            SwiftUI.Section(tr("Avisos al móvil")) {
                PhoneAlertsSettings(testMessage: $testMessage)
            }
            SwiftUI.Section(tr("Modo nocturno")) {
                Toggle(tr("Activado"), isOn: $settings.nightMode)
                Toggle(tr("Activarlo solo al anochecer (Sol por debajo de −6°)"), isOn: $settings.nightModeAuto)
                LabeledSlider(title: tr("Brillo"), value: $settings.nightBrightness, range: 0.3...1)
                Text(tr("Todo pasa a rojo tenue para no perder la adaptación a la oscuridad. Atajo: ⌃⌘N. Baja también el brillo de la pantalla del Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section(tr("Archivos")) {
                HStack {
                    TextField(tr("Carpeta de imágenes"), text: $settings.saveFolder)
                    Button(tr("Elegir…")) { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func choosePEM() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data, .data]
        if panel.runModal() == .OK, let url = panel.url {
            settings.pemPath = url.path
            if (try? SeestarSigner(pemURL: url)) == nil {
                testMessage = tr("Ese archivo no parece una clave RSA privada.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url.path }
    }
}

/// Explicación y configuración de los avisos al móvil con ntfy.
@MainActor
struct PhoneAlertsSettings: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var testMessage: String
    @State private var showAdvanced = false

    private var topic: String { settings.ntfyTopic.trimmingCharacters(in: .whitespaces) }
    private var subscribeURL: String {
        settings.ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + topic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(tr("Astrolabio puede avisarte en el móvil de lo que pasa durante la noche, aunque estés lejos del Mac. **No hace falta número de teléfono ni crear una cuenta**: se usa ntfy, una app gratuita para iPhone y Android.")))
                .font(.callout)
            Text(tr("Cómo funciona: eliges un «tema», que es como el nombre de un canal privado. Astrolabio publica los avisos en ese tema y la app ntfy del móvil, suscrita a él, te los muestra como notificaciones."))
                .font(.callout).foregroundStyle(.secondary)

            Text(tr("Qué se avisa")).font(.headline).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Label(tr("El plan de la sesión automática ha terminado."), systemImage: "checkmark.circle")
                Label(tr("La sesión se ha puesto en pausa porque se prevén nubes."), systemImage: "cloud")
                Label(tr("Un objeto del plan no se pudo completar (GoTo o enfoque fallidos)."), systemImage: "exclamationmark.triangle")
                Label(tr("Un apilado ha terminado al cumplir la duración elegida en «Antes de ir»."), systemImage: "timer")
            }
            .font(.callout)
            Text(tr("Los avisos también salen siempre como notificación en el Mac. Solo contienen el nombre del objeto y lo ocurrido."))
                .font(.caption).foregroundStyle(.secondary)

            Text(tr("Configurarlo en 3 pasos")).font(.headline).padding(.top, 4)
            Text(LocalizedStringKey(tr("1. Instala **ntfy** en el móvil (App Store o Google Play)."))).font(.callout)
            Text(tr("2. Elige un tema difícil de adivinar (quien lo conozca podría leer los avisos):")).font(.callout)
            HStack {
                TextField("", text: $settings.ntfyTopic, prompt: Text(tr("p. ej. astrolabio-7k2m-q9xd")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button(tr("Generar uno")) { settings.ntfyTopic = Self.randomTopic() }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(topic, forType: .string)
                    testMessage = tr("Tema copiado.")
                } label: { Image(systemName: "doc.on.doc") }
                    .help(tr("Copiar el tema"))
                    .disabled(topic.isEmpty)
            }
            Text(tr("3. En la app ntfy pulsa «+» (suscribirse a un tema) y escribe ese mismo tema, o escanea este código con la cámara del móvil:"))
                .font(.callout)
            if !topic.isEmpty {
                HStack(alignment: .center, spacing: 14) {
                    if let qr = Self.qrCode(subscribeURL) {
                        Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                            .frame(width: 120, height: 120)
                            .padding(6).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(subscribeURL).font(.caption.monospaced()).textSelection(.enabled)
                        Button(tr("Enviar un aviso de prueba")) {
                            settings.notify("Astrolabio", tr("Prueba de aviso desde el Mac. ¡Funciona!"))
                            testMessage = tr("Enviado. Debería llegarte al móvil en unos segundos.")
                        }
                        .buttonStyle(.borderedProminent)
                        if !testMessage.isEmpty { Text(testMessage).font(.caption).foregroundStyle(Theme.accentSoft) }
                    }
                }
            } else {
                Text(tr("Escribe o genera un tema para ver el código y probarlo.")).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(tr("Avanzado"), isExpanded: $showAdvanced) {
                TextField(tr("Servidor ntfy"), text: $settings.ntfyServer)
                Text(tr("Por defecto se usa el servidor público gratuito ntfy.sh. Si tienes tu propio servidor ntfy, pon aquí su dirección."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    static func randomTopic() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        func block() -> String { String((0..<4).map { _ in chars.randomElement()! }) }
        return "astrolabio-\(block())-\(block())-\(block())"
    }

    static func qrCode(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

/// Selector del idioma de la interfaz (el cambio se aplica al momento).
@MainActor
struct LanguagePicker: View {
    @ObservedObject private var loc = Loc.shared

    var body: some View {
        Picker(tr("Idioma de la interfaz"), selection: Binding(get: { loc.language }, set: { loc.setLanguage($0) })) {
            ForEach(AppLanguage.allCases) { l in Text(l.nativeName).tag(l) }
        }
        .pickerStyle(.menu)
    }
}
