import Foundation

/// Una sesión de apilado registrada por Astrolabio.
struct ObservationRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var target: String
    var start: Date
    var end: Date
    var frames: Int
    var exposureMs: Int

    var integrationMinutes: Double { Double(frames * exposureMs) / 60_000 }

    /// Noche a la que pertenece (fecha del atardecer: de mediodía a mediodía).
    var nightDate: Date { Calendar.current.startOfDay(for: start.addingTimeInterval(-12 * 3600)) }

    var kind: ObjectKind? { Catalog.find(target)?.kind }
}

/// Historial de observación: escucha los eventos de apilado del Seestar y guarda cada sesión
/// en Application Support/Astrolabio/history.json. Es la base de las estadísticas.
@MainActor
final class ObservationLog: ObservableObject {
    @Published private(set) var records: [ObservationRecord] = []
    @Published private(set) var current: ObservationRecord?

    private var listenerID: UUID?
    private var watchdog: Task<Void, Never>?
    private var lastUpdate = Date.distantPast
    private weak var client: SeestarClient?
    private var exposureProvider: () -> Int = { 10_000 }

    private let storage: URL?

    private var url: URL {
        if let storage { return storage }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    /// `storage` permite usar otro archivo (por ejemplo, en las pruebas).
    init(storage: URL? = nil) {
        self.storage = storage
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let list = try? dec.decode([ObservationRecord].self, from: data) {
            records = list
        }
    }

    func attach(to client: SeestarClient, exposureMs: @escaping () -> Int) {
        self.client = client
        exposureProvider = exposureMs
        if let id = listenerID { client.removeListener(id) }
        listenerID = client.addListener { [weak self] event in
            guard event.name == "Stack" else { return }
            self?.handleStack(event)
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                // Sin noticias del apilado en 15 minutos: la sesión se da por terminada.
                if self.current != nil && Date().timeIntervalSince(self.lastUpdate) > 900 { self.closeCurrent() }
            }
        }
    }

    private func targetName(_ event: SeestarEvent) -> String {
        let candidates: [Any?] = [event.data["target_name"], client?.viewTarget,
                                  client?.lastEvents["AutoGoto"]?.data["target_name"],
                                  client?.lastEvents["Stack"]?.data["target_name"]]
        for c in candidates { if let s = c as? String, !s.isEmpty { return s } }
        return tr("Sin nombre")
    }

    func handleStack(_ event: SeestarEvent, now: Date = Date()) {
        let state = event.state ?? ""
        if let frames = event.data.int("stacked_frame") {
            let name = targetName(event)
            if var cur = current, cur.target == name, frames >= cur.frames {
                cur.frames = frames
                cur.end = now
                current = cur
            } else {
                closeCurrent()
                let exp = client?.stackExposureMs ?? exposureProvider()
                current = ObservationRecord(target: name, start: now.addingTimeInterval(-Double(frames * exp) / 1000),
                                            end: now, frames: frames, exposureMs: exp)
            }
            lastUpdate = now
        }
        if ["complete", "cancel", "fail"].contains(state) { closeCurrent() }
    }

    func closeCurrent() {
        guard let cur = current else { return }
        current = nil
        guard cur.frames >= 3 else { return }
        records.append(cur)
        save()
    }

    func delete(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    /// Añade un registro a mano (por ejemplo, de una sesión hecha con otra app).
    func add(_ r: ObservationRecord) {
        records.append(r)
        records.sort { $0.start < $1.start }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    /// Todas las sesiones, incluida la que está en curso.
    var allRecords: [ObservationRecord] { records + (current.map { [$0] } ?? []) }

    /// Importa las sesiones que el Seestar guarda en su álbum. Los nombres de las imágenes
    /// apiladas llevan los fotogramas, la exposición y la fecha, p. ej.
    /// «Stacked_25_M 45_30.0s_IRCUT_20261030-234613». Devuelve cuántas sesiones nuevas añade.
    @discardableResult
    func importFromAlbum(_ reply: JSONObject) -> Int {
        guard let groups = reply.value(at: "result.list") as? [JSONObject] else { return 0 }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let regex = try! NSRegularExpression(pattern: #"Stacked_(\d+)_(?:mosaic_)?(.+?)_(\d+(?:\.\d+)?)s_[A-Za-z0-9]+_(\d{8}-\d{6})"#)
        var added = 0
        for g in groups {
            for f in (g["files"] as? [JSONObject]) ?? [] {
                guard let thn = f["thn"] as? String else { continue }
                let name = (thn as NSString).lastPathComponent
                let ns = name as NSString
                guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                      let frames = Int(ns.substring(with: m.range(at: 1))),
                      let exp = Double(ns.substring(with: m.range(at: 3))),
                      let end = fmt.date(from: ns.substring(with: m.range(at: 4))) else { continue }
                let target = ns.substring(with: m.range(at: 2))
                let expMs = Int(exp * 1000)
                let start = end.addingTimeInterval(-Double(frames * expMs) / 1000)
                let duplicate = records.contains {
                    Catalog.normalize($0.target) == Catalog.normalize(target) && abs($0.end.timeIntervalSince(end)) < 1800
                }
                if duplicate || frames < 1 { continue }
                records.append(ObservationRecord(target: target, start: start, end: end, frames: frames, exposureMs: expMs))
                added += 1
            }
        }
        if added > 0 {
            records.sort { $0.start < $1.start }
            save()
        }
        return added
    }

    func csv() -> String {
        let f = ISO8601DateFormatter()
        var out = "objeto,inicio,fin,fotogramas,exposicion_ms,minutos\n"
        for r in allRecords {
            out += "\"\(r.target)\",\(f.string(from: r.start)),\(f.string(from: r.end)),\(r.frames),\(r.exposureMs),\(String(format: "%.1f", r.integrationMinutes))\n"
        }
        return out
    }
}
