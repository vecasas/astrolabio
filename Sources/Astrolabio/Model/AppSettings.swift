import Foundation

/// Ajustes persistentes de la app (se guardan en UserDefaults).
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var siteName: String { didSet { d.set(siteName, forKey: "siteName") } }
    @Published var latitude: Double { didSet { d.set(latitude, forKey: "latitude") } }
    @Published var longitude: Double { didSet { d.set(longitude, forKey: "longitude") } }
    @Published var telescopeHost: String { didSet { d.set(telescopeHost, forKey: "telescopeHost") } }
    @Published var autoConnect: Bool { didSet { d.set(autoConnect, forKey: "autoConnect") } }
    @Published var pemPath: String { didSet { d.set(pemPath, forKey: "pemPath") } }
    @Published var minAltitude: Double { didSet { d.set(minAltitude, forKey: "minAltitude") } }
    @Published var maxCloudCover: Double { didSet { d.set(maxCloudCover, forKey: "maxCloudCover") } }
    @Published var exposureMs: Int { didSet { d.set(exposureMs, forKey: "exposureMs") } }
    @Published var gain: Int { didSet { d.set(gain, forKey: "gain") } }
    @Published var fovWidthDeg: Double { didSet { d.set(fovWidthDeg, forKey: "fovWidthDeg") } }
    @Published var fovHeightDeg: Double { didSet { d.set(fovHeightDeg, forKey: "fovHeightDeg") } }
    @Published var ntfyTopic: String { didSet { d.set(ntfyTopic, forKey: "ntfyTopic") } }
    @Published var ntfyServer: String { didSet { d.set(ntfyServer, forKey: "ntfyServer") } }
    @Published var saveFolder: String { didSet { d.set(saveFolder, forKey: "saveFolder") } }
    @Published var dewHeaterPower: Int { didSet { d.set(dewHeaterPower, forKey: "dewHeaterPower") } }
    @Published var ditherEnabled: Bool { didSet { d.set(ditherEnabled, forKey: "ditherEnabled") } }
    @Published var ditherPixels: Int { didSet { d.set(ditherPixels, forKey: "ditherPixels") } }
    @Published var ditherInterval: Int { didSet { d.set(ditherInterval, forKey: "ditherInterval") } }
    @Published var autoFocusBeforeStack: Bool { didSet { d.set(autoFocusBeforeStack, forKey: "autoFocusBeforeStack") } }
    /// Seguridad del apuntado y recentrado tras el GoTo.
    @Published var gotoMinAltitude: Double { didSet { d.set(gotoMinAltitude, forKey: "gotoMinAltitude") } }
    @Published var sunSafetyDeg: Double { didSet { d.set(max(GotoSafety.sunSeparationFloor, sunSafetyDeg), forKey: "sunSafetyDeg") } }
    @Published var recenterEnabled: Bool { didSet { d.set(recenterEnabled, forKey: "recenterEnabled") } }
    @Published var recenterToleranceArcmin: Double { didSet { d.set(recenterToleranceArcmin, forKey: "recenterToleranceArcmin") } }
    /// Avisos de batería baja, telescopio sin respuesta y memoria llena.
    @Published var healthAlerts: Bool { didSet { d.set(healthAlerts, forKey: "healthAlerts") } }
    /// Al terminar el plan.
    @Published var endAction: EndAction { didSet { d.set(endAction.rawValue, forKey: "endAction") } }
    @Published var darksAtEnd: Bool { didSet { d.set(darksAtEnd, forKey: "darksAtEnd") } }

    var gotoLimits: GotoSafety.Limits {
        GotoSafety.Limits(latitude: latitude, longitude: longitude, minAltitude: gotoMinAltitude,
                          minSunSeparation: max(GotoSafety.sunSeparationFloor, sunSafetyDeg))
    }
    /// Modo nocturno manual, automático al anochecer y brillo (0,3–1).
    @Published var nightMode: Bool { didSet { d.set(nightMode, forKey: "nightMode"); nightOverride = nil } }
    @Published var nightModeAuto: Bool { didSet { d.set(nightModeAuto, forKey: "nightModeAuto") } }
    @Published var nightBrightness: Double { didSet { d.set(nightBrightness, forKey: "nightBrightness") } }
    /// Se activa sola si `nightModeAuto` y el Sol está por debajo de −6°.
    @Published private(set) var autoNightNow = false
    private var nightOverride: Bool?
    private var nightTimer: Timer?

    var nightModeActive: Bool { nightMode || (nightModeAuto && autoNightNow && nightOverride != false) }

    init() {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        siteName = d.string(forKey: "siteName") ?? tr("Mi observatorio")
        latitude = dbl("latitude", 40.4818)
        longitude = dbl("longitude", -3.3643)
        telescopeHost = d.string(forKey: "telescopeHost") ?? "192.168.0.37"
        autoConnect = d.object(forKey: "autoConnect") == nil ? false : d.bool(forKey: "autoConnect")
        pemPath = d.string(forKey: "pemPath") ?? ""
        minAltitude = dbl("minAltitude", 30)
        maxCloudCover = dbl("maxCloudCover", 60)
        exposureMs = int("exposureMs", 10_000)
        gain = int("gain", 80)
        fovWidthDeg = dbl("fovWidthDeg", 0.73)
        fovHeightDeg = dbl("fovHeightDeg", 1.29)
        ntfyTopic = d.string(forKey: "ntfyTopic") ?? ""
        ntfyServer = d.string(forKey: "ntfyServer") ?? "https://ntfy.sh"
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Astrolabio").path ?? NSHomeDirectory() + "/Pictures/Astrolabio"
        saveFolder = d.string(forKey: "saveFolder") ?? pics
        dewHeaterPower = int("dewHeaterPower", 0)
        ditherEnabled = d.object(forKey: "ditherEnabled") == nil ? true : d.bool(forKey: "ditherEnabled")
        ditherPixels = int("ditherPixels", 50)
        ditherInterval = int("ditherInterval", 10)
        autoFocusBeforeStack = d.object(forKey: "autoFocusBeforeStack") == nil ? false : d.bool(forKey: "autoFocusBeforeStack")
        gotoMinAltitude = dbl("gotoMinAltitude", 15)
        sunSafetyDeg = max(GotoSafety.sunSeparationFloor, dbl("sunSafetyDeg", 30))
        recenterEnabled = d.object(forKey: "recenterEnabled") == nil ? true : d.bool(forKey: "recenterEnabled")
        recenterToleranceArcmin = dbl("recenterToleranceArcmin", 2)
        healthAlerts = d.object(forKey: "healthAlerts") == nil ? true : d.bool(forKey: "healthAlerts")
        endAction = d.string(forKey: "endAction").flatMap(EndAction.init(rawValue:)) ?? .park
        darksAtEnd = d.bool(forKey: "darksAtEnd")
        nightMode = d.bool(forKey: "nightMode")
        nightModeAuto = d.bool(forKey: "nightModeAuto")
        nightBrightness = dbl("nightBrightness", 0.7)
        updateAutoNight()
        nightTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAutoNight() }
        }
    }

    func updateAutoNight() {
        let night = Astro.sunAltitude(Date(), lat: latitude, lon: longitude) < -6
        if night != autoNightNow { autoNightNow = night }
    }

    /// Botón o atajo: si el modo automático lo tiene encendido, apagarlo solo por esta noche.
    func toggleNightMode() {
        if nightModeActive && !nightMode { nightOverride = false; objectWillChange.send() }
        else { nightMode.toggle() }
    }

    var saveFolderURL: URL {
        let url = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeSigner() -> SeestarSigner? {
        let path = (pemPath as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        return try? SeestarSigner(pemURL: URL(fileURLWithPath: path))
    }

    func notify(_ title: String, _ body: String) {
        Notifier.local(title, body)
        let topic = ntfyTopic, server = ntfyServer
        Task { await Notifier.phone(topic: topic, server: server, title: title, body: body) }
    }
}
