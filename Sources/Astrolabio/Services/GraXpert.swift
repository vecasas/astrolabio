import Foundation
import CryptoKit

/// Integración con GraXpert (gratuito, https://www.graxpert.com) por su línea de órdenes.
/// Seguridad: se ejecuta el programa directamente con una lista de argumentos (sin shell), sobre
/// archivos en una carpeta temporal propia que se borra al terminar. El original no se toca.
enum GraXpert {
    enum Tool: String, CaseIterable, Identifiable {
        case background = "background-extraction"
        case denoise = "denoising"
        var id: String { rawValue }
        var label: String { self == .background ? tr("Quitar el gradiente con IA") : tr("Quitar el ruido con IA") }
    }

    enum RunError: LocalizedError {
        case notInstalled, failed(String), timedOut, noOutput
        var errorDescription: String? {
            switch self {
            case .notInstalled: return tr("GraXpert no está instalado.")
            case .failed(let s): return tr("GraXpert terminó con un error: %@", s)
            case .timedOut: return tr("GraXpert tardó demasiado y se ha detenido.")
            case .noOutput: return tr("GraXpert no devolvió ninguna imagen.")
            }
        }
    }

    /// Ubicaciones habituales del ejecutable en el Mac.
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications/GraXpert.app/Contents/MacOS/GraXpert",
                home.appendingPathComponent("Applications/GraXpert.app/Contents/MacOS/GraXpert").path]
            .map { URL(fileURLWithPath: $0) }
    }

    static func find(in list: [URL] = candidates) -> URL? {
        list.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Argumentos para la línea de órdenes de GraXpert (documentada en su README).
    static func arguments(tool: Tool, input: URL, outputBase: URL, strength: Double) -> [String] {
        var a = [input.path, "-cli", "-cmd", tool.rawValue, "-output", outputBase.path]
        switch tool {
        case .background: a += ["-correction", "Subtraction", "-smoothing", String(format: "%.2f", min(1, max(0, strength)))]
        case .denoise: a += ["-strength", String(format: "%.2f", min(1, max(0, strength)))]
        }
        return a
    }

    /// Procesa una imagen lineal con GraXpert y devuelve el resultado.
    static func run(_ tool: Tool, image: LinearImage, strength: Double, executable: URL? = nil,
                    timeout: TimeInterval = 900) async throws -> LinearImage {
        guard let exe = executable ?? find() else { throw RunError.notInstalled }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Astrolabio-GraXpert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("entrada.fits")
        let outBase = dir.appendingPathComponent("salida")
        try ImageProcessing.saveFITS(image, to: input, object: "Astrolabio")

        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(tool: tool, input: input, outputBase: outBase, strength: strength)
        p.currentDirectoryURL = dir
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline || Task.isCancelled { p.terminate(); throw RunError.timedOut }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errPipe.fileHandleForReading.availableData.prefix(400), as: UTF8.self)
            throw RunError.failed(msg.isEmpty ? "código \(p.terminationStatus)" : msg)
        }
        // GraXpert añade la extensión del archivo de entrada.
        for ext in ["fits", "fit"] {
            let out = outBase.appendingPathExtension(ext)
            if let data = try? Data(contentsOf: out), let (img, _) = PhotoEditor.readFITS(data) { return img }
        }
        throw RunError.noOutput
    }
}

// MARK: - Copia del álbum del Seestar al ordenador

/// Copia del álbum por carpetas, con reanudación y comprobación de tamaño y SHA-256.
/// Nunca borra nada del telescopio.
enum AlbumCopy {
    static let maxFileBytes = 2_000_000_000
    static let manifestName = ".astrolabio-copia.json"

    struct Entry: Codable, Equatable {
        let name: String
        let size: Int
        let sha256: String
    }

    /// Archivos de una carpeta: los de la lista HTML del servidor si la da; si no, la imagen
    /// grande conocida y su FITS con el mismo nombre (si existe).
    static func listFolder(_ folderURL: URL, knownFull: URL) async -> [URL] {
        var req = URLRequest(url: folderURL)
        req.timeoutInterval = 15
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html"), data.count < 5_000_000 {
            let names = parseIndex(String(decoding: data, as: UTF8.self))
            if !names.isEmpty { return names.map { folderURL.appendingPathComponent($0) } }
        }
        let stem = knownFull.deletingPathExtension()
        return [knownFull, stem.appendingPathExtension("fit")]
    }

    /// Nombres de archivo de una página de índice («<a href="…">»): solo archivos de imagen o vídeo
    /// de esa misma carpeta, sin rutas, sin «..» y sin enlaces a otros servidores.
    static func parseIndex(_ html: String) -> [String] {
        let allowed: Set<String> = ["jpg", "jpeg", "png", "fit", "fits", "tif", "tiff", "mp4", "avi"]
        var out: [String] = []
        var seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"href\s*=\s*"([^"]+)""#, options: .caseInsensitive)
        for m in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let raw = String(html[r])
            guard let name = raw.removingPercentEncoding, !name.contains("/"), !name.contains(".."), !name.contains(":"),
                  !name.hasPrefix("."), allowed.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func loadManifest(_ folder: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func saveManifest(_ m: [String: Entry], _ folder: URL) {
        if let data = try? JSONEncoder().encode(m.values.sorted { $0.name < $1.name }) {
            try? data.write(to: folder.appendingPathComponent(manifestName), options: .atomic)
        }
    }

    enum Outcome: Equatable { case copied, alreadyThere, missing, failed(String) }

    /// Copia un archivo a la carpeta, comprobando el tamaño anunciado y guardando su SHA-256.
    /// Si ya está copiado y verificado, no se descarga otra vez (reanudación).
    static func copy(_ url: URL, into folder: URL, manifest: inout [String: Entry]) async -> Outcome {
        let name = SafeName.fileComponent(url.lastPathComponent, fallback: "archivo")
        let dest = folder.appendingPathComponent(name)
        guard SafeName.isInside(dest, folder) else { return .failed("ruta") }
        if let e = manifest[name], let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == e.size,
           (try? sha256(of: dest)) == e.sha256 {
            return .alreadyThere
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let http = resp as? HTTPURLResponse else { return .failed("respuesta") }
            if http.statusCode == 404 { return .missing }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            let size = (try tmp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= maxFileBytes else { return .failed("tamaño") }
            if http.expectedContentLength > 0 && Int64(size) != http.expectedContentLength {
                return .failed(tr("tamaño distinto del anunciado"))
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            manifest[name] = Entry(name: name, size: size, sha256: try sha256(of: dest))
            return .copied
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
