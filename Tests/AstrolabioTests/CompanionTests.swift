import Testing
import Foundation
@testable import Astrolabio

/// Servidor para el móvil: emparejamiento, llaves, límites y red local.
@MainActor
struct CompanionTests {
    final class Calls { var stop = 0, skip = 0, park = 0 }

    static func bridge(_ calls: Calls) -> CompanionBridge {
        CompanionBridge(status: { ["connected": true, "running": true, "frames": 12, "target": "M 31"] },
                        jpeg: { Data([0xFF, 0xD8, 0xFF, 0xD9]) },
                        stop: { calls.stop += 1; return "parado" },
                        skip: { calls.skip += 1; return "saltado" },
                        park: { calls.park += 1; return "aparcado" },
                        strings: { CompanionRouter.pageStrings() },
                        language: { "es" })
    }

    static func req(_ method: String, _ path: String, host: String = "192.168.1.10:8642", auth: String? = nil, json: String? = nil) -> HTTPRequest {
        var h = ["host": host]
        if let auth { h["authorization"] = "Bearer \(auth)" }
        if json != nil { h["content-type"] = "application/json" }
        return HTTPRequest(method: method, path: path, headers: h, body: Data((json ?? "").utf8))
    }

    @Test func testParsesRequestsAndRejectsAbuse() {
        let raw = "POST /api/pair?x=1 HTTP/1.1\r\nHost: a:1\r\nContent-Length: 4\r\n\r\nabcd"
        guard case .ok(let r, let n) = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("no se leyó"); return }
        #expect(r.method == "POST" && r.path == "/api/pair" && r.headers["host"] == "a:1" && r.body == Data("abcd".utf8) && n == raw.utf8.count)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: a".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("DELETE / HTTP/1.1\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPRequest.parse(Data(repeating: 65, count: 9000)) == .invalid)
    }

    @Test func testOnlyPrivateAddresses() {
        for ip in ["192.168.1.5", "10.0.0.2", "172.20.1.1", "127.0.0.1", "::1", "fe80::1%en0", "fd12::3", "::ffff:192.168.0.4", "169.254.3.3"] {
            #expect(CompanionRouter.isPrivate(ip), "\(ip)")
        }
        for ip in ["8.8.8.8", "172.32.0.1", "2001:db8::1", "::ffff:8.8.8.8", "", "nombre.com", "300.1.1.1"] {
            #expect(!CompanionRouter.isPrivate(ip), "\(ip)")
        }
    }

    @Test func testPairingNeedsTokenAndCodeOnceAndExpires() {
        let a = CompanionAuth()
        var t = Date()
        a.now = { t }
        let p = a.startPairing()
        #expect(p.code.count == 6 && p.token.count >= 30)
        #expect(a.pair(token: "otro", code: p.code) == .wrong)
        #expect(a.pair(token: p.token, code: "000000" == p.code ? "111111" : "000000") == .wrong)
        guard case .ok(let key) = a.pair(token: p.token, code: p.code) else { Issue.record("no emparejó"); return }
        #expect(a.isAuthorized("Bearer \(key)") && !a.isAuthorized("Bearer \(key.hasPrefix("x") ? "y" : "x")\(key.dropFirst())") && !a.isAuthorized(key))
        #expect(a.pair(token: p.token, code: p.code) == .expired)          // un QR, un móvil
        // Caduca a los 5 minutos.
        let q = a.startPairing()
        t = t.addingTimeInterval(301)
        #expect(a.pair(token: q.token, code: q.code) == .expired)
        // Cinco códigos malos anulan el QR.
        let r = a.startPairing()
        let bad = r.code == "123456" ? "654321" : "123456"
        for _ in 0..<4 { #expect(a.pair(token: r.token, code: bad) == .wrong) }
        #expect(a.pair(token: r.token, code: bad) == .locked)
        #expect(a.pair(token: r.token, code: r.code) == .expired)
        // Revocar quita todas las llaves.
        a.revokeAll()
        #expect(!a.isAuthorized("Bearer \(key)"))
    }

    @Test func testRateLimiter() {
        let l = RateLimiter(capacity: 3, perSecond: 1)
        var t = Date()
        l.now = { t }
        #expect(l.allow("a") && l.allow("a") && l.allow("a"))
        #expect(!l.allow("a") && l.allow("b"))
        t = t.addingTimeInterval(1.1)
        #expect(l.allow("a") && !l.allow("a"))
    }

    @Test func testRouterAuthHostAndActions() async throws {
        let calls = Calls()
        let auth = CompanionAuth()
        let r = CompanionRouter(auth: auth, bridge: Self.bridge(calls), expectedHost: "192.168.1.10:8642")
        // Fuera de la red local o con otro Host (DNS rebinding): prohibido.
        #expect(await r.handle(Self.req("GET", "/"), from: "8.8.8.8").status == 403)
        #expect(await r.handle(Self.req("GET", "/", host: "evil.example:8642"), from: "192.168.1.20").status == 403)
        // Página: CSP con nonce, sin plantillas sin rellenar.
        let page = await r.handle(Self.req("GET", "/"), from: "192.168.1.20")
        let html = String(decoding: page.body, as: UTF8.self)
        #expect(page.status == 200 && page.extraHeaders["Content-Security-Policy"]?.contains("default-src 'none'") == true)
        #expect(!html.contains("__NONCE__") && !html.contains("__I18N__") && html.contains("Parar"))
        // Sin llave: 401 y no se hace nada.
        #expect(await r.handle(Self.req("GET", "/api/status"), from: "192.168.1.20").status == 401)
        #expect(await r.handle(Self.req("POST", "/api/park", auth: String(repeating: "a", count: 40)), from: "192.168.1.20").status == 401)
        #expect(calls.park == 0)
        // Emparejar.
        let p = auth.startPairing()
        let bad = await r.handle(Self.req("POST", "/api/pair", json: #"{"pair":"\#(p.token)","code":"x"}"#), from: "192.168.1.20")
        #expect(bad.status == 401)
        let ok = await r.handle(Self.req("POST", "/api/pair", json: #"{"pair":"\#(p.token)","code":"\#(p.code)"}"#), from: "192.168.1.20")
        let key = try #require((try JSONSerialization.jsonObject(with: ok.body) as? [String: Any])?["key"] as? String)
        // Con llave.
        let st = await r.handle(Self.req("GET", "/api/status", auth: key), from: "192.168.1.20")
        #expect(st.status == 200 && String(decoding: st.body, as: UTF8.self).contains("M 31"))
        #expect(await r.handle(Self.req("GET", "/api/image.jpg", auth: key), from: "192.168.1.20").contentType == "image/jpeg")
        #expect(await r.handle(Self.req("POST", "/api/skip", auth: key), from: "192.168.1.20").status == 200)
        #expect(await r.handle(Self.req("GET", "/api/park", auth: key), from: "192.168.1.20").status == 404)   // GET no actúa
        #expect(calls.skip == 1 && calls.park == 0)
        // Límite de acciones: 3 seguidas y luego 429.
        _ = await r.handle(Self.req("POST", "/api/stop", auth: key), from: "192.168.1.20")
        _ = await r.handle(Self.req("POST", "/api/stop", auth: key), from: "192.168.1.20")
        #expect(await r.handle(Self.req("POST", "/api/park", auth: key), from: "192.168.1.20").status == 429)
        #expect(calls.stop == 2 && calls.park == 0)
    }

    @Test func testPairingAttemptsAreRateLimited() async {
        let r = CompanionRouter(auth: CompanionAuth(), bridge: Self.bridge(Calls()), expectedHost: "192.168.1.10:8642")
        var statuses: [Int] = []
        for _ in 0..<7 { statuses.append(await r.handle(Self.req("POST", "/api/pair", json: #"{"pair":"a","code":"1"}"#), from: "192.168.1.30").status) }
        #expect(statuses.prefix(5).allSatisfy { $0 == 401 } && statuses.suffix(2).allSatisfy { $0 == 429 })
    }

    /// Servidor real en 127.0.0.1: la página y la API responden por HTTP.
    @Test func testRealServerOverLoopback() async throws {
        let defaults = UserDefaults(suiteName: "companion-\(UUID())")!
        let server = CompanionServer(defaults: defaults)
        let port = UInt16.random(in: 20000...40000)
        server.start(bridge: Self.bridge(Calls()), port: port, bindAddress: "127.0.0.1")
        defer { server.stop() }
        for _ in 0..<50 where !server.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(server.isRunning)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg)
        let (d, resp) = try await session.data(from: base)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200 && String(decoding: d, as: UTF8.self).contains("<html"))
        let (_, r401) = try await session.data(from: base.appendingPathComponent("api/status"))
        #expect((r401 as? HTTPURLResponse)?.statusCode == 401)
        server.startPairing()
        let p = try #require(server.pairing)
        var req = URLRequest(url: base.appendingPathComponent("api/pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"pair":"\#(p.token)","code":"\#(p.code)"}"#.utf8)
        let (kd, _) = try await session.data(for: req)
        let key = try #require((try JSONSerialization.jsonObject(with: kd) as? [String: Any])?["key"] as? String)
        var st = URLRequest(url: base.appendingPathComponent("api/status"))
        st.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (sd, sr) = try await session.data(for: st)
        #expect((sr as? HTTPURLResponse)?.statusCode == 200 && String(decoding: sd, as: UTF8.self).contains("frames"))
        #expect(server.deviceCount == 1)
        // La llave se guarda como resumen SHA-256, nunca en claro.
        let saved = defaults.dictionary(forKey: "companionDevices") ?? [:]
        #expect(saved.count == 1 && saved.keys.first != key && saved.keys.first == CompanionAuth.hash(key))
    }
}
