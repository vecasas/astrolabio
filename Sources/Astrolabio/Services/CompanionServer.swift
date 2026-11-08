import Foundation
import Network
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Petición HTTP/1.1 mínima (una por conexión).
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]      // nombres en minúsculas
    var body: Data

    static let maxHeaderBytes = 8192
    static let maxBodyBytes = 2048

    enum ParseResult: Equatable { case incomplete, invalid, ok(HTTPRequest, consumed: Int) }

    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), ["GET", "POST", "HEAD"].contains(String(first[0])),
              first[1].hasPrefix("/"), first[1].count <= 200 else { return .invalid }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .invalid }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBodyBytes, headers["transfer-encoding"] == nil else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .ok(HTTPRequest(method: String(first[0]), path: path, headers: headers, body: Data(body)), consumed: bodyStart - data.startIndex + length)
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8",
                     body: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(status, ["error": message]) }

    func serialized(head: Bool = false) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 429: "Too Many Requests", 503: "Service Unavailable"][status] ?? "Error"
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        var all: [String: String] = ["Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
                                     "Referrer-Policy": "no-referrer", "Connection": "close"]
        for (k, v) in extraHeaders { all[k] = v }
        for k in all.keys.sorted() { h += "\(k): \(NetPolicy.headerValue(all[k]!))\r\n" }
        h += "\r\n"
        var d = Data(h.utf8)
        if !head { d.append(body) }
        return d
    }
}

/// Emparejamiento y llaves de los móviles. Sin estado de red: se prueba sin sockets.
final class CompanionAuth {
    /// Sesión de emparejamiento abierta desde el ordenador: token del QR + código de 6 cifras, 5 minutos, 5 intentos.
    struct Pairing { let token: String; let code: String; let expires: Date; var failures = 0 }
    static let pairingLifetime: TimeInterval = 300
    static let maxCodeFailures = 5

    private(set) var pairing: Pairing?
    /// SHA-256 (hex) de las llaves de los móviles emparejados → fecha de emparejado.
    private(set) var devices: [String: Date]
    var onDevicesChanged: (([String: Date]) -> Void)?
    var now: () -> Date = Date.init

    init(devices: [String: Date] = [:]) { self.devices = devices }

    static func randomToken(bytes: Int = 24) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func randomCode() -> String {
        var n: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &n) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return String(format: "%06u", n % 1_000_000)
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Comparación en tiempo constante.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    @discardableResult
    func startPairing() -> Pairing {
        let p = Pairing(token: Self.randomToken(), code: Self.randomCode(), expires: now().addingTimeInterval(Self.pairingLifetime))
        pairing = p
        return p
    }

    func cancelPairing() { pairing = nil }

    enum PairResult: Equatable { case ok(key: String), expired, wrong, locked }

    func pair(token: String, code: String) -> PairResult {
        guard var p = pairing, now() < p.expires else { pairing = nil; return .expired }
        guard Self.same(p.token, token) else { return .wrong }
        guard Self.same(p.code, code) else {
            p.failures += 1
            pairing = p.failures >= Self.maxCodeFailures ? nil : p
            return p.failures >= Self.maxCodeFailures ? .locked : .wrong
        }
        pairing = nil                       // un QR sirve para un solo móvil
        let key = Self.randomToken(bytes: 32)
        devices[Self.hash(key)] = now()
        onDevicesChanged?(devices)
        return .ok(key: key)
    }

    func isAuthorized(_ authorization: String?) -> Bool {
        guard let a = authorization, a.hasPrefix("Bearer ") else { return false }
        let key = String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard key.count >= 32, key.count <= 64 else { return false }
        let h = Self.hash(key)
        return devices.keys.contains { Self.same($0, h) }
    }

    func revokeAll() {
        devices = [:]
        pairing = nil
        onDevicesChanged?(devices)
    }
}

/// Límite de peticiones por dirección: cubo de fichas.
final class RateLimiter {
    let capacity: Double
    let perSecond: Double
    private var buckets: [String: (tokens: Double, at: Date)] = [:]
    var now: () -> Date = Date.init

    init(capacity: Double, perSecond: Double) { self.capacity = capacity; self.perSecond = perSecond }

    func allow(_ who: String, cost: Double = 1) -> Bool {
        let t = now()
        var b = buckets[who] ?? (capacity, t)
        b.tokens = min(capacity, b.tokens + t.timeIntervalSince(b.at) * perSecond)
        b.at = t
        let ok = b.tokens >= cost
        if ok { b.tokens -= cost }
        buckets[who] = b
        if buckets.count > 256 { buckets = buckets.filter { t.timeIntervalSince($0.value.at) < 600 } }
        return ok
    }
}

/// Lo que el móvil puede ver y hacer. Lo rellena la app; en las pruebas, un simulacro.
struct CompanionBridge {
    var status: @MainActor () -> [String: Any]
    var jpeg: @MainActor () -> Data?
    var stop: @MainActor () async -> String
    var skip: @MainActor () async -> String
    var park: @MainActor () async -> String
    var strings: @MainActor () -> [String: String]
    var language: @MainActor () -> String
}

/// Decide la respuesta a cada petición: dirección privada, Host correcto, límites, llave y ruta.
@MainActor
final class CompanionRouter {
    let auth: CompanionAuth
    let bridge: CompanionBridge
    /// «ip:puerto» con el que se anuncia el servidor (contra el DNS rebinding).
    var expectedHost: String
    let general = RateLimiter(capacity: 30, perSecond: 3)
    let pairLimiter = RateLimiter(capacity: 5, perSecond: 1.0 / 60)
    let actionLimiter = RateLimiter(capacity: 3, perSecond: 1.0 / 10)

    init(auth: CompanionAuth, bridge: CompanionBridge, expectedHost: String) {
        self.auth = auth; self.bridge = bridge; self.expectedHost = expectedHost
    }

    /// Solo direcciones de la red local (IPv4 privadas, enlace local, bucle; IPv6 ULA y de enlace).
    nonisolated static func isPrivate(_ ip: String) -> Bool {
        var a = ip.lowercased()
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a.hasPrefix("::ffff:") { a = String(a.dropFirst(7)) }
        if a == "::1" { return true }
        if a.contains(":") { return a.hasPrefix("fe8") || a.hasPrefix("fe9") || a.hasPrefix("fea") || a.hasPrefix("feb") || a.hasPrefix("fc") || a.hasPrefix("fd") }
        let p = a.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    func handle(_ r: HTTPRequest, from ip: String) async -> HTTPResponse {
        guard Self.isPrivate(ip) else { return .error(403, "Solo red local") }
        guard let host = r.headers["host"], host.lowercased() == expectedHost.lowercased() else { return .error(403, "Host") }
        guard general.allow(ip) else { return .error(429, tr("Demasiadas peticiones. Espera un momento.")) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("HEAD", "/"):
            return page()
        case ("POST", "/api/pair"):
            guard pairLimiter.allow(ip) else { return .error(429, tr("Demasiados intentos. Espera unos minutos.")) }
            guard r.headers["content-type"]?.hasPrefix("application/json") == true,
                  let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let token = obj["pair"] as? String, let code = obj["code"] as? String else { return .error(400, "JSON") }
            switch auth.pair(token: token, code: code.trimmingCharacters(in: .whitespaces)) {
            case .ok(let key): return .json(200, ["key": key])
            case .wrong: return .error(401, tr("Código incorrecto."))
            case .locked: return .error(401, tr("Demasiados códigos incorrectos: vuelve a mostrar el QR en el ordenador."))
            case .expired: return .error(401, tr("El QR ha caducado: vuelve a mostrarlo en el ordenador."))
            }
        case (_, let p) where p.hasPrefix("/api/"):
            guard auth.isAuthorized(r.headers["authorization"]) else { return .error(401, tr("Este móvil no está emparejado.")) }
            switch (r.method, p) {
            case ("GET", "/api/status"):
                return .json(200, bridge.status())
            case ("GET", "/api/image.jpg"):
                guard let d = bridge.jpeg() else { return .error(404, tr("Sin imagen")) }
                return HTTPResponse(status: 200, contentType: "image/jpeg", body: d)
            case ("POST", "/api/stop"), ("POST", "/api/skip"), ("POST", "/api/park"):
                guard actionLimiter.allow(ip) else { return .error(429, tr("Demasiadas peticiones. Espera un momento.")) }
                let msg: String
                switch p {
                case "/api/stop": msg = await bridge.stop()
                case "/api/skip": msg = await bridge.skip()
                default: msg = await bridge.park()
                }
                return .json(200, ["message": msg])
            default:
                return .error(404, "No encontrado")
            }
        default:
            return .error(r.method == "GET" ? 404 : 405, "No encontrado")
        }
    }

    private func page() -> HTTPResponse {
        let nonce = CompanionAuth.randomToken(bytes: 16)
        var json = String(data: (try? JSONSerialization.data(withJSONObject: bridge.strings(), options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        json = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026")
        let html = CompanionPage.html.replacingOccurrences(of: "__NONCE__", with: nonce)
            .replacingOccurrences(of: "__LANG__", with: bridge.language()).replacingOccurrences(of: "__I18N__", with: json)
        return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8), extraHeaders: [
            "Content-Security-Policy": "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; img-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        ])
    }

    /// Textos de la página en el idioma de la app.
    static func pageStrings() -> [String: String] {
        ["lTarget": tr("Objeto"), "lPhase": tr("Estado"), "lFrames": tr("Fotogramas"), "lBattery": tr("Batería"),
         "lPlan": tr("Plan"), "lLog": tr("Últimos mensajes"), "stop": tr("Parar"), "skip": tr("Saltar"), "park": tr("Aparcar"),
         "pairText": tr("Escribe el código de 6 cifras que aparece en el ordenador."), "pairBtn": tr("Emparejar"),
         "needQR": tr("Escanea el QR que aparece en Astrolabio, en «Control desde el móvil»."),
         "pairFail": tr("No se pudo emparejar."), "offline": tr("Sin conexión con el ordenador."),
         "noScope": tr("El telescopio no está conectado."), "updated": tr("Actualizada a las"),
         "askStop": tr("¿Parar el apilado o la sesión automática?"), "askSkip": tr("¿Saltar al siguiente objeto del plan?"),
         "askPark": tr("¿Parar y aparcar el telescopio?"), "nightMode": tr("Modo nocturno"), "dayMode": tr("Modo normal")]
    }
}

/// Servidor HTTP en la red local para el móvil. Apagado salvo que el usuario lo active.
@MainActor
final class CompanionServer: ObservableObject {
    static let shared = CompanionServer()
    static let defaultPort: UInt16 = 8642

    @Published private(set) var isRunning = false
    @Published private(set) var url: String?
    @Published private(set) var error: String?
    @Published private(set) var pairing: CompanionAuth.Pairing?
    @Published private(set) var deviceCount = 0

    let auth: CompanionAuth
    private var router: CompanionRouter?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "astrolabio.companion")
    private let defaults: UserDefaults
    private static let devicesKey = "companionDevices"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.dictionary(forKey: Self.devicesKey) as? [String: Date]) ?? [:]
        auth = CompanionAuth(devices: saved)
        deviceCount = saved.count
        auth.onDevicesChanged = { [weak self] d in
            MainActor.assumeIsolated {
                self?.defaults.set(d, forKey: Self.devicesKey)
                self?.deviceCount = d.count
            }
        }
    }

    /// Primera dirección IPv4 privada de una interfaz activa (wifi o cable).
    nonisolated static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf), name = String(cString: i.ifa_name)
            if CompanionRouter.isPrivate(ip) && !ip.hasPrefix("169.254.") { found.append((name, ip)) }
        }
        return (found.first { $0.0.hasPrefix("en") } ?? found.first)?.1
    }

    func start(bridge: CompanionBridge, port: UInt16 = defaultPort, bindAddress: String? = nil) {
        stop()
        guard let ip = bindAddress ?? Self.lanAddress() else { error = tr("No hay conexión a una red local."); return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!)
        params.prohibitedInterfaceTypes = [.cellular]
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            let hostPort = "\(ip):\(port)"
            let r = CompanionRouter(auth: auth, bridge: bridge, expectedHost: hostPort)
            router = r
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.isRunning = true; self?.error = nil
                    case .failed(let e): self?.isRunning = false; self?.error = e.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener = l
            url = "http://\(hostPort)/"
            l.start(queue: queue)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        router = nil
        isRunning = false
        url = nil
        pairing = nil
        auth.cancelPairing()
    }

    func startPairing() { pairing = auth.startPairing() }
    func cancelPairing() { auth.cancelPairing(); pairing = nil }
    func revokeAll() { auth.revokeAll(); pairing = nil }

    var pairingURL: String? {
        guard let url, let p = pairing else { return nil }
        return "\(url)#p=\(p.token)"
    }

    nonisolated private func accept(_ c: NWConnection) {
        var ip = ""
        if case .hostPort(let h, _) = c.endpoint { ip = "\(h)" }
        // Conexiones de fuera de la red local: se cierran sin leer nada.
        guard CompanionRouter.isPrivate(ip) else { c.cancel(); return }
        c.start(queue: queue)
        let deadline = DispatchWorkItem { c.cancel() }
        queue.asyncAfter(deadline: .now() + 10, execute: deadline)
        receive(c, buffer: Data(), ip: ip, deadline: deadline)
    }

    nonisolated private func receive(_ c: NWConnection, buffer: Data, ip: String, deadline: DispatchWorkItem) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .incomplete where !done && err == nil:
                self.receive(c, buffer: buf, ip: ip, deadline: deadline)
            case .ok(let req, _):
                Task { @MainActor in
                    let resp = await self.router?.handle(req, from: ip) ?? .error(503, "")
                    let out = resp.serialized(head: req.method == "HEAD")
                    self.queue.async {
                        c.send(content: out, completion: .contentProcessed { _ in deadline.cancel(); c.cancel() })
                    }
                }
            default:
                let out = HTTPResponse.error(400, "Bad request").serialized()
                c.send(content: out, completion: .contentProcessed { _ in deadline.cancel(); c.cancel() })
            }
        }
    }

    // MARK: Imagen

    /// JPEG reducido (máx. 1280 px) de la vista en directo.
    nonisolated static func jpeg(_ img: CGImage, maxSide: Int = 1280, quality: Double = 0.7) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
