using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Astrolabio.Core.Model;
using Astrolabio.Core.Services;
using Xunit;

namespace Astrolabio.Tests;

// Las mismas comprobaciones que CompanionTests.swift.
[Collection("Red")]
public class CompanionTests
{
    sealed class Calls { public int Stop, Skip, Park; }

    static CompanionBridge Bridge(Calls c) => new(
        () => new Dictionary<string, object?> { ["connected"] = true, ["running"] = true, ["frames"] = 12, ["target"] = "M 31" },
        () => [0xFF, 0xD8, 0xFF, 0xD9],
        () => { c.Stop++; return Task.FromResult("parado"); },
        () => { c.Skip++; return Task.FromResult("saltado"); },
        () => { c.Park++; return Task.FromResult("aparcado"); },
        () => "es");

    static HttpRequestLite Req(string method, string path, string host = "192.168.1.10:8642", string? auth = null, string? json = null)
    {
        var h = new Dictionary<string, string> { ["host"] = host };
        if (auth is not null) h["authorization"] = "Bearer " + auth;
        if (json is not null) h["content-type"] = "application/json";
        return new HttpRequestLite(method, path, h, Encoding.UTF8.GetBytes(json ?? ""));
    }

    static (HttpRequestLite.Result, HttpRequestLite?) P(string s) { var b = Encoding.UTF8.GetBytes(s); return HttpRequestLite.Parse(b, b.Length); }

    [Fact]
    public void ParsesRequestsAndRejectsAbuse()
    {
        var (res, r) = P("POST /api/pair?x=1 HTTP/1.1\r\nHost: a:1\r\nContent-Length: 4\r\n\r\nabcd");
        Assert.Equal(HttpRequestLite.Result.Ok, res);
        Assert.Equal(("POST", "/api/pair", "a:1", "abcd"), (r!.Method, r.Path, r.Headers["host"], Encoding.UTF8.GetString(r.Body)));
        Assert.Equal(HttpRequestLite.Result.Incomplete, P("GET / HTTP/1.1\r\nHost: a").Item1);
        Assert.Equal(HttpRequestLite.Result.Invalid, P("DELETE / HTTP/1.1\r\n\r\n").Item1);
        Assert.Equal(HttpRequestLite.Result.Invalid, P("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n").Item1);
        Assert.Equal(HttpRequestLite.Result.Invalid, P("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").Item1);
        Assert.Equal(HttpRequestLite.Result.Invalid, P(new string('A', 9000)).Item1);
    }

    [Theory]
    [InlineData("192.168.1.5", true)] [InlineData("10.0.0.2", true)] [InlineData("172.20.1.1", true)] [InlineData("127.0.0.1", true)]
    [InlineData("::1", true)] [InlineData("fe80::1%3", true)] [InlineData("fd12::3", true)] [InlineData("::ffff:192.168.0.4", true)]
    [InlineData("8.8.8.8", false)] [InlineData("172.32.0.1", false)] [InlineData("2001:db8::1", false)] [InlineData("::ffff:8.8.8.8", false)]
    [InlineData("", false)] [InlineData("300.1.1.1", false)]
    public void OnlyPrivateAddresses(string ip, bool ok) => Assert.Equal(ok, CompanionRouter.IsPrivate(ip));

    [Fact]
    public void PairingNeedsTokenAndCodeOnceAndExpires()
    {
        var a = new CompanionAuth(); var t = DateTime.UtcNow; a.Now = () => t;
        var p = a.StartPairing();
        Assert.Equal(6, p.Code.Length);
        Assert.Equal(CompanionAuth.PairResult.Wrong, a.Pair("otro", p.Code).Result);
        var (ok, key) = a.Pair(p.Token, p.Code);
        Assert.Equal(CompanionAuth.PairResult.Ok, ok);
        Assert.True(a.IsAuthorized("Bearer " + key));
        Assert.False(a.IsAuthorized("Bearer " + (key![0] == 'x' ? "y" : "x") + key[1..]));
        Assert.False(a.IsAuthorized(key));
        Assert.Equal(CompanionAuth.PairResult.Expired, a.Pair(p.Token, p.Code).Result);
        var q = a.StartPairing(); t = t.AddSeconds(301);
        Assert.Equal(CompanionAuth.PairResult.Expired, a.Pair(q.Token, q.Code).Result);
        var r = a.StartPairing(); var bad = r.Code == "123456" ? "654321" : "123456";
        for (var i = 0; i < 4; i++) Assert.Equal(CompanionAuth.PairResult.Wrong, a.Pair(r.Token, bad).Result);
        Assert.Equal(CompanionAuth.PairResult.Locked, a.Pair(r.Token, bad).Result);
        Assert.Equal(CompanionAuth.PairResult.Expired, a.Pair(r.Token, r.Code).Result);
        a.RevokeAll();
        Assert.False(a.IsAuthorized("Bearer " + key));
    }

    [Fact]
    public void RateLimiterWorks()
    {
        var l = new RateLimiter(3, 1); var t = DateTime.UtcNow; l.Now = () => t;
        Assert.True(l.Allow("a") && l.Allow("a") && l.Allow("a"));
        Assert.False(l.Allow("a")); Assert.True(l.Allow("b"));
        t = t.AddSeconds(1.1);
        Assert.True(l.Allow("a")); Assert.False(l.Allow("a"));
    }

    [Fact]
    public async Task RouterAuthHostAndActions()
    {
        var calls = new Calls(); var auth = new CompanionAuth();
        var r = new CompanionRouter(auth, Bridge(calls), "192.168.1.10:8642");
        Assert.Equal(403, (await r.Handle(Req("GET", "/"), "8.8.8.8")).Status);
        Assert.Equal(403, (await r.Handle(Req("GET", "/", "evil.example:8642"), "192.168.1.20")).Status);
        var page = await r.Handle(Req("GET", "/"), "192.168.1.20");
        var html = Encoding.UTF8.GetString(page.Body);
        Assert.Equal(200, page.Status);
        Assert.Contains("default-src 'none'", page.Extra!["Content-Security-Policy"]);
        Assert.DoesNotContain("__NONCE__", html); Assert.DoesNotContain("__I18N__", html);
        Assert.Equal(401, (await r.Handle(Req("GET", "/api/status"), "192.168.1.20")).Status);
        Assert.Equal(401, (await r.Handle(Req("POST", "/api/park", auth: new string('a', 40)), "192.168.1.20")).Status);
        Assert.Equal(0, calls.Park);
        var p = auth.StartPairing();
        Assert.Equal(401, (await r.Handle(Req("POST", "/api/pair", json: $$"""{"pair":"{{p.Token}}","code":"x"}"""), "192.168.1.20")).Status);
        var ok = await r.Handle(Req("POST", "/api/pair", json: $$"""{"pair":"{{p.Token}}","code":"{{p.Code}}"}"""), "192.168.1.20");
        var key = (string)JsonNode.Parse(ok.Body)!["key"]!;
        var st = await r.Handle(Req("GET", "/api/status", auth: key), "192.168.1.20");
        Assert.Equal(200, st.Status); Assert.Contains("M 31", Encoding.UTF8.GetString(st.Body));
        Assert.Equal("image/jpeg", (await r.Handle(Req("GET", "/api/image.jpg", auth: key), "192.168.1.20")).ContentType);
        Assert.Equal(200, (await r.Handle(Req("POST", "/api/skip", auth: key), "192.168.1.20")).Status);
        Assert.Equal(404, (await r.Handle(Req("GET", "/api/park", auth: key), "192.168.1.20")).Status);
        await r.Handle(Req("POST", "/api/stop", auth: key), "192.168.1.20");
        await r.Handle(Req("POST", "/api/stop", auth: key), "192.168.1.20");
        Assert.Equal(429, (await r.Handle(Req("POST", "/api/park", auth: key), "192.168.1.20")).Status);
        Assert.Equal((1, 2, 0), (calls.Skip, calls.Stop, calls.Park));
    }

    [Fact]
    public async Task PairingAttemptsAreRateLimited()
    {
        var r = new CompanionRouter(new CompanionAuth(), Bridge(new Calls()), "192.168.1.10:8642");
        var statuses = new List<int>();
        for (var i = 0; i < 7; i++) statuses.Add((await r.Handle(Req("POST", "/api/pair", json: """{"pair":"a","code":"1"}"""), "192.168.1.30")).Status);
        Assert.All(statuses.Take(5), s => Assert.Equal(401, s));
        Assert.All(statuses.Skip(5), s => Assert.Equal(429, s));
    }

    [Fact]
    public async Task RealServerOverLoopback()
    {
        var file = Path.Combine(Path.GetTempPath(), $"companion-{Guid.NewGuid()}.json");
        var server = new CompanionServer(file);
        var port = Random.Shared.Next(20000, 40000);
        server.Start(Bridge(new Calls()), port, "127.0.0.1");
        try
        {
            Assert.True(server.IsRunning);
            using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/") };
            Assert.Contains("<html", await http.GetStringAsync(""));
            Assert.Equal(401, (int)(await http.GetAsync("api/status")).StatusCode);
            server.StartPairing();
            var p = server.Pairing!;
            var resp = await http.PostAsync("api/pair", new StringContent($$"""{"pair":"{{p.Token}}","code":"{{p.Code}}"}""", Encoding.UTF8, "application/json"));
            var key = (string)JsonNode.Parse(await resp.Content.ReadAsStringAsync())!["key"]!;
            var req = new HttpRequestMessage(HttpMethod.Get, "api/status");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            var st = await http.SendAsync(req);
            Assert.Equal(200, (int)st.StatusCode);
            Assert.Contains("frames", await st.Content.ReadAsStringAsync());
            Assert.Equal(1, server.DeviceCount);
            var saved = File.ReadAllText(file);
            Assert.DoesNotContain(key, saved);
            Assert.Contains(CompanionAuth.Hash(key), saved);
        }
        finally { server.Stop(); File.Delete(file); }
    }

    [Fact]
    public void BackupNeverCarriesPhoneAccess()
    {
        var s = new AppSettings { CompanionEnabled = true, PemPath = "C:/clave.pem" };
        var b = BackupFile.Make(s, [], [], []);
        Assert.False(b.Settings.ContainsKey("CompanionEnabled"));
        Assert.False(b.Settings.ContainsKey("PemPath"));
        var restored = b.RestoredSettings(new AppSettings { CompanionEnabled = false });
        Assert.False(restored.CompanionEnabled);
    }
}
