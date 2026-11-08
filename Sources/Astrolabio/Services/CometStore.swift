import Foundation

/// Órbitas de cometas del Minor Planet Center. Se descargan una vez al día y se guardan en
/// Application Support/Astrolabio/CometEls.txt para poder usarlas sin internet.
@MainActor
final class CometStore: ObservableObject {
    static let shared = CometStore()
    static let source = URL(string: "https://www.minorplanetcenter.net/iau/MPCORB/CometEls.txt")!

    @Published private(set) var orbits: [CometOrbit] = []
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?

    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        if let cacheURL { self.cacheURL = cacheURL } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Astrolabio", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.cacheURL = base.appendingPathComponent("CometEls.txt")
        }
        loadCache()
    }

    private func loadCache() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let size = attrs[.size] as? Int, size <= Comets.maxBytes,
              let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return }
        orbits = Comets.parse(text)
        updated = attrs[.modificationDate] as? Date
    }

    /// Descarga las órbitas si la copia tiene más de un día.
    func refreshIfNeeded() async {
        if let u = updated, Date().timeIntervalSince(u) < 86400, !orbits.isEmpty { return }
        var req = URLRequest(url: Self.source)
        req.timeoutInterval = 30
        req.setValue("Astrolabio/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= Comets.maxBytes,
                  let text = String(data: data, encoding: .utf8) else {
                error = tr("No se pudieron descargar las órbitas de los cometas.")
                return
            }
            let parsed = Comets.parse(text)
            // Un archivo sin cometas válidos no sustituye a la copia buena.
            guard parsed.count >= 10 else { error = tr("No se pudieron descargar las órbitas de los cometas."); return }
            try? data.write(to: cacheURL, options: .atomic)
            orbits = parsed
            updated = Date()
            error = nil
        } catch {
            self.error = tr("No se pudieron descargar las órbitas de los cometas.")
        }
    }

    func orbit(named name: String) -> CometOrbit? { orbits.first { $0.name == name } }
}
