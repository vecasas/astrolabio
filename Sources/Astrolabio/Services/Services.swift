import Foundation
import UserNotifications

// MARK: - Tiempo (Open-Meteo, gratuito y sin clave)

struct WeatherHour: Identifiable {
    var id: Date { time }
    let time: Date
    let cloudCover: Double      // %
    let lowClouds: Double
    let humidity: Double        // %
    let temperature: Double     // °C
    let dewPoint: Double        // °C
    let wind: Double            // km/h
    var precipitation: Double = 0   // mm
    var gusts: Double = 0           // km/h
    var weatherCode: Int = 0        // WMO (95–99 tormenta)
}

enum WeatherService {
    static func forecast(lat: Double, lon: Double) async throws -> [WeatherHour] {
        try await fetch("https://api.open-meteo.com/v1/forecast", lat: lat, lon: lon, extra: [.init(name: "forecast_days", value: "3")])
    }

    /// Tiempo pasado entre dos fechas: los últimos 90 días salen de la API de previsión
    /// (más precisa) y lo anterior del archivo histórico ERA5 de Open-Meteo.
    static func history(lat: Double, lon: Double, from: Date, to: Date) async throws -> [WeatherHour] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let recent = from > Date().addingTimeInterval(-88 * 86400)
        return try await fetch(recent ? "https://api.open-meteo.com/v1/forecast" : "https://archive-api.open-meteo.com/v1/archive",
                               lat: lat, lon: lon,
                               extra: [.init(name: "start_date", value: f.string(from: from)), .init(name: "end_date", value: f.string(from: to))])
    }

    /// Hora más cercana a una fecha (como mucho a 90 minutos).
    static func nearest(_ date: Date, in hours: [WeatherHour]) -> WeatherHour? {
        hours.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) })
            .flatMap { abs($0.time.timeIntervalSince(date)) < 5400 ? $0 : nil }
    }

    private static func fetch(_ base: String, lat: Double, lon: Double, extra: [URLQueryItem]) async throws -> [WeatherHour] {
        var c = URLComponents(string: base)!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "hourly", value: "cloud_cover,cloud_cover_low,relative_humidity_2m,temperature_2m,dew_point_2m,wind_speed_10m,precipitation,wind_gusts_10m,weather_code"),
            .init(name: "timezone", value: "UTC"),
        ] + extra
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let obj = (try JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let hourly = obj["hourly"] as? JSONObject,
              let times = hourly["time"] as? [String] else { return [] }
        func arr(_ k: String) -> [Double] {
            (hourly[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? []
        }
        let cc = arr("cloud_cover"), low = arr("cloud_cover_low"), rh = arr("relative_humidity_2m")
        let t = arr("temperature_2m"), dp = arr("dew_point_2m"), w = arr("wind_speed_10m")
        let pr = arr("precipitation"), gu = arr("wind_gusts_10m"), wc = arr("weather_code")
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        var out: [WeatherHour] = []
        for (i, s) in times.enumerated() {
            guard let d = fmt.date(from: s) else { continue }
            func g(_ a: [Double]) -> Double { i < a.count ? a[i] : 0 }
            out.append(WeatherHour(time: d, cloudCover: g(cc), lowClouds: g(low), humidity: g(rh),
                                   temperature: g(t), dewPoint: g(dp), wind: g(w),
                                   precipitation: g(pr), gusts: g(gu), weatherCode: Int(g(wc))))
        }
        return out
    }

    static func cloudCover(at date: Date, in hours: [WeatherHour]) -> Double? {
        hours.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) })
            .flatMap { abs($0.time.timeIntervalSince(date)) < 5400 ? $0.cloudCover : nil }
    }
}

// MARK: - Avisos (notificación del Mac y, si se configura, al móvil con ntfy)

enum Notifier {
    /// Muestra una notificación del sistema. Dentro de Astrolabio.app usa el centro de
    /// notificaciones (con el nombre y el icono de la app); con `swift run`, sin paquete,
    /// recurre a osascript.
    static func local(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            localViaScript(title, body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { localViaScript(title, body); return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func localViaScript(_ title: String, _ body: String) {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Envía el aviso al tema de ntfy configurado (app gratuita para iPhone y Android).
    static func phone(topic: String, server: String, title: String, body: String) async {
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + t) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("telescope", forHTTPHeaderField: "Tags")
        req.httpBody = Data(body.utf8)
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Búsqueda de objetos por nombre (Sesame, CDS Estrasburgo)

enum NameResolver {
    /// Devuelve RA (horas) y Dec (grados) J2000 de cualquier objeto que conozca SIMBAD/NED/VizieR.
    static func resolve(_ name: String) async throws -> (ra: Double, dec: Double)? {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://cds.unistra.fr/cgi-bin/nph-sesame/-oI/SNV?\(enc)") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("%J ") {
            let parts = line.dropFirst(3).split(separator: " ").compactMap { Double($0) }
            if parts.count >= 2 { return (parts[0] / 15, parts[1]) }
        }
        return nil
    }
}
