import Foundation
import Network
import Security
@testable import Astrolabio

/// Seestar simulado para las pruebas: habla el protocolo JSON por TCP en 127.0.0.1 (puerto libre),
/// responde a las órdenes como el telescopio real y emite sus eventos (AutoGoto, Stack, AutoFocus…).
/// Lo que la app le envía queda en `received` para comprobarlo.
final class FakeSeestar: @unchecked Sendable {
    struct Call { let method: String; let params: Any? }

    private let queue = DispatchQueue(label: "fake-seestar")
    private var listener: NWListener!
    private var connection: NWConnection?
    private var buffer = Data()
    private var _received: [Call] = []
    private(set) var port: UInt16 = 0

    // Comportamiento configurable.
    var publicKey: SecKey?                      // si está, comprueba la firma de verify_client
    var pointingOffsetsArcmin: [Double] = []    // desvío en Dec tras cada GoTo (uno por GoTo)
    private var currentOffset = 0.0
    var errors: [String: Int] = [:]             // método → código de error
    var silent: Set<String> = []                // métodos sin respuesta (para probar los tiempos de espera)
    var dropOn: Set<String> = []                // métodos que cierran la conexión
    var gotoResult = "complete"
    var battery = 87
    private var target: (ra: Double, dec: Double)?
    private var stacked = 0

    var received: [Call] { queue.sync { _received } }
    func count(_ method: String) -> Int { received.filter { $0.method == method }.count }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            listener.cancel()
        }
    }

    /// Cierra la conexión actual (como un reinicio del telescopio).
    func dropConnection() { queue.async { self.connection?.cancel(); self.connection = nil } }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        buffer = Data()
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.connection === conn else { return }
            if let data { self.buffer.append(data); self.process() }
            if done || error != nil { return }
            self.receive(conn)
        }
    }

    private func process() {
        let sep = Data([0x0D, 0x0A])
        while let r = buffer.range(of: sep) {
            let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            handle(id: msg["id"] as? Int ?? 0, method: method, params: msg["params"])
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let conn = connection, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        conn.send(content: data + Data([0x0D, 0x0A]), completion: .idempotent)
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        queue.async { self.write(["Event": event, "Timestamp": "1"].merging(fields) { a, _ in a }) }
    }

    private func reply(_ id: Int, _ method: String, _ result: Any = 0) {
        write(["jsonrpc": "2.0", "id": id, "method": method, "result": result, "code": 0])
    }

    private func handle(id: Int, method: String, params: Any?) {
        _received.append(Call(method: method, params: params))
        if dropOn.contains(method) { connection?.cancel(); connection = nil; return }
        if silent.contains(method) { return }
        if let code = errors[method] {
            write(["jsonrpc": "2.0", "id": id, "method": method, "code": code, "error": "fallo simulado"])
            return
        }
        switch method {
        case "get_verify_str":
            reply(id, method, ["str": "reto-de-prueba-123"])
        case "verify_client":
            let p = params as? [String: Any]
            var ok = true
            if let key = publicKey {
                ok = false
                if let sig = (p?["sign"] as? String).flatMap({ Data(base64Encoded: $0) }), let text = p?["data"] as? String {
                    ok = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA1, Data(text.utf8) as CFData, sig as CFData, nil)
                }
            }
            if ok { reply(id, method, 0) }
            else { write(["jsonrpc": "2.0", "id": id, "method": method, "code": 210, "error": "fail to verify"]) }
        case "get_device_state":
            reply(id, method, [
                "device": ["firmware_ver_int": 2706, "firmware_ver_string": "6.45", "name": "Seestar S50 simulado"],
                "pi_status": ["battery_capacity": battery, "temp": 21.5, "charger_status": "Discharging"],
                "mount": ["equ_mode": false], "focuser": ["step": 1600],
                "storage": ["storage_volume": [["freeMB": 12_000]]],
            ])
        case "get_setting":
            reply(id, method, ["exp_ms": ["stack_l": 10_000], "stack_dither": ["pix": 50, "interval": 10, "enable": true], "auto_af": false])
        case "get_view_state":
            reply(id, method, ["View": ["state": "idle", "lp_filter": false, "gain": 80]])
        case "iscope_start_view":
            let p = params as? [String: Any]
            if let rd = p?["target_ra_dec"] as? [Double], rd.count == 2 { target = (rd[0], rd[1]) }
            currentOffset = pointingOffsetsArcmin.isEmpty ? 0 : pointingOffsetsArcmin.removeFirst()
            reply(id, method)
            let name = p?["target_name"] as? String ?? ""
            queue.asyncAfter(deadline: .now() + 0.2) { self.write(["Event": "AutoGoto", "state": "start", "target_name": name]) }
            queue.asyncAfter(deadline: .now() + 0.4) { self.write(["Event": "AutoGoto", "state": self.gotoResult, "target_name": name]) }
        case "scope_get_equ_coord":
            if let t = target {
                reply(id, method, ["ra": t.ra, "dec": t.dec + currentOffset / 60])
            } else {
                reply(id, method, ["ra": 0.0, "dec": 0.0])
            }
        case "iscope_start_stack":
            reply(id, method)
            stacked = 0
            for k in 1...3 {
                queue.asyncAfter(deadline: .now() + Double(k) * 0.3) {
                    self.stacked += 1
                    self.write(["Event": "Stack", "state": "working", "stacked_frame": self.stacked, "dropped_frame": 0])
                }
            }
        case "iscope_stop_view":
            reply(id, method)
            write(["Event": "Stack", "state": "cancel", "stacked_frame": stacked])
        case "start_auto_focuse":
            reply(id, method)
            queue.asyncAfter(deadline: .now() + 0.3) { self.write(["Event": "AutoFocus", "state": "complete"]) }
        case "start_create_dark":
            reply(id, method)
            queue.asyncAfter(deadline: .now() + 0.3) { self.write(["Event": "DarkLibrary", "state": "complete"]) }
        case "get_albums":
            reply(id, method, ["path": "MyWorks", "list": [["group_name": "DeepSky", "files": [
                ["name": "M 42", "thn": "M 42/Stacked_18_M 42_30.0s_LP_20261031-000015_thn.jpg", "count": 1],
            ]]]])
        default:
            reply(id, method)
        }
    }

    // MARK: Claves de prueba

    /// Par de claves RSA nuevo: la privada en PEM (PKCS#1) para la app y la pública para el simulador.
    static func makeKeyPair() throws -> (pem: String, publicKey: SecKey) {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(priv, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return ("-----BEGIN RSA PRIVATE KEY-----\n\(b64)\n-----END RSA PRIVATE KEY-----\n", pub)
    }
}

/// Canal de imagen simulado (puerto 4800): al conectar envía una imagen apilada en un ZIP.
final class FakeImageServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-image")
    private var listener: NWListener!
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    let width: Int, height: Int

    init(width: Int = 64, height: Int = 48) throws {
        self.width = width; self.height = height
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 0.3) { conn.send(content: self.frame(), completion: .idempotent) }
            self.drain(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, error in
            if !done && error == nil { self?.drain(conn) }
        }
    }

    func stop() { queue.sync { connections.forEach { $0.cancel() }; listener.cancel() } }

    /// Cabecera de 80 bytes + ZIP sin comprimir con `raw_data` (RGB de 16 bits).
    func frame() -> Data {
        var raw = Data(count: width * height * 6)
        raw.withUnsafeMutableBytes { p in
            let b = p.bindMemory(to: UInt16.self)
            for i in 0..<(width * height * 3) { b[i] = UInt16(1000 + (i % 3) * 500).littleEndian }
        }
        let zip = Self.storedZip(name: "raw_data", data: raw)
        var h = [UInt8](repeating: 0, count: 80)
        let size = UInt32(zip.count)
        h[6] = UInt8(size >> 24); h[7] = UInt8((size >> 16) & 0xFF); h[8] = UInt8((size >> 8) & 0xFF); h[9] = UInt8(size & 0xFF)
        h[15] = 23
        h[16] = UInt8(width >> 8); h[17] = UInt8(width & 0xFF)
        h[18] = UInt8(height >> 8); h[19] = UInt8(height & 0xFF)
        return Data(h) + zip
    }

    static func storedZip(name: String, data: Data) -> Data {
        var z = Data()
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; z.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; z.append(Data(bytes: &x, count: 4)) }
        let n = Array(name.utf8)
        u32(0x04034B50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(data.count); u32(data.count); u16(n.count); u16(0)
        z.append(contentsOf: n); z.append(data)
        let central = z.count
        u32(0x02014B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(data.count); u32(data.count)
        u16(n.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        z.append(contentsOf: n)
        let centralSize = z.count - central
        u32(0x06054B50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(central); u16(0)
        return z
    }
}
