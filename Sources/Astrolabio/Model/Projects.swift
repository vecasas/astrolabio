import Foundation

/// Proyecto de varias noches: acumular horas sobre un objeto (por ejemplo, 10 h en M31).
struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var objectID: String
    var goalHours: Double
    var created = Date()
}

/// Avance de un proyecto calculado con el historial de sesiones.
struct ProjectProgress: Equatable {
    let hours: Double
    let nights: Int
    let last: Date?

    func fraction(of goal: Double) -> Double { goal > 0 ? min(1, hours / goal) : 0 }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] { didSet { save() } }
    private let url: URL

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astrolabio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("projects.json")
    }

    init(url: URL = ProjectStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Project].self, from: data) {
            projects = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) { try? data.write(to: url, options: .atomic) }
    }

    /// Horas, noches y última sesión de un objeto según el historial (incluido lo importado del álbum).
    static func progress(of objectID: String, in records: [ObservationRecord]) -> ProjectProgress {
        let key = Catalog.normalize(objectID)
        let mine = records.filter { r in
            if let o = Catalog.find(r.target) { return Catalog.normalize(o.id) == key }
            return Catalog.normalize(r.target) == key
        }
        let hours = mine.reduce(0) { $0 + $1.integrationMinutes } / 60
        return ProjectProgress(hours: hours, nights: Set(mine.map(\.nightDate)).count, last: mine.map(\.end).max())
    }

    /// Minutos que conviene poner en el plan de esta noche: lo que falta, como mucho 2 horas.
    static func minutesForTonight(goalHours: Double, doneHours: Double) -> Double {
        max(0, min(120, (goalHours - doneHours) * 60)).rounded()
    }
}

// MARK: - Copia de seguridad

/// Copia de seguridad en un único archivo JSON: ajustes, horizontes, plan, proyectos e historial.
/// Nunca incluye la clave PEM ni su ruta.
struct BackupFile: Codable {
    static let currentVersion = 1
    static let maxBytes = 50 * 1024 * 1024
    /// Claves de ajustes que nunca se copian.
    static let excludedKeys: Set<String> = ["pemPath"]

    var format = "astrolabio-backup"
    var version = BackupFile.currentVersion
    var created = Date()
    var appVersion = AppInfo.version
    var settings: [String: SettingValue]
    var plan: [PlanItem]
    var projects: [Project]
    var history: [ObservationRecord]

    /// Valor de UserDefaults representable en JSON.
    enum SettingValue: Codable, Equatable {
        case string(String), double(Double), bool(Bool), data(Data)

        init?(_ any: Any) {
            switch any {
            case let s as String: self = .string(s)
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
            case let n as NSNumber: self = .double(n.doubleValue)
            case let d as Data: self = .data(d)
            default: return nil
            }
        }

        var value: Any {
            switch self {
            case .string(let s): return s
            case .double(let d): return d
            case .bool(let b): return b
            case .data(let d): return d
            }
        }
    }

    /// Claves de ajustes de Astrolabio que se guardan.
    static let settingKeys = [
        "siteName", "latitude", "longitude", "telescopeHost", "autoConnect", "minAltitude", "maxCloudCover", "exposureMs",
        "gain", "fovWidthDeg", "fovHeightDeg", "ntfyTopic", "ntfyServer", "saveFolder", "dewHeaterPower", "ditherEnabled",
        "ditherPixels", "ditherInterval", "autoFocusBeforeStack", "nightMode", "nightModeAuto", "nightBrightness",
        "gotoMinAltitude", "sunSafetyDeg", "recenterEnabled", "recenterToleranceArcmin", "healthAlerts", "endAction",
        "darksAtEnd", "focusWatch", "focusThresholdPercent", "autoRefocus", "autoDewHeater", "stormGuard", "alertCountry",
        "alertZone", "horizons", "language",
    ]

    static func make(defaults: UserDefaults, plan: [PlanItem], projects: [Project], history: [ObservationRecord]) -> BackupFile {
        var s: [String: SettingValue] = [:]
        for k in settingKeys where !excludedKeys.contains(k) {
            if let v = defaults.object(forKey: k).flatMap(SettingValue.init) { s[k] = v }
        }
        return BackupFile(settings: s, plan: plan, projects: projects, history: history)
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    enum RestoreError: LocalizedError {
        case tooBig, notABackup, newerVersion
        var errorDescription: String? {
            switch self {
            case .tooBig: return tr("El archivo es demasiado grande para ser una copia de Astrolabio.")
            case .notABackup: return tr("Este archivo no es una copia de seguridad de Astrolabio.")
            case .newerVersion: return tr("La copia es de una versión más nueva de Astrolabio. Actualiza la app primero.")
            }
        }
    }

    static func decode(_ data: Data) throws -> BackupFile {
        guard data.count <= maxBytes else { throw RestoreError.tooBig }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let b = try? dec.decode(BackupFile.self, from: data), b.format == "astrolabio-backup" else { throw RestoreError.notABackup }
        guard b.version <= currentVersion else { throw RestoreError.newerVersion }
        return b
    }

    /// Escribe los ajustes de la copia (solo las claves conocidas y nunca la clave PEM).
    func applySettings(to defaults: UserDefaults) {
        for (k, v) in settings where Self.settingKeys.contains(k) && !Self.excludedKeys.contains(k) {
            defaults.set(v.value, forKey: k)
        }
    }
}
