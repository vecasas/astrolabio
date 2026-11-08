import SwiftUI

@MainActor
struct LiveView: View {
    @EnvironmentObject var live: LiveViewModel
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var saveMessage = ""

    var body: some View {
        HSplitView {
            imageArea
                .frame(minWidth: 380, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)
        }
        .navigationTitle(tr("Vista en directo"))
        .toolbar {
            ToolbarItemGroup {
                Button { live.requestStacked() } label: { Label(tr("Pedir imagen"), systemImage: "arrow.clockwise") }
                    .disabled(!client.isConnected)
                Button { openWindow(id: "starparty") } label: { Label(tr("Fiesta de estrellas"), systemImage: "sparkles.tv") }
            }
        }
    }

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = live.image {
                    // zoom 1 = imagen entera ajustada a la ventana.
                    let fit = min(geo.size.width / CGFloat(img.width), geo.size.height / CGFloat(img.height))
                    let w = CGFloat(img.width) * fit * zoom * pinch, h = CGFloat(img.height) * fit * zoom * pinch
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: w, height: h)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .gesture(MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { v in zoom = max(1, min(8, zoom * v.magnification)); pinch = 1 })
                    .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2.5 }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.aperture").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text(client.isConnected ? tr("Esperando la primera imagen apilada…") : tr("Conecta el telescopio para ver la imagen."))
                            .foregroundStyle(.secondary)
                    }
                }
                if live.isProcessing {
                    ProgressView().controlSize(.small).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    private var controls: some View {
        Form {
            SwiftUI.Section(tr("Imagen")) {
                Text(live.info).font(.caption).foregroundStyle(.secondary)
                if let m = live.lastStarMetrics {
                    Text(tr("Nitidez: HFR %@ px (%@ estrellas)", String(format: "%.2f", m.hfr), "\(m.stars)"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .help(tr("Radio de media intensidad de las estrellas: cuanto menor, más nítidas."))
                }
                Text(tr("%@ fotogramas apilados", "\(client.stackedFrames)")).font(.caption)
                if !live.streamStatus.isEmpty { Text(live.streamStatus).font(.caption2).foregroundStyle(.tertiary) }
                Toggle(tr("Actualizar sola"), isOn: $live.autoRefresh)
                Toggle(tr("Vista previa sin apilar"), isOn: Binding(
                    get: { live.isPreviewing },
                    set: { $0 ? live.startPreview() : live.stopPreview() }))
                    .disabled(!client.isConnected)
                    .help(tr("Muestra cada fotograma de la cámara (útil para encuadrar y enfocar)."))
                HStack {
                    Text(tr("Zoom"))
                    Slider(value: $zoom, in: 1...8)
                    Button(tr("Ajustar")) { zoom = 1 }.controlSize(.small)
                }
                Text(tr("Doble clic en la imagen para acercar o volver a verla entera.")).font(.caption2).foregroundStyle(.tertiary)
            }
            SwiftUI.Section(tr("Estirado")) {
                LabeledSlider(title: tr("Brillo del fondo"), value: $live.options.targetBackground, range: 0.05...0.45)
                LabeledSlider(title: tr("Recorte de sombras"), value: $live.options.shadowsClip, range: 0.5...5)
                LabeledSlider(title: tr("Saturación"), value: $live.options.saturation, range: 0.5...2.5)
                Toggle(tr("Canales enlazados"), isOn: $live.options.linked)
            }
            SwiftUI.Section(tr("Mejorar")) {
                Toggle(tr("Recortar bordes del apilado"), isOn: $live.options.cropEdges)
                Toggle(tr("Quitar gradiente (contaminación lumínica)"), isOn: $live.options.removeGradient)
                Toggle(tr("Fondo neutro y color de las estrellas"), isOn: $live.options.colorBalance)
                Toggle(tr("Reducir ruido"), isOn: $live.options.denoise)
                Button(tr("Restablecer")) { live.options = ProcessingOptions() }
            }
            SwiftUI.Section(tr("Guardar")) {
                Button(tr("Guardar PNG y FITS")) {
                    do {
                        let urls = try live.save(to: settings.saveFolderURL, name: currentName)
                        saveMessage = tr("Guardado en %@: %@", "\(settings.saveFolderURL.lastPathComponent)", "\(urls.map(\.lastPathComponent).joined(separator: ", "))")
                    } catch {
                        saveMessage = error.localizedDescription
                    }
                }
                .disabled(live.image == nil)
                Button(tr("Abrir carpeta")) { NSWorkspace.shared.open(settings.saveFolderURL) }
                if !saveMessage.isEmpty { Text(saveMessage).font(.caption2).foregroundStyle(.secondary) }
                Text(tr("El FITS conserva los datos lineales para procesarlos en Siril o GraXpert."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var currentName: String {
        (client.lastEvents["AutoGoto"]?.data["target_name"] as? String)
            ?? (client.lastEvents["Stack"]?.data["target_name"] as? String) ?? tr("Seestar")
    }
}

@MainActor
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// Imagen apilada a pantalla completa para enseñarla a otras personas.
@MainActor
struct StarPartyView: View {
    @EnvironmentObject var live: LiveViewModel
    @EnvironmentObject var client: SeestarClient

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            if let img = live.image {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(tr("Esperando imagen…")).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading) {
                Text(name).font(.largeTitle.bold())
                Text(tr("%@ fotogramas", "\(client.stackedFrames)")).font(.title3)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var name: String {
        (client.lastEvents["AutoGoto"]?.data["target_name"] as? String) ?? ""
    }
}
