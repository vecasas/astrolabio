import Foundation
import Network

struct SeestarEvent {
    let name: String
    let data: JSONObject
    let received: Date

    var state: String? { data["state"] as? String }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return tr("Desconectado")
        case .connecting: return tr("Conectando…")
        case .connected: return tr("Conectado")
        case .failed(let m): return tr("Error: %@", "\(m)")
        }
    }
}

enum SeestarError: LocalizedError {
    case notConnected
    case timeout(String)
    case device(String, Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return tr("No hay conexión con el telescopio.")
        case .timeout(let m): return tr("El telescopio no respondió a %@.", "\(m)")
        case .device(let m, let c): return tr("El telescopio devolvió un error (%@): %@", "\(c)", "\(m)")
        case .transport(let m): return tr("Error de red: %@", "\(m)")
        }
    }
}

struct LogEntry: Identifiable {
    enum Level { case info, warning, error, traffic }
    let id = UUID()
    let date = Date()
    let level: Level
    let text: String
}

/// Conexión de control con el Seestar: JSON por TCP en el puerto 4700, un mensaje por línea
/// terminado en "\r\n". Las respuestas llevan el mismo `id` que la petición y los avisos del
/// telescopio llegan como objetos con la clave `Event`.
@MainActor
final class SeestarClient: ObservableObject {
    static let controlPort: UInt16 = 4700

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var host = ""
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authMessage = ""
    @Published private(set) var firmwareVersion = 0
    @Published private(set) var firmwareString = ""
    @Published private(set) var deviceName = ""
    @Published private(set) var ra: Double?       // horas, coordenadas del día
    @Published private(set) var dec: Double?      // grados
    @Published private(set) var battery: Int?
    @Published private(set) var chargerStatus: String?
    @Published private(set) var temperature: Double?
    @Published private(set) var freeStorageMB: Double?
    @Published private(set) var isEQMode = false
    @Published private(set) var focuserPosition: Int?
    @Published private(set) var stackedFrames = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var currentView: String = ""
    /// Ajustes reales del telescopio (se leen con get_setting / get_view_state).
    @Published private(set) var stackExposureMs: Int?
    @Published private(set) var gainRange: ClosedRange<Int>?
    @Published private(set) var currentGain: Int?
    @Published private(set) var ditherSetting: (enabled: Bool, pixels: Int, interval: Int)?
    @Published private(set) var autoFocusBeforeStackSetting: Bool?
    @Published private(set) var viewTarget: String?
    @Published private(set) var stackState: String?
    @Published private(set) var viewLPFilter: Bool?
    @Published private(set) var viewTargetRA: Double?
    @Published private(set) var viewTargetDec: Double?
    @Published private(set) var lastEvents: [String: SeestarEvent] = [:]
    @Published var log: [LogEntry] = []
    @Published var logTraffic = false

    /// La app le da aquí el firmador cuando hay una clave PEM configurada.
    var signerProvider: @MainActor () -> SeestarSigner? = { nil }

    private var connection: NWConnection?
    private var buffer = Data()
    private var nextId = 10000
    private var pending: [Int: (String, CheckedContinuation<JSONObject, Error>)] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var listeners: [UUID: @MainActor (SeestarEvent) -> Void] = [:]
    private var userRequestedDisconnect = false
    private var reconnectTask: Task<Void, Never>?

    var isConnected: Bool { status == .connected }

    // MARK: - Registro

    func addLog(_ text: String, _ level: LogEntry.Level = .info) {
        if level == .traffic && !logTraffic { return }
        log.append(LogEntry(level: level, text: text))
        if log.count > 1500 { log.removeFirst(log.count - 1500) }
    }

    // MARK: - Conexión

    func connect(to host: String) async {
        userRequestedDisconnect = false
        reconnectTask?.cancel()
        closeSocket()
        self.host = host
        status = .connecting
        addLog(tr("Conectando con %@:%@…", "\(host)", "\(Self.controlPort)"))

        guard let port = NWEndpoint.Port(rawValue: Self.controlPort) else { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.noDelay = true
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        connection = conn

        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        if once.fire() { cont.resume(returning: true) }
                    case .failed(let error):
                        if once.fire() { cont.resume(returning: false) }
                        else { self?.handleDrop(error.localizedDescription) }
                    case .waiting(let error):
                        if once.fire() {
                            self?.addLog(tr("No se puede llegar al telescopio: %@", "\(error.localizedDescription)"), .error)
                            cont.resume(returning: false)
                        }
                    case .cancelled:
                        if once.fire() { cont.resume(returning: false) }
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .main)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if once.fire() { cont.resume(returning: false) }
            }
        }

        guard ready, connection === conn else {
            if connection === conn {
                closeSocket()
                status = .failed(tr("no se pudo conectar con %@", "\(host)"))
            }
            return
        }

        status = .connected
        addLog(tr("Conectado a %@.", "\(host)"))
        receiveNext()
        await afterConnect()
        startHeartbeat()
    }

    func disconnect() {
        userRequestedDisconnect = true
        reconnectTask?.cancel()
        closeSocket()
        status = .disconnected
        addLog(tr("Desconectado."))
    }

    private func closeSocket() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        isAuthenticated = false
        for (_, entry) in pending { entry.1.resume(throwing: SeestarError.notConnected) }
        pending.removeAll()
    }

    private func handleDrop(_ reason: String) {
        guard connection != nil else { return }
        addLog(tr("Conexión perdida: %@", "\(reason)"), .warning)
        closeSocket()
        status = .failed(reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !userRequestedDisconnect, !host.isEmpty else { return }
        reconnectTask?.cancel()
        let target = host
        reconnectTask = Task { @MainActor [weak self] in
            var delay = 3.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !self.userRequestedDisconnect else { return }
                if self.isConnected { return }
                self.addLog(tr("Reintentando la conexión…"))
                await self.connect(to: target)
                if self.isConnected { return }
                delay = min(delay * 2, 60)
            }
        }
    }

    private func afterConnect() async {
        if let signer = signerProvider() {
            await authenticate(with: signer)
        } else {
            authMessage = tr("Sin clave PEM: con firmware reciente el telescopio puede ignorar las órdenes.")
            addLog(authMessage, .warning)
        }
        await refreshDeviceState()
    }

    // MARK: - Autenticación

    func authenticate(with signer: SeestarSigner) async {
        do {
            let challenge = try await send("get_verify_str", timeout: 10)
            guard let text = challenge.string("result.str"), !text.isEmpty else {
                authMessage = tr("El telescopio no envió el reto de autenticación (¿está ocupado?).")
                addLog(authMessage, .warning)
                return
            }
            let signature = try signer.sign(text)
            let reply = try await send("verify_client", params: ["sign": signature, "data": text], timeout: 10)
            let code = reply.int("code") ?? -1
            let resultInt = reply.int("result")
            let hasEnvelope = (reply["result"] as? JSONObject)?["key_envelope"] != nil
            if code == 0 && (resultInt == 0 || hasEnvelope || reply["result"] == nil) {
                isAuthenticated = true
                authMessage = "Autenticado."
                addLog(tr("Autenticación correcta."))
            } else {
                authMessage = tr("El telescopio rechazó la clave (código %@).", "\(code)")
                addLog(authMessage, .error)
            }
        } catch {
            authMessage = tr("Fallo de autenticación: %@", "\(error.localizedDescription)")
            addLog(authMessage, .error)
        }
    }

    // MARK: - Lectura

    private func receiveNext() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if let error {
                    self.handleDrop(error.localizedDescription)
                    return
                }
                if isComplete {
                    self.handleDrop(tr("el telescopio cerró la conexión"))
                    return
                }
                self.receiveNext()
            }
        }
    }

    private func processBuffer() {
        let separator = Data([0x0D, 0x0A])
        while let range = buffer.range(of: separator) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !lineData.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: lineData)) as? JSONObject else { continue }
            handleMessage(object)
        }
        if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
    }

    private func handleMessage(_ msg: JSONObject) {
        if let name = msg["Event"] as? String {
            let event = SeestarEvent(name: name, data: msg, received: Date())
            lastEvents[name] = event
            applyEvent(event)
            for listener in listeners.values { listener(event) }
            if logTraffic { addLog("← \(JSONText.encode(msg))", .traffic) }
            return
        }

        if logTraffic { addLog("← \(JSONText.encode(msg))", .traffic) }

        if let method = msg["method"] as? String, method == "scope_get_equ_coord" {
            if let r = msg.double("result.ra"), let d = msg.double("result.dec") {
                ra = r
                dec = d
            }
        }
        if let id = msg.int("id"), let entry = pending.removeValue(forKey: id) {
            if let err = msg["error"] {
                let text = (err as? String) ?? JSONText.encode(err)
                entry.1.resume(throwing: SeestarError.device(text, msg.int("code") ?? -1))
            } else {
                entry.1.resume(returning: msg)
            }
        }
    }

    private func applyEvent(_ event: SeestarEvent) {
        let d = event.data
        switch event.name {
        case "Stack":
            if let s = d.int("stacked_frame") { stackedFrames = s }
            if let s = d.int("dropped_frame") { droppedFrames = s }
        case "PiStatus":
            if let b = d.int("battery_capacity") { battery = b }
            if let t = d.double("temp") { temperature = t }
            if let c = d.string("charger_status") { chargerStatus = c }
        case "View":
            if let mode = d.string("mode") { currentView = mode }
        case "FocuserMove":
            if let p = d.int("position") { focuserPosition = p }
        default:
            break
        }
    }

    // MARK: - Envío

    func addListener(_ listener: @escaping @MainActor (SeestarEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    @discardableResult
    func send(_ method: String, params: Any? = nil, timeout: Double = 15) async throws -> JSONObject {
        guard let conn = connection, status == .connected else { throw SeestarError.notConnected }
        let id = nextId
        nextId += 1
        var message: JSONObject = ["id": id, "method": method]
        if let params { message["params"] = params }
        message = withVerify(message)
        let line = JSONText.encode(message) + "\r\n"
        if method != "scope_get_equ_coord" { addLog("→ \(line.trimmingCharacters(in: .whitespacesAndNewlines))", .traffic) }

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = (method, cont)
            conn.send(content: Data(line.utf8), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    if let entry = self?.pending.removeValue(forKey: id) {
                        entry.1.resume(throwing: SeestarError.transport(error.localizedDescription))
                    }
                }
            })
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let entry = self?.pending.removeValue(forKey: id) {
                    entry.1.resume(throwing: SeestarError.timeout(entry.0))
                }
            }
        }
    }

    /// Añade el marcador "verify" que esperan algunas versiones del firmware.
    /// - Hasta 2582 no se usa.
    /// - Desde 2706 los parámetros de tipo objeto se envían tal cual.
    /// - Las listas llevan "verify" como último elemento.
    private func withVerify(_ message: JSONObject) -> JSONObject {
        // get_albums con el marcador devuelve una lista vacía (comprobado con firmware de S50 Pro).
        let skip: Set<String> = ["get_verify_str", "verify_client", "pi_is_verified", "get_albums"]
        guard let method = message["method"] as? String, !skip.contains(method) else { return message }
        if firmwareVersion != 0 && firmwareVersion <= 2582 { return message }
        var msg = message
        switch msg["params"] {
        case nil:
            msg["params"] = ["verify"]
        case var dict as JSONObject:
            if firmwareVersion >= 2706 { return msg }
            dict["verify"] = true
            msg["params"] = dict
        case let list as [Any]:
            if let last = list.last as? String, last == "verify" { return msg }
            msg["params"] = list + ["verify"]
        case let other?:
            msg["params"] = [other, "verify"]
        }
        return msg
    }

    // MARK: - Estado periódico

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.isConnected else { return }
                _ = try? await self.send("scope_get_equ_coord", timeout: 8)
                if tick % 10 == 0 { await self.refreshDeviceState() }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshDeviceState() async {
        guard let reply = try? await send("get_device_state", timeout: 15) else { return }
        if let fw = reply.int("result.device.firmware_ver_int") { firmwareVersion = fw }
        if let fs = reply.string("result.device.firmware_ver_string") { firmwareString = fs }
        if let name = reply.string("result.device.name") { deviceName = name }
        if let b = reply.int("result.pi_status.battery_capacity") { battery = b }
        if let t = reply.double("result.pi_status.temp") { temperature = t }
        if let c = reply.string("result.pi_status.charger_status") { chargerStatus = c }
        if let eq = reply.bool("result.mount.equ_mode") { isEQMode = eq }
        if let f = reply.int("result.focuser.step") { focuserPosition = f }
        if let free = reply.double("result.storage.storage_volume.0.freeMB") { freeStorageMB = free }
        if let list = reply.value(at: "result.storage.storage_volume") as? [JSONObject],
           let first = list.first, let free = first.double("freeMB") {
            freeStorageMB = free
        }
        await refreshSettings()
    }

    /// Lee exposición, ganancia, dithering y el objeto en curso del propio telescopio.
    func refreshSettings() async {
        if let s = try? await send("get_setting", timeout: 10) {
            if let e = s.int("result.exp_ms.stack_l") { stackExposureMs = e }
            if let range = s.value(at: "result.isp_range_gain") as? [Any],
               let lo = (range.first as? NSNumber)?.intValue, let hi = (range.last as? NSNumber)?.intValue, hi > lo {
                gainRange = lo...hi
            }
            if let en = s.bool("result.stack_dither.enable") {
                ditherSetting = (en, s.int("result.stack_dither.pix") ?? 50, s.int("result.stack_dither.interval") ?? 10)
            }
            if let af = s.bool("result.auto_af") { autoFocusBeforeStackSetting = af }
        }
        if let v = try? await send("get_view_state", timeout: 10) {
            if let t = v.string("result.View.target_name"), !t.isEmpty { viewTarget = t }
            if let g = v.int("result.View.gain") { currentGain = g }
            stackState = v.string("result.View.Stack.state")
            if let lp = v.bool("result.View.lp_filter") { viewLPFilter = lp }
            if let coords = v.value(at: "result.View.target_ra_dec") as? [Any], coords.count >= 2,
               let ra = (coords[0] as? NSNumber)?.doubleValue, let dec = (coords[1] as? NSNumber)?.doubleValue {
                viewTargetRA = ra; viewTargetDec = dec
            }
            if let f = v.int("result.View.Stack.stacked_frame") { stackedFrames = f }
            if let d = v.int("result.View.Stack.dropped_frame") { droppedFrames = d }
            if let mode = v.string("result.View.mode") { currentView = mode }
        }
    }

    // MARK: - Espera de eventos

    /// Espera a que el evento `name` llegue con un estado final después de `since`.
    /// Devuelve el estado ("complete", "fail", "cancel") o nil si se agota el tiempo.
    func waitForEvent(_ name: String,
                      since: Date,
                      terminal: Set<String> = ["complete", "fail", "cancel"],
                      timeout: Double) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let ev = lastEvents[name], ev.received >= since, let st = ev.state, terminal.contains(st) {
                return st
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}

/// Bandera de un solo uso para no reanudar dos veces una continuación.
final class OnceFlag {
    private var done = false
    func fire() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
