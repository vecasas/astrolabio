import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Una carpeta del álbum del Seestar (el telescopio da su portada y cuántos archivos tiene).
struct AlbumFile: Identifiable, Hashable {
    var id: String { thumbURL.absoluteString }
    let group: String
    let name: String
    let thumbURL: URL
    let fullURL: URL
    let isSubframe: Bool
    let count: Int

    /// Nombre legible: «M 45», «M 45 · subtomas», «NGC 1981 · mosaico».
    var title: String {
        var t = name
        var extras: [String] = []
        if t.hasSuffix("_sub") { t.removeLast(4); extras.append("subtomas") }
        if t.hasSuffix("_mosaic") { t.removeLast(7); extras.append("mosaico") }
        t = t.replacingOccurrences(of: "_", with: " ")
        return ([t] + extras).joined(separator: " · ")
    }

    /// Fecha y hora sacadas del nombre de la portada (…_20261030-234613_thn.jpg).
    var date: Date? {
        let s = thumbURL.lastPathComponent
        guard let r = s.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(s[r]))
    }
}

/// Una imagen guardada en el Mac.
struct LocalImage: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
}

/// Qué se está viendo a tamaño completo.
enum AlbumViewerItem: Identifiable {
    case remote(AlbumFile)
    case local(LocalImage)
    var id: String {
        switch self {
        case .remote(let f): return f.id
        case .local(let l): return l.url.path
        }
    }
}

@MainActor
struct AlbumView: View {
    @EnvironmentObject var client: SeestarClient
    @EnvironmentObject var settings: AppSettings

    enum Tab: String, CaseIterable, Identifiable { case seestar = "En el Seestar", mac = "En este Mac"; var id: String { rawValue } }

    @State private var tab: Tab = .seestar
    @State private var files: [AlbumFile] = []
    @State private var local: [LocalImage] = []
    @State private var selection = Set<AlbumFile.ID>()
    @State private var loading = false
    @State private var showSubframes = false
    @State private var message = ""
    @State private var viewer: AlbumViewerItem?

    private var visible: [AlbumFile] { files.filter { showSubframes || !$0.isSubframe } }
    private var groups: [String] { Array(Set(visible.map(\.group))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text(tr($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 260)
                if tab == .seestar {
                    Button { Task { await load() } } label: { Label(tr("Cargar"), systemImage: "arrow.clockwise") }
                        .disabled(!client.isConnected || loading)
                    if loading { ProgressView().controlSize(.small) }
                    Toggle(tr("Subtomas"), isOn: $showSubframes).toggleStyle(.checkbox)
                    Spacer()
                    Text(tr("%@ seleccionadas", "\(selection.count)")).foregroundStyle(.secondary)
                    Button(tr("Seleccionar todo")) { selection = Set(visible.map(\.id)) }
                    Button(tr("Descargar al Mac")) { Task { await download() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty)
                } else {
                    Button { loadLocal() } label: { Label(tr("Actualizar"), systemImage: "arrow.clockwise") }
                    Spacer()
                    Text(tr("%@ imágenes", "\(local.count)")).foregroundStyle(.secondary)
                    Button(tr("Abrir la carpeta")) { NSWorkspace.shared.open(settings.saveFolderURL) }
                }
            }
            .padding(12)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Theme.accentSoft).padding(.horizontal, 12).padding(.bottom, 6) }
            Divider().overlay(Theme.cardStroke)
            ScrollView {
                if tab == .seestar { seestarGrid } else { localGrid }
            }
        }
        .navigationTitle(tr("Álbum"))
        .sheet(item: $viewer) { item in AlbumViewer(item: item, onClose: { viewer = nil }, onDownload: { f in
            Task { await download([f]) }
        }).nightMode() }
        .task { if client.isConnected && files.isEmpty { await load() } }
        .onChange(of: tab) { _, t in if t == .mac { loadLocal() } }
    }

    // MARK: Seestar

    @ViewBuilder
    private var seestarGrid: some View {
        if files.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text(client.isConnected ? tr("Pulsa «Cargar» para ver las fotos del telescopio.") : tr("Conecta el telescopio para ver su álbum."))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.self) { group in
                    Text(groupTitle(group)).font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ForEach(visible.filter { $0.group == group }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) { file in
                            remoteTile(file)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func groupTitle(_ g: String) -> String {
        switch g {
        case "DeepSky": return tr("Cielo profundo")
        case "SolarSystem": return tr("Sistema solar")
        case "Scenery": return tr("Paisaje")
        default: return g
        }
    }

    private func remoteTile(_ file: AlbumFile) -> some View {
        let selected = selection.contains(file.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: file.thumbURL, contentMode: .fill)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { viewer = .remote(file) }
                Button {
                    if selected { selection.remove(file.id) } else { selection.insert(file.id) }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? Theme.accent : .white.opacity(0.85))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : Theme.cardStroke, lineWidth: selected ? 2 : 1))
            Text(file.title).font(.callout.weight(.semibold)).lineLimit(1)
            HStack {
                Text(file.date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Loc.shared.locale)) ?? "").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if file.count > 1 { Pill(text: "\(file.count)", systemImage: "photo.stack", color: Theme.accentSoft) }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let reply = try await client.albums()
            guard let result = reply["result"] as? JSONObject else { message = tr("Respuesta sin álbum."); return }
            let basePath = (result["path"] as? String) ?? ""
            let groupsList = (result["list"] as? [JSONObject]) ?? []
            var out: [AlbumFile] = []
            for g in groupsList {
                let groupName = (g["group_name"] as? String) ?? (g["name"] as? String) ?? tr("Sin nombre")
                for f in (g["files"] as? [JSONObject]) ?? [] {
                    guard let thn = f["thn"] as? String else { continue }
                    let name = (f["name"] as? String) ?? thn
                    let full = thn.hasSuffix("_thn.jpg") ? String(thn.dropLast("_thn.jpg".count)) + ".jpg" : thn
                    guard let tURL = url(basePath, thn), let fURL = url(basePath, full) else { continue }
                    out.append(AlbumFile(group: groupName, name: name, thumbURL: tURL, fullURL: fURL,
                                         isSubframe: name.hasSuffix("_sub") || name.hasSuffix("-sub"),
                                         count: (f["count"] as? NSNumber)?.intValue ?? 1))
                }
            }
            files = out
            message = tr("%@ carpetas en %@ grupos. Haz clic en una foto para verla en grande.", "\(out.count)", "\(groupsList.count)")
        } catch {
            message = error.localizedDescription
        }
    }

    private func url(_ base: String, _ file: String) -> URL? {
        let path = ([base, file].filter { !$0.isEmpty }.joined(separator: "/"))
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return URL(string: "http://\(client.host)/\(path)")
    }

    private func download(_ chosenFiles: [AlbumFile]? = nil) async {
        let chosen = chosenFiles ?? files.filter { selection.contains($0.id) }
        var ok = 0
        for file in chosen {
            let folder = settings.saveFolderURL.appendingPathComponent("Álbum").appendingPathComponent(file.title)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            message = tr("Descargando %@…", "\(file.title)")
            do {
                let (tmp, _) = try await URLSession.shared.download(from: file.fullURL)
                let dest = folder.appendingPathComponent(file.fullURL.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                ok += 1
            } catch {
                client.addLog(tr("No se pudo descargar %@: %@", "\(file.name)", "\(error.localizedDescription)"), .warning)
            }
        }
        message = tr("Descargadas %@ de %@ en %@/Álbum.", "\(ok)", "\(chosen.count)", "\(settings.saveFolderURL.path)")
    }

    // MARK: Mac

    @ViewBuilder
    private var localGrid: some View {
        if local.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text(tr("Aún no hay imágenes en %@.", "\(settings.saveFolderURL.path)")).foregroundStyle(.secondary)
                Text(tr("Aquí aparecen las fotos guardadas desde la vista en directo, el apilador planetario y las descargas del álbum."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(local) { img in
                    VStack(alignment: .leading, spacing: 6) {
                        LocalThumb(url: img.url)
                            .frame(height: 140).frame(maxWidth: .infinity)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
                            .onTapGesture { viewer = .local(img) }
                            .contextMenu {
                                Button(tr("Mostrar en el Finder")) { NSWorkspace.shared.activateFileViewerSelecting([img.url]) }
                                Button(tr("Abrir con la app predeterminada")) { NSWorkspace.shared.open(img.url) }
                            }
                        Text(img.url.deletingPathExtension().lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(img.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Loc.shared.locale))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private func loadLocal() {
        let root = settings.saveFolderURL
        let exts: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic"]
        var out: [LocalImage] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let u as URL in en where exts.contains(u.pathExtension.lowercased()) {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append(LocalImage(url: u, date: d))
            }
        }
        local = out.sorted { $0.date > $1.date }
    }
}

/// Miniatura de un archivo local (se genera fuera del hilo principal).
struct LocalThumb: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            else { ProgressView() }
        }
        .clipped()
        .task(id: url) {
            let u = url
            image = await Task.detached { LocalThumb.thumbnail(u, max: 400) }.value
        }
    }

    nonisolated static func thumbnail(_ url: URL, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}

/// Visor a tamaño completo con zoom.
@MainActor
struct AlbumViewer: View {
    let item: AlbumViewerItem
    let onClose: () -> Void
    let onDownload: (AlbumFile) -> Void
    @State private var zoom: CGFloat = 1
    @State private var localImage: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Slider(value: $zoom, in: 1...6).frame(width: 160)
                if case .remote(let f) = item {
                    Button { onDownload(f) } label: { Label(tr("Descargar"), systemImage: "arrow.down.circle") }
                }
                if case .local(let l) = item {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([l.url]) } label: { Label(tr("Finder"), systemImage: "folder") }
                }
                Button(tr("Cerrar")) { onClose() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    content
                        .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                }
                .background(Color.black)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Theme.deep)
        .task {
            if case .local(let l) = item {
                let u = l.url
                localImage = await Task.detached { LocalThumb.thumbnail(u, max: 4000) }.value
            }
        }
    }

    private var title: String {
        switch item {
        case .remote(let f): return f.title
        case .local(let l): return l.url.lastPathComponent
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .remote(let f):
            RemoteImage(url: f.fullURL, contentMode: .fit, loadingText: tr("Descargando del telescopio…"))
        case .local:
            if let localImage {
                Image(decorative: localImage, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else { ProgressView() }
        }
    }
}

/// Imagen descargada por HTTP. El servidor del Seestar envía los JPEG como
/// «application/octet-stream», así que se descodifican a mano con ImageIO (y se guardan en caché).
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    var loadingText: String? = nil
    @State private var image: CGImage?
    @State private var failed = false

    private static let cache = NSCache<NSURL, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    Text(tr("No se pudo cargar")).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    if let loadingText { Text(loadingText).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: url as NSURL) { image = hit.image; return }
        failed = false
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { failed = true; return }
            let decoded = await Task.detached { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }.value
            if let decoded {
                Self.cache.setObject(CGImageBox(decoded), forKey: url as NSURL)
                image = decoded
            } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
