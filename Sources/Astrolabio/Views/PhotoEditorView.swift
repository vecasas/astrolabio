import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Estado del editor (compartido para poder abrir una foto desde el álbum).
@MainActor
final class PhotoEditorModel: ObservableObject {
    static let shared = PhotoEditorModel()

    @Published private(set) var source: EditableImage?
    @Published private(set) var url: URL?
    @Published var edit = PhotoEdit() { didSet { schedulePreview() } }
    @Published var trails: [SatelliteTrail] = [] { didSet { schedulePreview() } }
    @Published var showLabels = false { didSet { schedulePreview() } }
    @Published private(set) var preview: CGImage?
    @Published private(set) var before: CGImage?
    @Published private(set) var busy = false
    @Published var message = ""
    /// Versiones anteriores de los datos (para deshacer GraXpert).
    @Published private(set) var undoStack: [LinearImage] = []

    /// Copia reducida para la vista previa (rápida); la exportación usa la imagen completa.
    private var small: EditableImage?
    private var smallScale = 1.0
    private var previewTask: Task<Void, Never>?

    static let previewMaxSide = 1400

    func open(_ url: URL) {
        busy = true
        message = ""
        Task {
            do {
                let img = try await Task.detached { try PhotoEditor.load(url) }.value
                self.url = url
                source = img
                undoStack = []
                trails = []
                edit = PhotoEdit()
                if !img.isLinear { edit.removeGradient = false; edit.neutralBackground = false; edit.blackPoint = 0; edit.saturation = 1 }
                makeSmall()
                busy = false
                schedulePreview()
            } catch {
                busy = false
                message = error.localizedDescription
            }
        }
    }

    private func makeSmall() {
        guard let s = source else { return }
        let f = max(1, Int(ceil(Double(max(s.image.width, s.image.height)) / Double(Self.previewMaxSide))))
        smallScale = Double(f)
        var e = s
        e.image = Self.downscale(s.image, factor: f)
        small = e
        let bOpts = PhotoEdit(removeGradient: false, neutralBackground: false, noise: 0, colorNoise: 0, sharpen: 0,
                              saturation: 1, starReduction: 0)
        before = PhotoEditor.cgImage(PhotoEditor.stretched(e.image, isLinear: e.isLinear, bOpts))
    }

    static func downscale(_ img: LinearImage, factor f: Int) -> LinearImage {
        guard f > 1 else { return img }
        let w = img.width / f, h = img.height / f
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for y in 0..<h { for x in 0..<w {
            var sr: Float = 0, sg: Float = 0, sb: Float = 0
            for dy in 0..<f { for dx in 0..<f {
                let i = (y * f + dy) * img.width + x * f + dx
                sr += img.r[i]; sg += img.g[i]; sb += img.b[i]
            } }
            let k = Float(f * f)
            r[y * w + x] = sr / k; g[y * w + x] = sg / k; b[y * w + x] = sb / k
        } }
        return LinearImage(width: w, height: h, r: r, g: g, b: b)
    }

    func schedulePreview() {
        previewTask?.cancel()
        guard let s = small else { return }
        let e = edit, scale = smallScale
        let tr = trails.map { t -> SatelliteTrail in
            var c = t
            c.p1 = CGPoint(x: t.p1.x / scale, y: t.p1.y / scale); c.p2 = CGPoint(x: t.p2.x / scale, y: t.p2.y / scale)
            c.halfWidth = max(1, t.halfWidth / scale)
            return c
        }
        let labels = showLabels ? wcs(for: s) : nil
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let processed = PhotoEditor.process(s, e, trails: tr)
                guard var cg = PhotoEditor.cgImage(PhotoEditor.stretched(processed, isLinear: s.isLinear, e)) else { return nil }
                if let labels, e.crop == .original { cg = SkyLabels.draw(on: cg, wcs: labels) ?? cg }
                return cg
            }.value
            if !Task.isCancelled { preview = img }
        }
    }

    /// Solución del cielo: la de la cabecera FITS o una estimación con el centro y el campo del Seestar.
    func wcs(for img: EditableImage, fovWidthDeg: Double = 0.73) -> ImageWCS? {
        if let w = ImageWCS.fromFITS(img.header, width: img.image.width, height: img.image.height) { return w }
        // El encabezado describe la imagen completa: para la copia reducida se reescala.
        if let full = source, let w0 = ImageWCS.fromFITS(full.header, width: full.image.width, height: full.image.height) {
            let k = Double(full.image.width) / Double(img.image.width)
            return ImageWCS(raDeg: w0.raDeg, decDeg: w0.decDeg, refX: w0.refX / k, refY: w0.refY / k,
                            cd11: w0.cd11 * k, cd12: w0.cd12 * k, cd21: w0.cd21 * k, cd22: w0.cd22 * k, solved: true)
        }
        guard let c = SkyLabels.approximateCenter(header: source?.header ?? [:], name: img.name) else { return nil }
        return ImageWCS.estimate(raHours: c.raHours, decDeg: c.decDeg, width: img.image.width, height: img.image.height, fovWidthDeg: fovWidthDeg)
    }

    var labelsAreApproximate: Bool {
        guard let s = small else { return true }
        return !(wcs(for: s)?.solved ?? false)
    }

    func detectTrails() {
        guard let s = source else { return }
        busy = true
        Task {
            let found = await Task.detached { SatelliteTrails.detect(s.image) }.value
            trails.removeAll { !$0.manual }
            trails += found
            busy = false
            message = found.isEmpty ? tr("No se han encontrado trazas de satélite.") : tr("%@ trazas encontradas. Desmarca las que no lo sean.", "\(found.count)")
        }
    }

    /// Traza marcada a mano (dos puntos en coordenadas de la vista previa).
    func addManualTrail(_ a: CGPoint, _ b: CGPoint) {
        trails.append(SatelliteTrail(p1: CGPoint(x: a.x * smallScale, y: a.y * smallScale),
                                     p2: CGPoint(x: b.x * smallScale, y: b.y * smallScale), halfWidth: 3 * smallScale, manual: true))
    }

    var previewScale: Double { smallScale }

    func runGraXpert(_ tool: GraXpert.Tool, strength: Double) {
        guard let s = source else { return }
        busy = true
        message = tr("GraXpert está trabajando… puede tardar unos minutos.")
        Task {
            do {
                let out = try await GraXpert.run(tool, image: s.image, strength: strength)
                guard out.width == s.image.width, out.height == s.image.height else { throw GraXpert.RunError.noOutput }
                undoStack.append(s.image)
                var n = s
                n.image = out
                source = n
                if tool == .background { edit.removeGradient = false }
                if tool == .denoise { edit.noise = 0 }
                makeSmall()
                message = tr("GraXpert ha terminado.")
            } catch {
                message = error.localizedDescription
            }
            busy = false
            schedulePreview()
        }
    }

    func undo() {
        guard var s = source, let last = undoStack.popLast() else { return }
        s.image = last
        source = s
        makeSmall()
        schedulePreview()
    }

    /// Exporta a resolución completa. Devuelve el archivo creado.
    func export(format: PhotoEditor.ExportFormat, to url: URL, caption: String?, labels: Bool) async throws {
        guard let s = source else { return }
        let e = edit, tr = trails
        let w = labels ? wcs(for: s) : nil
        let cg: CGImage? = await Task.detached {
            let processed = PhotoEditor.process(s, e, trails: tr)
            guard var cg = PhotoEditor.cgImage(PhotoEditor.stretched(processed, isLinear: s.isLinear, e), bits16: format == .tiff16) else { return nil }
            if let w, e.crop == .original { cg = SkyLabels.draw(on: cg, wcs: w) ?? cg }
            if let caption { cg = PhotoEditor.addCaption(caption, to: cg) ?? cg }
            return cg
        }.value
        guard let cg else { throw CocoaError(.fileWriteUnknown) }
        try PhotoEditor.export(cg, format: format, to: url)
    }
}

/// Retoque de fotos: gradiente, fondo neutro, ruido, enfoque, estrellas, trazas de satélite,
/// nombres de los objetos, GraXpert y exportación. El original no se modifica nunca.
@MainActor
struct PhotoEditorView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model = PhotoEditorModel.shared
    @State private var split = 0.5
    @State private var compare = false
    @State private var marking = false
    @State private var firstPoint: CGPoint?
    @State private var format: PhotoEditor.ExportFormat = .jpeg
    @State private var gxStrength = 0.5

    var body: some View {
        HSplitView {
            previewArea.frame(minWidth: 500)
            ScrollView { controls.padding(14) }.frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
        }
    }

    private var previewArea: some View {
        VStack(spacing: 8) {
            HStack {
                Button(tr("Abrir una imagen…")) { openPanel() }
                if let u = model.url { Text(u.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Toggle(tr("Comparar antes/después"), isOn: $compare).toggleStyle(.switch).disabled(model.preview == nil)
            }
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let img = model.preview {
                        let size = fitted(img, in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: img, scale: 1).resizable().frame(width: size.width, height: size.height)
                            if compare, let b = model.before {
                                Image(decorative: b, scale: 1).resizable().frame(width: size.width, height: size.height)
                                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                                Rectangle().fill(.white).frame(width: 2, height: size.height).offset(x: size.width * split - 1)
                            }
                            trailOverlay(img: img, size: size)
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { t in tap(t.location, img: img, size: size) })
                    } else {
                        Text(tr("Abre una imagen del álbum, de tu carpeta o un FITS para retocarla. El original no se modifica nunca."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(40)
                    }
                }
            }
            if compare { Slider(value: $split, in: 0...1) { Text(tr("Antes | después")) } }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(Theme.accentSoft) }
        }
        .padding(12)
    }

    private func fitted(_ img: CGImage, in box: CGSize) -> CGSize {
        let k = min(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
        return CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
    }

    private func trailOverlay(img: CGImage, size: CGSize) -> some View {
        let k = size.width / CGFloat(img.width) / CGFloat(model.previewScale)
        return Canvas { ctx, _ in
            for t in model.trails {
                var p = Path()
                p.move(to: CGPoint(x: t.p1.x * k, y: t.p1.y * k)); p.addLine(to: CGPoint(x: t.p2.x * k, y: t.p2.y * k))
                ctx.stroke(p, with: .color(t.enabled ? .red.opacity(0.8) : .gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if let f = firstPoint {
                ctx.fill(Path(ellipseIn: CGRect(x: f.x - 4, y: f.y - 4, width: 8, height: 8)), with: .color(.red))
            }
        }
        .allowsHitTesting(false)
    }

    private func tap(_ p: CGPoint, img: CGImage, size: CGSize) {
        guard marking else { return }
        if let f = firstPoint {
            let k = CGFloat(img.width) / size.width
            model.addManualTrail(CGPoint(x: f.x * k, y: f.y * k), CGPoint(x: p.x * k, y: p.y * k))
            firstPoint = nil
            marking = false
        } else {
            firstPoint = p
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: tr("Ajustes"), systemImage: "slider.horizontal.3") {
                Toggle(tr("Quitar el gradiente (contaminación lumínica)"), isOn: $model.edit.removeGradient)
                Toggle(tr("Fondo neutro"), isOn: $model.edit.neutralBackground)
                slider(tr("Punto negro"), $model.edit.blackPoint, 0...1)
                slider(tr("Brillo"), $model.edit.brightness, 0...1)
                slider(tr("Ruido"), $model.edit.noise, 0...1)
                slider(tr("Ruido de color"), $model.edit.colorNoise, 0...1)
                slider(tr("Enfoque"), $model.edit.sharpen, 0...1)
                slider(tr("Saturación"), $model.edit.saturation, 0...2)
                slider(tr("Reducir estrellas"), $model.edit.starReduction, 0...1)
                Picker(tr("Recorte"), selection: $model.edit.crop) { ForEach(CropAspect.allCases) { Text(tr($0.rawValue)).tag($0) } }
                if model.edit.crop == .free {
                    slider(tr("Izquierda"), Binding(get: { model.edit.freeCrop.minX }, set: { model.edit.freeCrop.origin.x = $0 }), 0...0.9)
                    slider(tr("Arriba"), Binding(get: { model.edit.freeCrop.minY }, set: { model.edit.freeCrop.origin.y = $0 }), 0...0.9)
                    slider(tr("Ancho"), Binding(get: { model.edit.freeCrop.width }, set: { model.edit.freeCrop.size.width = $0 }), 0.1...1)
                    slider(tr("Alto"), Binding(get: { model.edit.freeCrop.height }, set: { model.edit.freeCrop.size.height = $0 }), 0.1...1)
                }
                Button(tr("Valores iniciales")) { model.edit = PhotoEdit() }
            }
            Card(title: tr("Trazas de satélite"), systemImage: "line.diagonal") {
                HStack {
                    Button(tr("Buscar trazas")) { model.detectTrails() }
                    Button(marking ? tr("Haz clic en los dos extremos…") : tr("Marcar a mano")) { marking.toggle(); firstPoint = nil }
                }
                ForEach($model.trails) { $t in
                    HStack {
                        Toggle(isOn: $t.enabled) {
                            Text(t.manual ? tr("Traza marcada a mano (%@ px)", "\(Int(t.length))") : tr("Traza de %@ px", "\(Int(t.length))"))
                        }
                        Spacer()
                        Button { model.trails.removeAll { $0.id == t.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
            Card(title: tr("Nombres de los objetos"), systemImage: "tag") {
                Toggle(tr("Mostrar nombres y la rosa N/E"), isOn: $model.showLabels)
                if model.showLabels && model.labelsAreApproximate {
                    Text(tr("Esta imagen no trae solución astrométrica: las posiciones se estiman con el objeto central y el campo del Seestar, suponiendo el norte arriba. Pueden estar giradas."))
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                if model.edit.crop != .original { Text(tr("Los nombres solo se dibujan sin recorte.")).font(.caption).foregroundStyle(.secondary) }
            }
            Card(title: "GraXpert", systemImage: "cpu") {
                if GraXpert.find() != nil {
                    slider(tr("Intensidad"), $gxStrength, 0...1)
                    ForEach(GraXpert.Tool.allCases) { tool in
                        Button(tool.label) { model.runGraXpert(tool, strength: gxStrength) }.disabled(model.busy || model.source == nil)
                    }
                    if !model.undoStack.isEmpty { Button(tr("Deshacer GraXpert")) { model.undo() } }
                    Text(tr("Usa los modelos de IA de GraXpert en tu ordenador; la imagen no sale de él.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("Instala GraXpert (gratuito, graxpert.com) para quitar el gradiente y el ruido con IA. Mientras tanto se usan los ajustes de Astrolabio."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title: tr("Guardar"), systemImage: "square.and.arrow.down") {
                Toggle(tr("Añadir un pie con el objeto, la exposición y la fecha"), isOn: $model.edit.caption)
                Picker(tr("Formato"), selection: $format) { ForEach(PhotoEditor.ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                Button(tr("Guardar una copia…")) { save() }.buttonStyle(.borderedProminent).disabled(model.source == nil || model.busy)
                Text(tr("Se guarda una copia nueva; el original no se toca.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: v, in: range)
            Text(String(format: "%.2f", v.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 36)
        }
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.jpeg, .png, .tiff, UTType(filenameExtension: "fits") ?? .data, UTType(filenameExtension: "fit") ?? .data]
        p.directoryURL = settings.saveFolderURL
        if p.runModal() == .OK, let u = p.url { model.open(u) }
    }

    private func caption() -> String? {
        guard model.edit.caption, let s = model.source else { return nil }
        var parts: [String] = []
        if let c = SkyLabels.approximateCenter(header: s.header, name: s.name),
           let o = Catalog.objects.min(by: { Astro.separation(ra1: $0.raHours, dec1: $0.decDeg, ra2: c.raHours, dec2: c.decDeg) < Astro.separation(ra1: $1.raHours, dec1: $1.decDeg, ra2: c.raHours, dec2: c.decDeg) }) {
            parts.append(o.displayName)
        }
        if let m = s.name.range(of: #"(\d+(?:\.\d+)?)s"#, options: .regularExpression), let n = s.name.range(of: #"Stacked_(\d+)"#, options: .regularExpression) {
            let frames = s.name[n].dropFirst(8), exp = s.name[m].dropLast()
            if let f = Double(frames), let e = Double(exp) {
                parts.append(tr("%@ × %@ s (%@)", String(frames), String(exp), ReportFormat.duration(f * e / 60)))
            }
        }
        if let d = s.name.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            if let date = f.date(from: String(s.name[d])) { parts.append(ReportFormat.date(date)) }
        }
        parts.append("Seestar S50 · Astrolabio")
        return parts.joined(separator: "  ·  ")
    }

    private func save() {
        guard let src = model.url else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [format.type]
        p.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent)_retocada.\(format.ext)"
        p.directoryURL = settings.saveFolderURL
        guard p.runModal() == .OK, let url = p.url else { return }
        guard url.standardizedFileURL != src.standardizedFileURL else { model.message = tr("Elige otro nombre: el original no se sobrescribe."); return }
        let cap = caption(), labels = model.showLabels
        Task {
            do {
                try await model.export(format: format, to: url, caption: cap, labels: labels)
                model.message = tr("Guardada en %@", url.lastPathComponent)
            } catch { model.message = error.localizedDescription }
        }
    }
}
