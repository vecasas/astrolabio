import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Tiempo en un momento de la sesión.
struct WeatherSnapshot: Codable, Hashable {
    var cloudCover: Double
    var temperature: Double
    var dewPoint: Double
    var humidity: Double
    var wind: Double
}

/// Una sesión de apilado registrada por Astrolabio. Los campos opcionales se añadieron en la
/// versión 1.1 para los informes; los registros antiguos o importados no los tienen.
struct ObservationRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var target: String
    var start: Date
    var end: Date
    var frames: Int
    var exposureMs: Int

    var raJ2000: Double?
    var decJ2000: Double?
    var gain: Int?
    var lpFilter: Bool?
    var dropped: Int?
    var ditherEnabled: Bool?
    var ditherPixels: Int?
    var ditherInterval: Int?
    var focusPosition: Int?
    var altitudeStart: Double?
    var altitudeEnd: Double?
    var batteryStart: Int?
    var batteryEnd: Int?
    var temperature: Double?
    var firmware: String?
    var device: String?
    var siteName: String?
    var latitude: Double?
    var longitude: Double?
    var weather: WeatherSnapshot?
    var events: [String]?
    var imageFile: String?
    var albumThumb: String?
    var imported: Bool?

    var integrationMinutes: Double { Double(frames * exposureMs) / 60_000 }

    /// Noche a la que pertenece (fecha del atardecer: de mediodía a mediodía).
    var nightDate: Date { Calendar.current.startOfDay(for: start.addingTimeInterval(-12 * 3600)) }

    var kind: ObjectKind? { Catalog.find(target)?.kind }

    /// Coordenadas: las guardadas o, si no hay, las del catálogo.
    var coordinates: (ra: Double, dec: Double)? {
        if let raJ2000, let decJ2000 { return (raJ2000, decJ2000) }
        return Catalog.find(target).map { ($0.raHours, $0.decDeg) }
    }

    /// Imagen guardada del apilado (en Application Support/Astrolabio/reports).
    var imageURL: URL? { imageFile.map { ObservationLog.reportsFolder.appendingPathComponent($0) } }
}

/// Lo que el resto de la app aporta al empezar y al cerrar una sesión.
struct SessionContext {
    var siteName: String
    var latitude: Double
    var longitude: Double
    var gain: Int
    var weather: WeatherSnapshot?
    var image: () -> CGImage?
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
    /// Datos del lugar, el tiempo y la imagen en directo (lo pone la app al arrancar).
    var contextProvider: () -> SessionContext? = { nil }

    nonisolated static var reportsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio/reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

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
                if let d = event.data.int("dropped_frame") { cur.dropped = d }
                if let b = client?.battery { cur.batteryEnd = b }
                current = cur
            } else {
                closeCurrent()
                let exp = client?.stackExposureMs ?? exposureProvider()
                var rec = ObservationRecord(target: name, start: now.addingTimeInterval(-Double(frames * exp) / 1000),
                                            end: now, frames: frames, exposureMs: exp)
                rec.dropped = event.data.int("dropped_frame")
                fillContext(&rec)
                current = rec
            }
            lastUpdate = now
        }
        if ["complete", "cancel", "fail"].contains(state) { closeCurrent() }
    }

    /// Completa un registro nuevo con lo que se sabe del telescopio, el lugar y el tiempo.
    private func fillContext(_ rec: inout ObservationRecord) {
        if let c = client {
            rec.gain = c.currentGain
            rec.lpFilter = c.viewLPFilter
            rec.focusPosition = c.focuserPosition
            rec.batteryStart = c.battery
            rec.batteryEnd = c.battery
            rec.temperature = c.temperature
            rec.firmware = c.firmwareString.isEmpty ? nil : c.firmwareString
            rec.device = c.deviceName.isEmpty ? nil : c.deviceName
            if let d = c.ditherSetting { rec.ditherEnabled = d.enabled; rec.ditherPixels = d.pixels; rec.ditherInterval = d.interval }
            if let ra = c.viewTargetRA, let dec = c.viewTargetDec {
                // El telescopio da coordenadas de la fecha; se guardan tal cual (la diferencia con J2000 es de minutos de arco).
                rec.raJ2000 = ra; rec.decJ2000 = dec
            }
        }
        if rec.raJ2000 == nil, let o = Catalog.find(rec.target) { rec.raJ2000 = o.raHours; rec.decJ2000 = o.decDeg }
        if let ctx = contextProvider() {
            rec.siteName = ctx.siteName
            rec.latitude = ctx.latitude
            rec.longitude = ctx.longitude
            if rec.gain == nil { rec.gain = ctx.gain }
            rec.weather = ctx.weather
            if let co = rec.coordinates {
                let now = Astro.precessFromJ2000(raHours: co.ra, decDeg: co.dec, to: Date())
                rec.altitudeStart = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: Date(), lat: ctx.latitude, lon: ctx.longitude).alt
            }
        }
    }

    func closeCurrent() {
        guard var cur = current else { return }
        current = nil
        guard cur.frames >= 3 else { return }
        if let ctx = contextProvider() {
            if let co = cur.coordinates {
                let now = Astro.precessFromJ2000(raHours: co.ra, decDeg: co.dec, to: cur.end)
                cur.altitudeEnd = Astro.altAz(raHours: now.ra, decDeg: now.dec, date: cur.end, lat: ctx.latitude, lon: ctx.longitude).alt
            }
            if let img = ctx.image() { cur.imageFile = saveImage(img, id: cur.id) }
        }
        if let c = client {
            cur.batteryEnd = c.battery ?? cur.batteryEnd
            // Avisos y errores del registro durante la sesión (sin el tráfico de red).
            let evs = c.log.filter { $0.date >= cur.start.addingTimeInterval(-120) && $0.date <= Date() && $0.level != .traffic }
            cur.events = evs.suffix(60).map { "\($0.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Loc.shared.locale)))  \($0.text)" }
        }
        records.append(cur)
        save()
    }

    /// Guarda una copia JPEG de la imagen apilada para el informe.
    private func saveImage(_ img: CGImage, id: UUID) -> String? {
        let name = "\(id.uuidString).jpg"
        let url = Self.reportsFolder.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? name : nil
    }

    /// Actualiza un registro ya guardado (por ejemplo, al completar el tiempo de una sesión antigua).
    func update(_ rec: ObservationRecord) {
        guard let i = records.firstIndex(where: { $0.id == rec.id }) else { return }
        records[i] = rec
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
                var rec = ObservationRecord(target: target, start: start, end: end, frames: frames, exposureMs: expMs)
                rec.imported = true
                rec.albumThumb = albumBase(reply).map { "\($0)/\(thn)" }
                rec.lpFilter = name.contains("_LP_")
                if let o = Catalog.find(target) { rec.raJ2000 = o.raHours; rec.decJ2000 = o.decDeg }
                records.append(rec)
                added += 1
            }
        }
        if added > 0 {
            records.sort { $0.start < $1.start }
            save()
        }
        return added
    }

    /// Ruta base de las imágenes del álbum (http://IP/MyWorks).
    private func albumBase(_ reply: JSONObject) -> String? {
        guard let host = client?.host, !host.isEmpty else { return nil }
        let path = (reply.value(at: "result.path") as? String) ?? "MyWorks"
        return "http://\(host)/\(path)"
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
