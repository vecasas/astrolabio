import Foundation

/// Avisos meteorológicos oficiales de MeteoAlarm (servicios meteorológicos europeos, AEMET en España).
enum MeteoAlarm {
    /// Países con feed en MeteoAlarm (identificador de la URL).
    static let countries = [
        "austria", "belgium", "bosnia-herzegovina", "bulgaria", "croatia", "cyprus", "czechia", "denmark",
        "estonia", "finland", "france", "germany", "greece", "hungary", "iceland", "ireland", "israel", "italy",
        "latvia", "lithuania", "luxembourg", "malta", "moldova", "montenegro", "netherlands", "north-macedonia",
        "norway", "poland", "portugal", "romania", "serbia", "slovakia", "slovenia", "spain", "sweden",
        "switzerland", "ukraine", "united-kingdom",
    ]

    /// Tamaño máximo aceptado del feed (los reales ocupan unos cientos de KB).
    static let maxBytes = 20 * 1024 * 1024

    static func fetch(country: String) async throws -> [WeatherWarning] {
        guard countries.contains(country),
              let url = URL(string: "https://feeds.meteoalarm.org/api/v1/warnings/feeds-\(country)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes else { return [] }
        return parse(data)
    }

    /// Convierte el JSON de MeteoAlarm en avisos, uno por zona. Ignora lo que no entienda.
    static func parse(_ data: Data) -> [WeatherWarning] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let list = root["warnings"] as? [JSONObject] else { return [] }
        let iso = ISO8601DateFormatter()
        func date(_ s: Any?) -> Date? {
            guard let s = s as? String else { return nil }
            return iso.date(from: s.replacingOccurrences(of: "-00:00", with: "+00:00"))
        }
        var out: [WeatherWarning] = []
        var seen = Set<String>()
        for w in list {
            guard let alert = w["alert"] as? JSONObject, let infos = alert["info"] as? [JSONObject] else { continue }
            // Cada aviso viene en varios idiomas: basta con el primero.
            guard let info = infos.first else { continue }
            var level = 0, type = 0
            for p in (info["parameter"] as? [JSONObject]) ?? [] {
                let name = p["valueName"] as? String, value = p["value"] as? String ?? ""
                let n = Int(value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? 0
                if name == "awareness_level" { level = n }
                if name == "awareness_type" { type = n }
            }
            guard let onset = date(info["onset"]) ?? date(info["effective"]), let expires = date(info["expires"]) else { continue }
            let event = info["event"] as? String ?? ""
            let headline = info["headline"] as? String ?? event
            for a in (info["area"] as? [JSONObject]) ?? [] {
                guard let area = a["areaDesc"] as? String, !area.isEmpty else { continue }
                let warning = WeatherWarning(area: area, event: event, headline: headline, level: level, type: type,
                                             onset: onset, expires: expires)
                if seen.insert(warning.id).inserted { out.append(warning) }
            }
        }
        return out
    }

    /// Zonas que aparecen en el feed, para elegir la propia en Ajustes.
    static func areas(_ warnings: [WeatherWarning]) -> [String] {
        Array(Set(warnings.map(\.area))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Radar de precipitación de RainViewer (gratuito, con atribución).
enum RainRadar {
    struct Frame: Equatable {
        let time: Date
        let path: String
    }

    static func frames() async throws -> (host: String, frames: [Frame]) {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return parse(data)
    }

    static func parse(_ data: Data) -> (host: String, frames: [Frame]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let host = root["host"] as? String, host.hasPrefix("https://"),
              let radar = root["radar"] as? JSONObject else { return ("", []) }
        let past = (radar["past"] as? [JSONObject]) ?? []
        let frames = past.compactMap { f -> Frame? in
            guard let t = (f["time"] as? NSNumber)?.doubleValue, let p = f["path"] as? String,
                  p.hasPrefix("/"), !p.contains("..") else { return nil }
            return Frame(time: Date(timeIntervalSince1970: t), path: p)
        }
        return (host, frames)
    }

    /// Tesela del mapa (proyección web Mercator) que contiene un punto.
    static func tile(lat: Double, lon: Double, zoom: Int) -> (x: Int, y: Int, fx: Double, fy: Double) {
        let n = Double(1 << zoom)
        let x = (lon + 180) / 360 * n
        let latR = max(-85.0511, min(85.0511, lat)) * .pi / 180
        let y = (1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n
        return (Int(x), Int(y), x - floor(x), y - floor(y))
    }

    static func radarURL(host: String, frame: Frame, z: Int, x: Int, y: Int) -> URL? {
        URL(string: "\(host)\(frame.path)/256/\(z)/\(x)/\(y)/2/1_1.png")
    }

    static func baseURL(z: Int, x: Int, y: Int) -> URL? {
        URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")
    }
}
