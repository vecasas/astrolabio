import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Estado del apilador planetario.
@MainActor
final class StackerModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var fileInfo = ""
    @Published var options = StackOptions()
    @Published var finish = PlanetaryStacker.Finish() { didSet { if finish != oldValue { render() } } }
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var running = false
    @Published private(set) var result: StackResult?
    @Published private(set) var preview: CGImage?
    @Published private(set) var bestPreview: CGImage?
    @Published var message = ""
    private var finished: RGBFrame?
    private var renderGen = 0

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "ser") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        fileURL = url
        result = nil
        preview = nil
        bestPreview = nil
        message = ""
        fileInfo = tr("Leyendo…")
        Task {
            do {
                let src = try await PlanetaryStacker.open(url)
                fileInfo = tr("%@×%@ · unos %@ fotogramas", "\(src.width)", "\(src.height)", "\(src.estimatedFrames)") + (src.fps > 0 ? tr(" · %.0f fps", src.fps) : "")
            } catch {
                fileInfo = error.localizedDescription
            }
        }
    }

    func run() {
        guard let url = fileURL, !running else { return }
        running = true
        progress = 0
        stage = tr("Abriendo…")
        message = ""
        let opts = options
        Task {
            do {
                let src = try await PlanetaryStacker.open(url)
                let res = try await Task.detached(priority: .userInitiated) {
                    try PlanetaryStacker.stack(source: src, options: opts) { text, p in
                        Task { @MainActor [weak self] in self?.stage = text; self?.progress = p }
                    }
                }.value
                result = res
                bestPreview = PlanetaryStacker.cgImage(PlanetaryStacker.finish(res.bestFrame, .init(fine: 0, medium: 0, gamma: finish.gamma, balance: finish.balance)))
                stage = tr("Apilados %@ de %@ fotogramas", "\(res.used)", "\(res.analyzed)")
                render()
            } catch {
                stage = ""
                message = error.localizedDescription
            }
            running = false
        }
    }

    func render() {
        guard let res = result else { return }
        renderGen += 1
        let gen = renderGen, f = finish
        Task.detached(priority: .userInitiated) {
            let out = PlanetaryStacker.finish(res.stacked, f)
            let img = PlanetaryStacker.cgImage(out)
            await MainActor.run { [weak self] in
                guard let self, gen == self.renderGen else { return }
                self.finished = out
                self.preview = img
            }
        }
    }

    func save(to folder: URL, tiff: Bool) {
        guard let finished else { return }
        let dir = folder.appendingPathComponent("Planetario", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "planeta"
        let url = dir.appendingPathComponent("\(base)_apilado_\(result?.used ?? 0).\(tiff ? "tif" : "png")")
        do {
            try PlanetaryStacker.save(finished, to: url)
            message = tr("Guardado en %@", "\(url.path)")
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Apilador planetario: vídeo de la Luna o de un planeta → imagen nítida.
@MainActor
struct StackerView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = StackerModel()
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    images
                    if let r = model.result { qualityChart(r) }
                }
                .padding(20)
            }
            .frame(minWidth: 420, idealWidth: 700, maxWidth: .infinity)
            controls.frame(minWidth: 260, idealWidth: 290, maxWidth: 330)
        }
        .navigationTitle(tr("Apilador planetario"))
    }

    @ViewBuilder
    private var images: some View {
        if model.result == nil {
            VStack(spacing: 12) {
                Image(systemName: "film.stack").font(.system(size: 54)).foregroundStyle(Theme.accent)
                Text(tr("Arrastra aquí un vídeo de un planeta o de la Luna")).font(.title3.weight(.semibold))
                Text(tr("MP4 o MOV (por ejemplo, grabado con el Seestar en modo planeta) o SER de una cámara planetaria."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(tr("Elegir vídeo…")) { model.choose() }.buttonStyle(.borderedProminent)
                if model.running {
                    ProgressView(value: model.progress).frame(width: 320)
                    Text(model.stage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(dropTargeted ? Theme.accent : Theme.cardStroke,
                                                               style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.load(url) } }
                }
                return true
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                imageCard(tr("Mejor fotograma"), model.bestPreview)
                imageCard(tr("Apilado y procesado"), model.preview)
            }
        }
    }

    private func imageCard(_ title: String, _ img: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ZStack {
                Color.black
                if let img {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else { ProgressView() }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private func qualityChart(_ r: StackResult) -> some View {
        let sorted = r.qualities.filter { $0 > 0 }.sorted(by: >)
        let maxQ = sorted.first ?? 1
        struct P: Identifiable { let id: Int; let q: Double }
        let pts = stride(from: 0, to: sorted.count, by: max(1, sorted.count / 300)).map { P(id: $0, q: sorted[$0] / maxQ * 100) }
        return Card(title: tr("Nitidez de los fotogramas (de mejor a peor)"), systemImage: "chart.line.downtrend.xyaxis") {
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Fotograma", p.id), y: .value("Nitidez", p.q))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.5), Theme.accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Fotograma", p.id), y: .value("Nitidez", p.q)).foregroundStyle(Theme.accentSoft)
                }
                RuleMark(x: .value("Corte", r.used)).foregroundStyle(Theme.warn)
                    .annotation(position: .top, alignment: .leading) { Text(tr("%@ usados", "\(r.used)")).font(.caption2).foregroundStyle(Theme.warn) }
            }
            .chartYAxisLabel(tr("% del mejor"))
            .frame(height: 160)
        }
    }

    private var controls: some View {
        Form {
            SwiftUI.Section(tr("Vídeo")) {
                Text(model.fileURL?.lastPathComponent ?? tr("Ninguno")).lineLimit(1).truncationMode(.middle)
                if !model.fileInfo.isEmpty { Text(model.fileInfo).font(.caption).foregroundStyle(.secondary) }
                Button(tr("Elegir otro…")) { model.choose() }
            }
            SwiftUI.Section(tr("Apilado")) {
                VStack(alignment: .leading) {
                    Text(tr("Usar el %@ %% más nítido", "\(Int(model.options.keepPercent))"))
                    Slider(value: $model.options.keepPercent, in: 5...100, step: 5)
                }
                Toggle(tr("Alineación fina"), isOn: $model.options.refine)
                    .help(tr("Además de centrar el planeta, corrige desplazamientos de fracciones de píxel."))
                Button {
                    model.run()
                } label: {
                    Label(model.running ? tr("Apilando…") : tr("Apilar"), systemImage: "square.stack.3d.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.fileURL == nil || model.running)
                if model.running {
                    ProgressView(value: model.progress)
                    Text(model.stage).font(.caption).foregroundStyle(.secondary)
                } else if !model.stage.isEmpty {
                    Text(model.stage).font(.caption).foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section(tr("Procesado")) {
                LabeledSlider(title: tr("Detalle fino"), value: $model.finish.fine, range: 0...4)
                LabeledSlider(title: tr("Detalle medio"), value: $model.finish.medium, range: 0...3)
                LabeledSlider(title: tr("Gamma"), value: $model.finish.gamma, range: 0.5...2.5)
                Toggle(tr("Equilibrar color"), isOn: $model.finish.balance)
                Button(tr("Restablecer")) { model.finish = .init() }
            }
            .disabled(model.result == nil)
            SwiftUI.Section(tr("Guardar")) {
                HStack {
                    Button(tr("PNG")) { model.save(to: settings.saveFolderURL, tiff: false) }
                    Button(tr("TIFF 16 bits")) { model.save(to: settings.saveFolderURL, tiff: true) }
                }
                .disabled(model.preview == nil)
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(Theme.accentSoft).textSelection(.enabled) }
                Text(tr("Se guarda en la carpeta de imágenes, dentro de «Planetario».")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
