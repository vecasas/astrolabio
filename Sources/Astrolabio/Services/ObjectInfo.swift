import Foundation

/// Resumen de un objeto sacado de la Wikipedia en español (con caché en disco).
struct ObjectSummary: Codable, Equatable {
    let title: String
    let extract: String
    let url: String?
}

@MainActor
final class ObjectInfoService: ObservableObject {
    static let shared = ObjectInfoService()

    @Published private(set) var summaries: [String: ObjectSummary] = [:]
    private var inFlight = Set<String>()
    private var missing = Set<String>()

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("wikipedia.json")
    }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let m = try? JSONDecoder().decode([String: ObjectSummary].self, from: d) {
            summaries = m
        }
    }

    /// Títulos que se prueban en orden: «M39» → «Messier 39»; «NGC 7000», «IC 5146», «Sh2-155»… y el nombre común.
    static func candidateTitles(for obj: DeepSkyObject) -> [String] {
        var out: [String] = []
        let id = obj.id.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("M"), let n = Int(id.dropFirst().trimmingCharacters(in: .whitespaces)) {
            out.append("Messier \(n)"); out.append("M\(n)")
        }
        out.append(id)
        if !obj.name.isEmpty { out.append(obj.name) }
        return out
    }

    /// Clave de caché: idioma + objeto (cada idioma usa su propia Wikipedia).
    private func key(_ obj: DeepSkyObject) -> String { "\(Loc.shared.language.rawValue):\(obj.id)" }

    func summary(for obj: DeepSkyObject) -> ObjectSummary? { summaries[key(obj)] }
    func isMissing(_ obj: DeepSkyObject) -> Bool { missing.contains(key(obj)) }

    func load(_ obj: DeepSkyObject) async {
        let k = key(obj)
        let domain = Loc.shared.language.wikipedia
        guard summaries[k] == nil, !inFlight.contains(k), !missing.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        var titles = Self.candidateTitles(for: obj)
        // La Wikipedia en chino titula los Messier como «梅西耶32».
        if Loc.shared.language == .zh, obj.id.hasPrefix("M"), let n = Int(obj.id.dropFirst().trimmingCharacters(in: .whitespaces)) {
            titles.insert("梅西耶\(n)", at: 0)
        }
        if !obj.name.isEmpty { titles.append(obj.localizedName) }
        for title in titles {
            guard let enc = title.replacingOccurrences(of: " ", with: "_")
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://\(domain)/api/rest_v1/page/summary/\(enc)?redirect=true") else { continue }
            var req = URLRequest(url: url)
            req.setValue("Astrolabio/1.0 (app de astronomía para macOS)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            if Loc.shared.language == .zh { req.setValue("zh-cn", forHTTPHeaderField: "Accept-Language") }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj2 = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
                  (obj2["type"] as? String) == "standard",
                  let extract = obj2["extract"] as? String, extract.count > 40 else { continue }
            let page = (obj2.value(at: "content_urls.desktop.page") as? String)
            summaries[k] = ObjectSummary(title: (obj2["title"] as? String) ?? title, extract: extract, url: page)
            save()
            return
        }
        missing.insert(k)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(summaries) { try? d.write(to: cacheURL, options: .atomic) }
    }
}
