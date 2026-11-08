import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

extension CompanionBridge {
    /// Puente real: estado del telescopio, de la sesión y de la vista en directo. Nunca expone ajustes ni la clave.
    @MainActor
    static func live(client: SeestarClient, runner: SessionRunner, plan: PlanStore, live: LiveViewModel) -> CompanionBridge {
        var cache: (gen: ObjectIdentifier?, at: Date, data: Data?) = (nil, .distantPast, nil)
        return CompanionBridge(
            status: {
                var s: [String: Any] = ["connected": client.isConnected, "running": runner.isRunning,
                                        "frames": client.stackedFrames, "time": Date().timeIntervalSince1970]
                if let b = client.battery { s["battery"] = b }
                if let c = client.chargerStatus { s["charging"] = c.lowercased().contains("charg") && !c.lowercased().contains("not") }
                if let e = client.stackExposureMs { s["exposure"] = Double(e) / 1000 }
                let current = plan.items.first { $0.id == runner.currentItemID }
                s["target"] = current?.name ?? client.viewTarget ?? ""
                s["phase"] = runner.isRunning ? runner.phase.label : (client.isConnected ? (client.stackState ?? client.currentView) : "")
                if !plan.items.isEmpty {
                    var p: [String: Any] = ["total": plan.items.count,
                                            "done": plan.items.filter { $0.status == .done || $0.status == .skipped || $0.status == .failed }.count]
                    if runner.isRunning { p["remainingMin"] = Int(runner.remainingSeconds / 60) }
                    s["plan"] = p
                }
                s["messages"] = Array(runner.messages.suffix(5).reversed())
                return s
            },
            jpeg: {
                // Se recodifica como mucho cada 10 s.
                guard let img = live.image else { return nil }
                let id = ObjectIdentifier(img)
                if cache.gen == id || Date().timeIntervalSince(cache.at) < 10, let d = cache.data { return d }
                cache = (id, Date(), CompanionServer.jpeg(img))
                return cache.data
            },
            stop: {
                if runner.isRunning { runner.stop(); return tr("Sesión automática detenida.") }
                guard client.isConnected else { return tr("El telescopio no está conectado.") }
                do { try await client.stopStack(); return tr("Apilado detenido.") } catch { return error.localizedDescription }
            },
            skip: {
                guard runner.isRunning else { return tr("No hay ninguna sesión automática en marcha.") }
                runner.skip()
                return tr("Saltando al siguiente objeto…")
            },
            park: {
                if runner.isRunning { runner.stop() }
                guard client.isConnected else { return tr("El telescopio no está conectado.") }
                do { try? await client.stopStack(); try await client.park(); return tr("Aparcando el telescopio.") }
                catch { return error.localizedDescription }
            },
            strings: { CompanionRouter.pageStrings() },
            language: { Loc.shared.language.rawValue })
    }
}

enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

@MainActor
struct PhoneView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var server = CompanionServer.shared
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("Mira cómo va la noche y para, salta o aparca el telescopio desde el móvil, sin instalar nada: basta el navegador. Solo funciona en tu wifi; nada sale a internet."))
                    .foregroundStyle(.secondary)
                Card(title: tr("Servidor para el móvil"), systemImage: "iphone.radiowaves.left.and.right") {
                    Toggle(tr("Permitir el control desde el móvil"), isOn: $settings.companionEnabled)
                    if let url = server.url, server.isRunning {
                        HStack { Text(tr("Dirección:")); Text(url).monospaced().textSelection(.enabled) }
                    }
                    if let e = server.error { Text(e).foregroundStyle(Theme.warn) }
                    Text(tr("Apagado de serie. Al activarlo, macOS puede pedir permiso para la red local o para aceptar conexiones entrantes: acéptalo para que el móvil llegue al Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if server.isRunning {
                    Card(title: tr("Emparejar un móvil"), systemImage: "qrcode") {
                        if let p = server.pairing, let link = server.pairingURL, p.expires > tick {
                            HStack(alignment: .top, spacing: 24) {
                                if let qr = QRCode.image(link) {
                                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 220, height: 220)
                                        .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(tr("1. Escanea el código con la cámara del móvil (conectado a la misma wifi)."))
                                    Text(tr("2. Escribe este código en el móvil:"))
                                    Text(p.code.prefix(3) + " " + p.code.suffix(3)).font(.system(size: 40, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Theme.accentSoft)
                                    Text(tr("Caduca en %d s. Sirve para un solo móvil.", Int(p.expires.timeIntervalSince(tick))))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button(tr("Cancelar")) { server.cancelPairing() }
                                }
                            }
                        } else {
                            Button(tr("Mostrar el código QR")) { server.startPairing() }.buttonStyle(.borderedProminent)
                        }
                    }
                    Card(title: tr("Móviles emparejados"), systemImage: "lock.iphone") {
                        Text(tr("%d móviles con acceso.", server.deviceCount))
                        Button(tr("Quitar el acceso a todos")) { server.revokeAll() }.disabled(server.deviceCount == 0)
                        Text(tr("Cada móvil guarda su propia llave. Quitar el acceso las anula todas: habrá que volver a emparejar."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card(title: tr("Qué puede hacer el móvil"), systemImage: "checklist") {
                    Text(tr("Ver el estado, el objeto, los fotogramas, la batería, el avance del plan y la imagen apilada (se actualiza cada 15 s). Parar, saltar al siguiente objeto y aparcar, siempre con confirmación. No puede ver ni cambiar los ajustes, la clave ni los archivos."))
                        .font(.callout)
                }
            }
            .padding(20)
        }
        .navigationTitle(tr("Control desde el móvil"))
        .onReceive(timer) { tick = $0 }
    }
}
