import Testing
import Foundation
@testable import Astrolabio

/// Pruebas de extremo a extremo contra un Seestar simulado (FakeSeestar): conexión, autenticación,
/// órdenes, errores, reconexión, seguridad del GoTo, recentrado, canal de imagen y sesión automática.
@MainActor
@Suite(.serialized)
struct ProtocolIntegrationTests {
    init() { Notifier.enabled = false }

    private func connected(_ fake: FakeSeestar, signer: SeestarSigner? = nil) async -> SeestarClient {
        let c = SeestarClient()
        c.port = fake.port
        c.signerProvider = { signer }
        await c.connect(to: "127.0.0.1")
        return c
    }

    private func waitUntil(_ timeout: Double = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return cond()
    }

    @Test func testConnectAuthenticatesAndReadsDeviceState() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let keys = try FakeSeestar.makeKeyPair()
        fake.publicKey = keys.publicKey
        let c = await connected(fake, signer: try SeestarSigner(pemText: keys.pem))
        defer { c.disconnect() }
        #expect(c.isConnected)
        #expect(c.isAuthenticated)                         // firma comprobada por el simulador
        #expect(c.firmwareVersion == 2706 && c.firmwareString == "6.45")
        #expect(c.deviceName == "Seestar S50 simulado")
        #expect(c.battery == 87 && c.freeStorageMB == 12_000 && c.focuserPosition == 1600)
        #expect(c.connectionCount == 1)
    }

    @Test func testWrongKeyIsRejected() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        fake.publicKey = try FakeSeestar.makeKeyPair().publicKey          // el telescopio espera otra clave
        let c = await connected(fake, signer: try SeestarSigner(pemText: try FakeSeestar.makeKeyPair().pem))
        defer { c.disconnect() }
        #expect(c.isConnected)
        #expect(!c.isAuthenticated)
        #expect(c.authMessage.contains("210") || !c.authMessage.isEmpty)
    }

    @Test func testDeviceErrorsAndTimeouts() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        fake.errors["scope_park"] = 207
        fake.silent = ["scope_move_to_horizon"]
        let c = await connected(fake)
        defer { c.disconnect() }
        await #expect(throws: SeestarError.self) { try await c.park() }
        let start = Date()
        await #expect(throws: SeestarError.self) { _ = try await c.send("scope_move_to_horizon", timeout: 1) }
        #expect(Date().timeIntervalSince(start) < 3)
        // La conexión sigue viva después de un error y de un tiempo de espera.
        _ = try await c.send("get_device_state")
    }

    @Test func testDisconnectFailsPendingCommandsAndReconnects() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        fake.dropOn = ["reboot_simulado"]
        let c = await connected(fake)
        defer { c.disconnect() }
        await #expect(throws: SeestarError.self) { _ = try await c.send("reboot_simulado", timeout: 10) }
        #expect(await waitUntil(15) { c.connectionCount >= 2 && c.isConnected })   // reconexión automática
    }

    @Test func testSafetyBlocksGotoWithoutSendingIt() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        c.gotoLimitsProvider = { GotoSafety.Limits(latitude: 40.48, longitude: -3.36, minAltitude: 15, minSunSeparation: 30) }
        let sun = Astro.sun(Date())
        await #expect(throws: GotoBlockedError.self) { try await c.gotoTarget(name: "Sol", raHours: sun.ra, decDeg: sun.dec) }
        await #expect(throws: GotoBlockedError.self) { try await c.gotoTarget(name: "Bajo", raHours: 6.4, decDeg: -80) }
        #expect(fake.count("iscope_start_view") == 0)
    }

    @Test func testGotoRecentersWhenOffCentre() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        c.recenterToleranceProvider = { 2 }
        fake.pointingOffsetsArcmin = [3.0, 0.5]                // queda a 3′, se corrige y queda a 0,5′
        let p = Astro.precessFromJ2000(raHours: 2.53, decDeg: 89.26, to: Date())
        let ok = try await c.gotoAndWait(name: "Polaris", raHours: p.ra, decDeg: p.dec, timeout: 10)
        #expect(ok)
        #expect(fake.count("iscope_start_view") == 2)
        fake.pointingOffsetsArcmin = [0.5]                     // centrado a la primera
        _ = try await c.gotoAndWait(name: "Polaris", raHours: p.ra, decDeg: p.dec, timeout: 10)
        #expect(fake.count("iscope_start_view") == 3)
        fake.pointingOffsetsArcmin = [500]                     // lectura absurda: no se insiste
        _ = try await c.gotoAndWait(name: "Polaris", raHours: p.ra, decDeg: p.dec, timeout: 10)
        #expect(fake.count("iscope_start_view") == 4)
    }

    @Test func testFailedGotoReportsFalse() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        fake.gotoResult = "fail"
        let c = await connected(fake)
        defer { c.disconnect() }
        let p = Astro.precessFromJ2000(raHours: 2.53, decDeg: 89.26, to: Date())
        #expect(try await c.gotoAndWait(name: "Polaris", raHours: p.ra, decDeg: p.dec, timeout: 10) == false)
    }

    @Test func testInterruptingAStackAsksFirst() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        try await c.startStack()
        #expect(await waitUntil { c.isStacking && c.stackedFrames >= 1 })
        var asked = 0
        c.confirmInterrupt = { _ in asked += 1; return false }
        let p = Astro.precessFromJ2000(raHours: 2.53, decDeg: 89.26, to: Date())
        await #expect(throws: GotoBlockedError.self) { try await c.gotoTarget(name: "Polaris", raHours: p.ra, decDeg: p.dec) }
        #expect(asked == 1 && fake.count("iscope_start_view") == 0)
        // La sesión automática no pregunta.
        try await SeestarClient.$unattended.withValue(true) {
            try await c.gotoTarget(name: "Polaris", raHours: p.ra, decDeg: p.dec)
        }
        #expect(asked == 1 && fake.count("iscope_start_view") == 1)
    }

    @Test func testAlbumImportThroughTheProtocol() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        let log = ObservationLog(storage: FileManager.default.temporaryDirectory.appendingPathComponent("album-\(UUID()).json"))
        log.attach(to: c, exposureMs: { 10_000 })
        #expect(log.importFromAlbum(try await c.albums()) == 1)
        #expect(log.records.first?.target == "M 42")
        #expect(log.records.first?.albumThumb?.hasPrefix("http://127.0.0.1/MyWorks/") == true)
    }

    @Test func testImageStreamDeliversStackedFrame() async throws {
        let server = try FakeImageServer(width: 64, height: 48)
        defer { server.stop() }
        let stream = ImageStream()
        stream.port = server.port
        var got: RawFrame?
        stream.onFrame = { got = $0 }
        stream.connect(host: "127.0.0.1")
        defer { stream.disconnect() }
        #expect(await waitUntil(8) { got != nil })
        #expect(got?.kind == .stacked && got?.width == 64 && got?.height == 48 && got?.channels == 3)
        #expect(got?.pixels.count == 64 * 48 * 3 && got?.pixels[1] == 1500)
        let lin = ImageProcessing.linear(from: try #require(got))
        #expect(lin.width > 0 && lin.height > 0)
    }

    @Test func testSessionRunnerRunsAPlanAndParks() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        let defaults = try #require(UserDefaults(suiteName: "astro-run-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.endAction = .park
        let plan = PlanStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).json"))
        var item = PlanItem(name: "Polaris", raHours: 2.53, decDeg: 89.26, minutes: 0.1)
        item.autofocus = false
        plan.items = [item]
        let runner = SessionRunner()
        runner.stateDefaults = defaults
        runner.options = .init(waitForDark: false, pauseForClouds: false, stopAtDawn: false)
        runner.start(client: c, settings: settings, plan: plan)
        #expect(SessionRunner.pendingResume(defaults: defaults) != nil)        // estado guardado para retomar
        #expect(await waitUntil(30) { runner.phase == .finished })
        #expect(plan.items[0].status == .done)
        #expect((plan.items[0].doneSeconds ?? 0) >= 5)
        #expect(fake.count("iscope_start_view") >= 1 && fake.count("iscope_start_stack") == 1 && fake.count("scope_park") == 1)
        #expect(fake.count("set_user_location") == 1)
        #expect(SessionRunner.pendingResume(defaults: defaults) == nil)        // terminado: nada que retomar
    }

    @Test func testResumedItemOnlyStacksTheRemainingTime() async throws {
        let fake = try FakeSeestar()
        defer { fake.stop() }
        let c = await connected(fake)
        defer { c.disconnect() }
        let defaults = try #require(UserDefaults(suiteName: "astro-resume-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.endAction = .nothing
        settings.darksAtEnd = true
        let plan = PlanStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).json"))
        var item = PlanItem(name: "Polaris", raHours: 2.53, decDeg: 89.26, minutes: 10)
        item.autofocus = false
        item.status = .running                 // estaba en marcha cuando se cerró la app
        item.doneSeconds = 10 * 60 - 6         // le quedan 6 segundos
        plan.items = [item]
        let runner = SessionRunner()
        runner.stateDefaults = defaults
        let saved = SessionRunner.SavedState(startedAt: Date().addingTimeInterval(-3600),
                                             options: .init(waitForDark: false, pauseForClouds: false, stopAtDawn: false))
        let t0 = Date()
        runner.start(client: c, settings: settings, plan: plan, resuming: saved)
        #expect(await waitUntil(30) { runner.phase == .finished })
        #expect(Date().timeIntervalSince(t0) < 25)                         // no repite los 10 minutos
        #expect(plan.items[0].status == .done)
        #expect(fake.count("start_create_dark") == 1)                      // oscuros al final
        #expect(fake.count("scope_park") == 0)                              // «dejarlo como está»
    }
}
