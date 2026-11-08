import Foundation

/// Elementos orbitales de CelesTrak (estaciones espaciales y los ~150 satélites más brillantes).
/// Se descargan por HTTPS como mucho una vez al día, con límite de tamaño, y se guardan en caché.
@MainActor
final class SatelliteStore: ObservableObject {
    static let shared = SatelliteStore()
    static let sources = [
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle")!,
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle")!,
    ]
    nonisolated static let maxBytes = 2_000_000

    @Published private(set) var tles: [TLE] = []
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?

    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        if let cacheURL { self.cacheURL = cacheURL } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Astrolabio", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.cacheURL = base.appendingPathComponent("satellites.tle")
        }
        loadCache()
    }

    private func loadCache() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let size = attrs[.size] as? Int, size <= Self.maxBytes * 2,
              let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return }
        tles = Self.merge(TLE.parseList(text))
        updated = attrs[.modificationDate] as? Date
    }

    /// Quita repetidos (la ISS está en los dos grupos) y deja primero las estaciones tripuladas.
    nonisolated static func merge(_ list: [TLE]) -> [TLE] {
        var seen = Set<String>(), out: [TLE] = []
        for t in list where seen.insert(String(t.line1.prefix(7))).inserted { out.append(t) }
        let crewed = ["ISS (ZARYA)", "CSS (TIANHE)", "TIANGONG"]
        return out.sorted { a, b in
            let ia = crewed.firstIndex { a.name.hasPrefix($0) } ?? 99, ib = crewed.firstIndex { b.name.hasPrefix($0) } ?? 99
            return ia != ib ? ia < ib : a.name < b.name
        }
    }

    /// Solo se aceptan respuestas HTTPS de celestrak.org con texto TLE válido.
    nonisolated static func accept(_ data: Data, from url: URL?) -> [TLE]? {
        guard let url, url.scheme == "https", url.host == "celestrak.org", data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let list = TLE.parseList(text)
        return list.isEmpty ? nil : list
    }

    func refreshIfNeeded(force: Bool = false) async {
        if !force, let u = updated, Date().timeIntervalSince(u) < 86400, !tles.isEmpty { return }
        var all: [TLE] = []
        var text = ""
        for src in Self.sources {
            var req = URLRequest(url: src)
            req.timeoutInterval = 30
            req.setValue("Astrolabio/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = Self.accept(data, from: resp.url) else { continue }
            all += list
            text += list.map { "\($0.name)\n\($0.line1)\n\($0.line2)\n" }.joined()
        }
        guard !all.isEmpty else {
            error = tr("No se pudieron descargar las órbitas de los satélites.")
            return
        }
        try? text.data(using: .utf8)?.write(to: cacheURL, options: .atomic)
        tles = Self.merge(all)
        updated = Date()
        error = nil
    }

    /// Satélites que cruzan cerca de un objetivo (J2000) entre dos instantes.
    nonisolated static func crossings(_ tles: [TLE], raHours: Double, decDeg: Double, from: Date, to: Date,
                                      lat: Double, lon: Double, radius: Double = 1.0) -> [(name: String, at: Date, sep: Double)] {
        tles.compactMap { t in
            guard let c = Satellites.closestApproach(t, raHours: raHours, decDeg: decDeg, from: from, to: to, lat: lat, lon: lon),
                  c.sep <= radius, Satellites.sunlitAt(t, c.at) else { return nil }
            return (t.name, c.at, c.sep)
        }.sorted { $0.at < $1.at }
    }
}

extension Satellites {
    /// ¿Está iluminado (y por tanto deja traza) en ese instante?
    static func sunlitAt(_ tle: TLE, _ date: Date) -> Bool {
        guard let s = SGP4(tle), let r = s.position(at: date) else { return false }
        return sunlit(teme: r, date: date)
    }
}
