import Foundation

/// Órdenes de alto nivel del Seestar. Los nombres de método son los del protocolo del
/// telescopio, documentados por la comunidad (proyectos seestar_alp y seestar-proxy).
extension SeestarClient {

    // MARK: Apuntado

    /// GoTo con resolución de placa a unas coordenadas del día (RA en horas, Dec en grados).
    /// Se niega si el objetivo está cerca del Sol o demasiado bajo, y pide confirmación si
    /// interrumpe un apilado en curso (salvo en la sesión automática).
    func gotoTarget(name: String, raHours: Double, decDeg: Double, lpFilter: Bool = false) async throws {
        if let limits = gotoLimitsProvider(), let reason = GotoSafety.check(raHours: raHours, decDeg: decDeg, limits: limits) {
            addLog(reason, .warning)
            throw GotoBlockedError(reason: reason)
        }
        if isStacking && !Self.unattended {
            guard await confirmInterrupt(tr("Hay un apilado en curso. Si apuntas a %@ se detendrá. ¿Continuar?", name)) else {
                throw GotoBlockedError(reason: tr("Cancelado: el apilado sigue en marcha."))
            }
        }
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
        guard state == "complete" else { return false }
        if let tolerance = recenterToleranceProvider() {
            await recenter(name: name, raHours: raHours, decDeg: decDeg, lpFilter: lpFilter, tolerance: tolerance)
        }
        return true
    }

    /// Posición actual del telescopio en coordenadas del día (tras el GoTo ya está ajustada
    /// con la resolución de placa del propio Seestar).
    func currentPointing() async -> (ra: Double, dec: Double)? {
        guard let r = try? await send("scope_get_equ_coord", timeout: 10),
              let ra = r.double("result.ra"), let dec = r.double("result.dec") else { return nil }
        return (ra, dec)
    }

    /// Si el objeto quedó a más de `tolerance` minutos de arco del centro, vuelve a apuntar (dos veces como mucho).
    func recenter(name: String, raHours: Double, decDeg: Double, lpFilter: Bool, tolerance: Double, maxTries: Int = 2) async {
        for attempt in 0...maxTries {
            try? await Task.sleep(for: .seconds(2))
            guard let p = await currentPointing() else { return }
            let off = RecenterPolicy.offsetArcmin(targetRA: raHours, targetDec: decDeg, actualRA: p.ra, actualDec: p.dec)
            switch RecenterPolicy.decide(offsetArcmin: off, tolerance: tolerance) {
            case .centered:
                if attempt > 0 { addLog(tr("%@ centrado (desvío %@′).", name, String(format: "%.1f", off))) }
                return
            case .unreliable:
                addLog(tr("No se pudo comprobar el centrado (lectura de %@′).", String(format: "%.0f", off)), .warning)
                return
            case .recenter:
                guard attempt < maxTries else {
                    addLog(tr("%@ sigue a %@′ del centro tras %@ intentos.", name, String(format: "%.1f", off), "\(maxTries)"), .warning)
                    return
                }
                addLog(tr("%@ quedó a %@′ del centro: se vuelve a apuntar.", name, String(format: "%.1f", off)))
                let start = Date()
                do {
                    try await Self.$unattended.withValue(true) {
                        try await gotoTarget(name: name, raHours: raHours, decDeg: decDeg, lpFilter: lpFilter)
                    }
                } catch { return }
                guard await waitForEvent("AutoGoto", since: start, timeout: 300) == "complete" else { return }
            }
        }
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
        if restart && isStacking && !Self.unattended {
            guard await confirmInterrupt(tr("Hay un apilado en curso. Si empiezas otro, el actual se detendrá. ¿Continuar?")) else { return }
        }
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

    /// Crea los oscuros y espera a que el telescopio termine (evento DarkLibrary).
    func createDarksAndWait(timeout: Double = 1800) async -> Bool {
        let start = Date()
        try? await send("iscope_stop_view")
        try? await Task.sleep(for: .seconds(1))
        do { try await createDarks() } catch { return false }
        return await waitForEvent("DarkLibrary", since: start, timeout: timeout) == "complete"
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
