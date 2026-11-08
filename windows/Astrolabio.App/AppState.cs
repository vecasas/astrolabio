using Avalonia.Threading;
using Astrolabio.Core;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Model;
using Astrolabio.Core.Protocol;
using Astrolabio.Core.Services;

namespace Astrolabio.App;

/// <summary>Estado compartido por toda la interfaz (equivale a los objetos de entorno de la versión de macOS).</summary>
public sealed class AppState
{
    public static AppState Instance { get; } = new();

    public AppSettings Settings { get; } = AppSettings.Load();
    public SeestarClient Client { get; }
    public PlanStore Plan { get; } = new();
    public SessionRunner Runner { get; }
    public ObservationLog History { get; } = new();
    public LiveModel Live { get; }
    public NightGuard Guard { get; }
    public List<WeatherHour> Weather { get; private set; } = [];
    public Astro.Night? Night { get; private set; }
    public List<TargetForecast> Forecasts { get; private set; } = [];
    public event Action? TonightUpdated;
    public event Action? WeatherUpdated;

    private AppState()
    {
        // Se crean en el hilo de la interfaz para que publiquen sus cambios en él.
        Client = new SeestarClient { SignerProvider = () => Settings.MakeSigner() };
        Runner = new SessionRunner();
        Live = new LiveModel(Client);
        History.Attach(Client, () => Settings.ExposureMs);
        Guard = new NightGuard(Client, Settings, () => Weather);
        Live.StarMetricsMeasured += Guard.Handle;
        Runner.Guard = Guard;
        History.ContextProvider = () =>
        {
            var s = Settings;
            var h = WeatherService.Nearest(DateTime.UtcNow, Weather);
            return new SessionContext(s.SiteName, s.Latitude, s.Longitude, s.Gain, Client.LpFilter, s.DitherEnabled, s.DitherPixels, s.DitherInterval,
                h is null ? null : new WeatherSnapshot(h.CloudCover, h.Temperature, h.DewPoint, h.Humidity, h.Wind),
                path => { if (Live.Image is not { } img) return false; img.Save(path); return true; });
        };
        Client.GotoLimitsProvider = () => Settings.GotoLimits;
        Client.RecenterToleranceProvider = () => Settings.RecenterEnabled ? Settings.RecenterToleranceArcmin : null;
        Client.ConfirmInterrupt = text => Dispatcher.UIThread.InvokeAsync(() =>
            Views.Ask.YesNo(Strings.T("¿Interrumpir el apilado?"), text, Strings.T("Continuar"), Strings.T("Cancelar")));
        _ = WeatherLoop();
        _ = HealthLoop();
        if (Settings.AutoConnect) Dispatcher.UIThread.Post(async () => await Connect());
    }

    public async Task Connect()
    {
        await Client.ConnectAsync(Settings.TelescopeHost);
        if (Client.IsConnected) Live.Connect(Settings.TelescopeHost);
    }

    public void Disconnect() { Live.Disconnect(); Client.Disconnect(); }

    private readonly AlertLimiter _alerts = new(TimeSpan.FromMinutes(30));
    private DateTime? _disconnectedSince;
    private bool _resumeChecked;

    /// <summary>Cada minuto: retoma un plan interrumpido y avisa de batería baja, poca memoria o telescopio mudo.</summary>
    private async Task HealthLoop()
    {
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(60));
            await Dispatcher.UIThread.InvokeAsync(Guard.Tick);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (!_resumeChecked && Client.IsConnected)
                {
                    _resumeChecked = true;
                    if (!Runner.IsRunning && SessionRunner.PendingResume() is { } saved &&
                        Plan.Items.Any(i => i.Status is PlanItem.ItemStatus.Pending or PlanItem.ItemStatus.Running))
                        Runner.Start(Client, Settings, Plan, saved);
                }
                if (Client.IsConnected) _disconnectedSince = null; else _disconnectedSince ??= DateTime.Now;
                if (!Settings.HealthAlerts) return;
                var issues = HealthCheck.Issues(Client.IsConnected, Client.Battery, Client.ChargerStatus == "Charging", Client.FreeStorageMB,
                    Runner.IsRunning, _disconnectedSince is DateTime d ? (DateTime.Now - d).TotalSeconds : 0, HealthCheck.FreeMB(Settings.SaveFolder));
                foreach (var i in issues.Where(i => _alerts.ShouldSend(i.Kind, DateTime.Now)))
                {
                    Client.AddLog(i.Message, LogLevel.Warning);
                    Settings.Notify("Astrolabio", i.Message);
                }
            });
        }
    }

    private async Task WeatherLoop()
    {
        while (true)
        {
            try
            {
                var w = await WeatherService.Forecast(Settings.Latitude, Settings.Longitude);
                Dispatcher.UIThread.Post(() => { Weather = w; WeatherUpdated?.Invoke(); });
            }
            catch { }
            await RecomputeTonight();
            await Task.Delay(TimeSpan.FromMinutes(30));
        }
    }

    public async Task RecomputeTonight()
    {
        var s = Settings; var w = Weather;
        var n = Astro.NightFor(DateTime.Now, s.Latitude, s.Longitude);
        var f = await Task.Run(() => Planner.Evaluate(Catalog.Featured, n, s.Latitude, s.Longitude, s.MinAltitude, s.Fov, w));
        Dispatcher.UIThread.Post(() => { Night = n; Forecasts = f; TonightUpdated?.Invoke(); });
    }
}
