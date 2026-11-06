import Foundation

/// Órdenes de alto nivel del Seestar. Los nombres de método son los del protocolo del
/// telescopio, documentados por la comunidad (proyectos seestar_alp y seestar-proxy).
extension SeestarClient {

    // MARK: Apuntado

    /// GoTo con resolución de placa a unas coordenadas del día (RA en horas, Dec en grados).
    func gotoTarget(name: String, raHours: Double, decDeg: Double, lpFilter: Bool = false) async throws {
        try await send("iscope_start_view", params: [
            "mode": "star",
            "target_ra_dec": [raHours, decDeg],
            "target_name": name,
            "lp_filter": lpFilter,
        ])
    }

    /// GoTo y espera al evento AutoGoto. Devuelve true si terminó bien.
    func gotoAndWait(name: String, raHours: Double, decDeg: Double, lpFilter: Bool = false,
                     timeout: Double = 300) async throws -> Bool {
        let start = Date()
        try await gotoTarget(name: name, raHours: raHours, decDeg: decDeg, lpFilter: lpFilter)
        let state = await waitForEvent("AutoGoto", since: start, timeout: timeout)
        return state == "complete"
    }

    func stopGoto() async throws {
        try await send("iscope_stop_view", params: ["stage": "AutoGoto"])
    }

    func stopView() async throws {
        try await send("iscope_stop_view")
    }

    /// Mueve la montura en una dirección. angle: 0 = derecha, 90 = arriba, 180 = izquierda, 270 = abajo.
    func move(angle: Int, speed: Int, seconds: Int = 1) async throws {
        try await send("scope_speed_move", params: ["speed": speed, "angle": angle, "dur_sec": seconds])
    }

    func stopMove() async throws {
        try await send("scope_speed_move", params: ["speed": 0, "angle": 0, "dur_sec": 0])
    }

    func park() async throws {
        try await send("scope_park")
    }

    func openArm() async throws {
        try await send("scope_move_to_horizon")
    }

    func sync(raHours: Double, decDeg: Double) async throws {
        try await send("scope_sync", params: ["ra": raHours, "dec": decDeg])
    }

    // MARK: Enfoque

    func autoFocus() async throws {
        try await send("start_auto_focuse")
    }

    func autoFocusAndWait(tries: Int = 2) async -> Bool {
        for attempt in 1...max(1, tries) {
            let start = Date()
            do { try await autoFocus() } catch {
                addLog(tr("No se pudo iniciar el enfoque: %@", "\(error.localizedDescription)"), .warning)
                continue
            }
            let state = await waitForEvent("AutoFocus", since: start, timeout: 180)
            if state == "complete" { return true }
            addLog(tr("Enfoque automático fallido (intento %@).", "\(attempt)"), .warning)
            try? await Task.sleep(for: .seconds(5))
        }
        return false
    }

    func focuserPositionNow() async throws -> Int? {
        let reply = try await send("get_focuser_position")
        return reply.int("result")
    }

    func moveFocuser(to step: Int) async throws {
        try await send("move_focuser", params: ["step": step, "ret_step": true])
    }

    // MARK: Apilado

    func setTargetName(_ name: String) async throws {
        try await send("set_sequence_setting", params: [["group_name": name]])
    }

    func startStack(restart: Bool = true) async throws {
        try await send("iscope_start_stack", params: ["restart": restart])
    }

    func stopStack() async throws {
        try await send("iscope_stop_view", params: ["stage": "Stack"])
    }

    func setGain(_ gain: Int) async throws {
        try await send("set_control_value", params: ["gain", gain])
    }

    /// Exposición de cada subtoma en milisegundos (10 000, 20 000 o 30 000 según el modelo).
    func setExposure(ms: Int) async throws {
        try await send("set_setting", params: ["exp_ms": ["stack_l": ms]])
    }

    func setLPFilter(_ on: Bool) async throws {
        try await send("set_setting", params: ["stack_lenhance": on])
    }

    func setAutoFocusBeforeStack(_ on: Bool) async throws {
        try await send("set_setting", params: ["auto_af": on])
    }

    func setDither(enabled: Bool, pixels: Int = 50, interval: Int = 10) async throws {
        try await send("set_setting", params: ["stack_dither": ["pix": pixels, "interval": interval, "enable": enabled]])
    }

    func createDarks() async throws {
        try await send("start_create_dark")
    }

    // MARK: Modos especiales

    func startMoonView() async throws {
        try await send("iscope_start_view", params: ["mode": "moon"])
    }

    func startPlanetScan() async throws {
        try await send("start_scan_planet")
    }

    func startStarView() async throws {
        try await send("iscope_start_view", params: ["mode": "star"])
    }

    func startPolarAlign() async throws {
        try await send("start_polar_align")
    }

    func stopPolarAlign() async throws {
        try await send("stop_polar_align")
    }

    // MARK: Equipo

    func setDewHeater(power: Int) async throws {
        try await send("pi_output_set2", params: ["heater": ["state": power > 0, "value": power]])
    }

    func setTimeAndLocation(latitude: Double, longitude: Double) async throws {
        let now = Date()
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        try await send("pi_set_time", params: [
            "year": c.year ?? 2026, "mon": c.month ?? 1, "day": c.day ?? 1,
            "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0,
            "time_zone": TimeZone.current.identifier,
        ])
        try await send("set_user_location", params: ["lat": latitude, "lon": longitude, "force": true])
    }

    func playSound(_ id: Int) async throws {
        try await send("play_sound", params: ["num": id])
    }

    func shutdown() async throws {
        try await send("pi_shutdown")
    }

    // MARK: Álbum

    func albums() async throws -> JSONObject {
        try await send("get_albums", timeout: 30)
    }
}
