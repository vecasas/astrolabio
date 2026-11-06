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
        History.ContextProvider = () =>
        {
            var s = Settings;
            var h = WeatherService.Nearest(DateTime.UtcNow, Weather);
            return new SessionContext(s.SiteName, s.Latitude, s.Longitude, s.Gain, Client.LpFilter, s.DitherEnabled, s.DitherPixels, s.DitherInterval,
                h is null ? null : new WeatherSnapshot(h.CloudCover, h.Temperature, h.DewPoint, h.Humidity, h.Wind),
                path => { if (Live.Image is not { } img) return false; img.Save(path); return true; });
        };
        _ = WeatherLoop();
        if (Settings.AutoConnect) Dispatcher.UIThread.Post(async () => await Connect());
    }

    public async Task Connect()
    {
        await Client.ConnectAsync(Settings.TelescopeHost);
        if (Client.IsConnected) Live.Connect(Settings.TelescopeHost);
    }

    public void Disconnect() { Live.Disconnect(); Client.Disconnect(); }

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
        var f = await Task.Run(() => Planner.Evaluate(Catalog.Objects, n, s.Latitude, s.Longitude, s.MinAltitude, s.Fov, w));
        Dispatcher.UIThread.Post(() => { Night = n; Forecasts = f; TonightUpdated?.Invoke(); });
    }
}
