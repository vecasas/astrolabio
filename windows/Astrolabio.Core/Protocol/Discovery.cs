using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace Astrolabio.Core.Protocol;

public sealed record DiscoveredScope(string Ip, string Name, string Model);

/// <summary>Busca Seestar en la red local con scan_iscope por difusión UDP al puerto 4720.</summary>
public static class SeestarDiscovery
{
    public const int Port = 4720;

    public static async Task<List<DiscoveredScope>> Scan(double timeout = 3)
    {
        using var udp = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        var payload = Encoding.UTF8.GetBytes("{\"id\":1,\"method\":\"scan_iscope\",\"params\":\"\"}\r\n");
        var targets = new HashSet<IPAddress>([IPAddress.Broadcast, .. SubnetBroadcasts()]);
        foreach (var t in targets) { try { await udp.SendAsync(payload, new IPEndPoint(t, Port)); } catch { } }
        var found = new Dictionary<string, DiscoveredScope>();
        var deadline = DateTime.Now.AddSeconds(timeout);
        var resent = false;
        while (DateTime.Now < deadline)
        {
            var left = deadline - DateTime.Now;
            using var cts = new CancellationTokenSource(left > TimeSpan.Zero ? left : TimeSpan.FromMilliseconds(1));
            try
            {
                var r = await udp.ReceiveAsync(cts.Token);
                foreach (var line in Encoding.UTF8.GetString(r.Buffer).Split("\r\n", StringSplitOptions.RemoveEmptyEntries))
                {
                    if (JsonPath.Parse(line) is not { } obj) continue;
                    if (obj.Str("method") == "scan_iscope" && obj["result"] is null) continue;
                    var name = obj.Str("result.device_name") ?? obj.Str("result.name") ?? obj.Str("name") ?? "Seestar";
                    var model = obj.Str("result.product_model") ?? obj.Str("product_model") ?? "";
                    var ip = obj.Str("result.ip") ?? r.RemoteEndPoint.Address.ToString();
                    found[ip] = new DiscoveredScope(ip, name, model);
                }
            }
            catch (OperationCanceledException) { break; }
            if (!resent && DateTime.Now.AddSeconds(timeout / 2) > deadline)
            {
                foreach (var t in targets) { try { await udp.SendAsync(payload, new IPEndPoint(t, Port)); } catch { } }
                resent = true;
            }
        }
        return found.Values.OrderBy(s => s.Ip).ToList();
    }

    /// <summary>Direcciones de difusión de las interfaces IPv4 activas (p. ej. 192.168.0.255).</summary>
    private static IEnumerable<IPAddress> SubnetBroadcasts()
    {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask is null) continue;
                var ip = ua.Address.GetAddressBytes();
                var mask = ua.IPv4Mask.GetAddressBytes();
                var b = new byte[4];
                for (var i = 0; i < 4; i++) b[i] = (byte)(ip[i] | ~mask[i]);
                yield return new IPAddress(b);
            }
        }
    }
}
