using System.Text.Json.Nodes;

namespace Astrolabio.Core.Protocol;

/// <summary>Órdenes de alto nivel del Seestar (nombres de método documentados por la comunidad).</summary>
public static class SeestarCommands
{
    /// <summary>GoTo con resolución de placa (coordenadas de la fecha). Se niega cerca del Sol o
    /// demasiado bajo y pregunta antes de interrumpir un apilado (salvo en la sesión automática).</summary>
    public static async Task GotoTarget(this SeestarClient c, string name, double raHours, double decDeg, bool lp = false)
    {
        if (c.GotoLimitsProvider() is { } limits && Model.GotoSafety.Check(raHours, decDeg, DateTime.UtcNow, limits) is string reason)
        {
            c.AddLog(reason, LogLevel.Warning);
            throw new Model.GotoBlockedException(reason);
        }
        if (c.IsStacking && !SeestarClient.Unattended &&
            !await c.ConfirmInterrupt(Strings.T("Hay un apilado en curso. Si apuntas a %@ se detendrá. ¿Continuar?", name)))
            throw new Model.GotoBlockedException(Strings.T("Cancelado: el apilado sigue en marcha."));
        await c.Send("iscope_start_view", new JsonObject
        {
            ["mode"] = "star", ["target_ra_dec"] = new JsonArray(raHours, decDeg), ["target_name"] = name, ["lp_filter"] = lp,
        });
    }

    public static async Task<bool> GotoAndWait(this SeestarClient c, string name, double raHours, double decDeg, bool lp = false, double timeout = 300)
    {
        var start = DateTime.Now;
        await c.GotoTarget(name, raHours, decDeg, lp);
        if (await c.WaitForEvent("AutoGoto", start, timeout) != "complete") return false;
        if (c.RecenterToleranceProvider() is double tol) await c.Recenter(name, raHours, decDeg, lp, tol);
        return true;
    }

    /// <summary>Posición actual en coordenadas de la fecha (ya ajustada por la resolución de placa del Seestar).</summary>
    public static async Task<(double Ra, double Dec)?> CurrentPointing(this SeestarClient c)
    {
        try
        {
            var r = await c.Send("scope_get_equ_coord", timeout: 10);
            return r.Num("result.ra") is double ra && r.Num("result.dec") is double dec ? (ra, dec) : null;
        }
        catch { return null; }
    }

    /// <summary>Vuelve a apuntar (dos veces como mucho) si el objeto quedó a más de <paramref name="tolerance"/>′ del centro.</summary>
    public static async Task Recenter(this SeestarClient c, string name, double ra, double dec, bool lp, double tolerance, int maxTries = 2)
    {
        for (var attempt = 0; attempt <= maxTries; attempt++)
        {
            await Task.Delay(2000);
            if (await c.CurrentPointing() is not { } p) return;
            var off = Model.RecenterPolicy.OffsetArcmin(ra, dec, p.Ra, p.Dec);
            var offText = off.ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
            switch (Model.RecenterPolicy.Decide(off, tolerance))
            {
                case Model.RecenterPolicy.Decision.Centered:
                    if (attempt > 0) c.AddLog(Strings.T("%@ centrado (desvío %@′).", name, offText));
                    return;
                case Model.RecenterPolicy.Decision.Unreliable:
                    c.AddLog(Strings.T("No se pudo comprobar el centrado (lectura de %@′).", (int)off), LogLevel.Warning);
                    return;
            }
            if (attempt == maxTries) { c.AddLog(Strings.T("%@ sigue a %@′ del centro tras %@ intentos.", name, offText, maxTries), LogLevel.Warning); return; }
            c.AddLog(Strings.T("%@ quedó a %@′ del centro: se vuelve a apuntar.", name, offText));
            var start = DateTime.Now;
            var prev = SeestarClient.Unattended;
            SeestarClient.Unattended = true;
            try { await c.GotoTarget(name, ra, dec, lp); } catch { return; } finally { SeestarClient.Unattended = prev; }
            if (await c.WaitForEvent("AutoGoto", start, 300) != "complete") return;
        }
    }

    public static Task StopGoto(this SeestarClient c) => c.Send("iscope_stop_view", new JsonObject { ["stage"] = "AutoGoto" });
    public static Task StopView(this SeestarClient c) => c.Send("iscope_stop_view");
    public static Task Move(this SeestarClient c, int angle, int speed, int seconds = 1) =>
        c.Send("scope_speed_move", new JsonObject { ["speed"] = speed, ["angle"] = angle, ["dur_sec"] = seconds });
    public static Task StopMove(this SeestarClient c) => c.Send("scope_speed_move", new JsonObject { ["speed"] = 0, ["angle"] = 0, ["dur_sec"] = 0 });
    public static Task Park(this SeestarClient c) => c.Send("scope_park");
    public static Task OpenArm(this SeestarClient c) => c.Send("scope_move_to_horizon");
    public static Task Sync(this SeestarClient c, double raHours, double decDeg) => c.Send("scope_sync", new JsonObject { ["ra"] = raHours, ["dec"] = decDeg });

    public static Task AutoFocus(this SeestarClient c) => c.Send("start_auto_focuse");
    public static async Task<bool> AutoFocusAndWait(this SeestarClient c, int tries = 2)
    {
        for (var attempt = 1; attempt <= Math.Max(1, tries); attempt++)
        {
            var start = DateTime.Now;
            try { await c.AutoFocus(); }
            catch (Exception e) { c.AddLog(Strings.T("No se pudo iniciar el enfoque: %@", e.Message), LogLevel.Warning); continue; }
            if (await c.WaitForEvent("AutoFocus", start, 180) == "complete") return true;
            c.AddLog(Strings.T("Enfoque automático fallido (intento %@).", attempt), LogLevel.Warning);
            await Task.Delay(5000);
        }
        return false;
    }
    public static async Task<int?> FocuserPositionNow(this SeestarClient c) => (await c.Send("get_focuser_position")).Int("result");
    public static Task MoveFocuser(this SeestarClient c, int step) => c.Send("move_focuser", new JsonObject { ["step"] = step, ["ret_step"] = true });

    public static Task SetTargetName(this SeestarClient c, string name) =>
        c.Send("set_sequence_setting", new JsonArray(new JsonObject { ["group_name"] = name }));
    public static async Task StartStack(this SeestarClient c, bool restart = true)
    {
        if (restart && c.IsStacking && !SeestarClient.Unattended &&
            !await c.ConfirmInterrupt(Strings.T("Hay un apilado en curso. Si empiezas otro, el actual se detendrá. ¿Continuar?"))) return;
        await c.Send("iscope_start_stack", new JsonObject { ["restart"] = restart });
    }
    public static Task StopStack(this SeestarClient c) => c.Send("iscope_stop_view", new JsonObject { ["stage"] = "Stack" });
    public static Task SetGain(this SeestarClient c, int gain) => c.Send("set_control_value", new JsonArray("gain", gain));
    public static Task SetExposure(this SeestarClient c, int ms) => c.Send("set_setting", new JsonObject { ["exp_ms"] = new JsonObject { ["stack_l"] = ms } });
    public static Task SetLPFilter(this SeestarClient c, bool on) => c.Send("set_setting", new JsonObject { ["stack_lenhance"] = on });
    public static Task SetAutoFocusBeforeStack(this SeestarClient c, bool on) => c.Send("set_setting", new JsonObject { ["auto_af"] = on });
    public static Task SetDither(this SeestarClient c, bool enabled, int pixels = 50, int interval = 10) =>
        c.Send("set_setting", new JsonObject { ["stack_dither"] = new JsonObject { ["pix"] = pixels, ["interval"] = interval, ["enable"] = enabled } });
    public static Task CreateDarks(this SeestarClient c) => c.Send("start_create_dark");

    /// <summary>Crea los oscuros y espera al evento DarkLibrary.</summary>
    public static async Task<bool> CreateDarksAndWait(this SeestarClient c, double timeout = 1800)
    {
        var start = DateTime.Now;
        try { await c.StopView(); } catch { }
        await Task.Delay(1000);
        try { await c.CreateDarks(); } catch { return false; }
        return await c.WaitForEvent("DarkLibrary", start, timeout) == "complete";
    }

    public static Task StartMoonView(this SeestarClient c) => c.Send("iscope_start_view", new JsonObject { ["mode"] = "moon" });
    public static Task StartPlanetScan(this SeestarClient c) => c.Send("start_scan_planet");
    public static Task StartStarView(this SeestarClient c) => c.Send("iscope_start_view", new JsonObject { ["mode"] = "star" });
    public static Task StartPolarAlign(this SeestarClient c) => c.Send("start_polar_align");
    public static Task StopPolarAlign(this SeestarClient c) => c.Send("stop_polar_align");
    public static Task SetDewHeater(this SeestarClient c, int power) =>
        c.Send("pi_output_set2", new JsonObject { ["heater"] = new JsonObject { ["state"] = power > 0, ["value"] = power } });
    public static Task Shutdown(this SeestarClient c) => c.Send("pi_shutdown");
    public static Task<JsonObject> Albums(this SeestarClient c) => c.Send("get_albums", timeout: 30);

    public static async Task SetTimeAndLocation(this SeestarClient c, double lat, double lon)
    {
        var n = DateTime.Now;
        await c.Send("pi_set_time", new JsonObject
        {
            ["year"] = n.Year, ["mon"] = n.Month, ["day"] = n.Day, ["hour"] = n.Hour, ["min"] = n.Minute, ["sec"] = n.Second,
            ["time_zone"] = TimeZoneInfo.Local.Id,
        });
        await c.Send("set_user_location", new JsonObject { ["lat"] = lat, ["lon"] = lon, ["force"] = true });
    }

    /// <summary>Apunta a unas coordenadas J2000 y, si llega, empieza a apilar con ese nombre.</summary>
    public static async Task<(bool Ok, string Message)> GotoAndStack(this SeestarClient c, string name, double raJ2000, double decJ2000, bool lp)
    {
        var now = Astronomy.Astro.PrecessFromJ2000(raJ2000, decJ2000, DateTime.UtcNow);
        try
        {
            if (!await c.GotoAndWait(name, now.Ra, now.Dec, lp))
                return (false, Strings.T("El GoTo a %@ no terminó bien (¿nubes o poca altura?).", name));
            await c.SetTargetName(name);
            await c.StartStack();
            return (true, Strings.T("Apilando %@.", name));
        }
        catch (Exception e) { return (false, e.Message); }
    }
}
