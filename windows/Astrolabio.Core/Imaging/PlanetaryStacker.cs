namespace Astrolabio.Core.Imaging;

/// <summary>Fotograma RGB en coma flotante (0–1).</summary>
public sealed class RgbFrame(int w, int h, float[] r, float[] g, float[] b)
{
    public int Width { get; } = w; public int Height { get; } = h;
    public float[] R = r, G = g, B = b;
    public float[] Luminance() { var l = new float[Width * Height]; for (var i = 0; i < l.Length; i++) l[i] = 0.2126f * R[i] + 0.7152f * G[i] + 0.0722f * B[i]; return l; }
}

public interface IFrameSource
{
    int Width { get; }
    int Height { get; }
    int EstimatedFrames { get; }
    void Rewind();
    RgbFrame? Next();
}

/// <summary>Lector de vídeos SER (formato habitual de las cámaras planetarias), port del de macOS.</summary>
public sealed class SerFrameSource : IFrameSource
{
    private readonly byte[] _data;
    private readonly int _colorId, _bps, _planes;
    private readonly float _max;
    private int _index;
    public int Width { get; } public int Height { get; } public int EstimatedFrames { get; }

    public SerFrameSource(string path)
    {
        _data = File.ReadAllBytes(path);
        if (_data.Length <= 178 || System.Text.Encoding.ASCII.GetString(_data, 0, 14) != "LUCAM-RECORDER") throw new InvalidDataException(Strings.T("No es un archivo SER válido."));
        int I32(int o) => BitConverter.ToInt32(_data, o);
        _colorId = I32(18); Width = I32(26); Height = I32(30);
        var depth = I32(34); var count = I32(38);
        _bps = depth > 8 ? 2 : 1;
        _planes = _colorId is 100 or 101 ? 3 : 1;
        _max = (1 << Math.Clamp(depth, 1, 16)) - 1;
        var frameBytes = Width * Height * _planes * _bps;
        if (Width <= 0 || Height <= 0 || frameBytes <= 0) throw new InvalidDataException(Strings.T("Cabecera SER no válida."));
        EstimatedFrames = Math.Min(count, (_data.Length - 178) / frameBytes);
    }

    public void Rewind() => _index = 0;

    public RgbFrame? Next()
    {
        if (_index >= EstimatedFrames) return null;
        var start = 178 + _index++ * Width * Height * _planes * _bps;
        int n = Width * Height; var r = new float[n]; var g = new float[n]; var b = new float[n]; var k = 1 / _max;
        float S(int i) => _bps == 1 ? _data[start + i] * k : (ushort)(_data[start + 2 * i] | (_data[start + 2 * i + 1] << 8)) * k;
        if (_planes == 3)
        {
            var bgr = _colorId == 101;
            for (var i = 0; i < n; i++) { float c0 = S(3 * i), c1 = S(3 * i + 1), c2 = S(3 * i + 2); r[i] = bgr ? c2 : c0; g[i] = c1; b[i] = bgr ? c0 : c2; }
        }
        else if (_colorId is >= 8 and <= 11)
        {
            var (rx, ry) = new[] { (0, 0), (1, 0), (0, 1), (1, 1) }[_colorId - 8];
            for (var y = 0; y < Height; y++)
            for (var x = 0; x < Width; x++)
            {
                int bx = x & ~1, by = y & ~1;
                if (bx + 1 >= Width || by + 1 >= Height) continue;
                var i = y * Width + x;
                r[i] = S((by + ry) * Width + bx + rx);
                b[i] = S((by + 1 - ry) * Width + bx + 1 - rx);
                g[i] = (S((by + ry) * Width + bx + 1 - rx) + S((by + 1 - ry) * Width + bx + rx)) / 2;
            }
        }
        else for (var i = 0; i < n; i++) { var v = S(i); r[i] = v; g[i] = v; b[i] = v; }
        return new RgbFrame(Width, Height, r, g, b);
    }
}

public sealed record StackResult(RgbFrame Stacked, RgbFrame BestFrame, double[] Qualities, int Used, int Analyzed);

/// <summary>Ordena los fotogramas por nitidez, alinea los mejores y los promedia (port de PlanetaryStacker.swift).</summary>
public static class PlanetaryStacker
{
    public static (double Cx, double Cy, int Box)? Locate(float[] l, int w, int h)
    {
        var step = Math.Max(1, l.Length / 20000);
        var sample = new List<float>(); float hi = 0;
        for (var i = 0; i < l.Length; i += step) { sample.Add(l[i]); hi = Math.Max(hi, l[i]); }
        sample.Sort();
        var lo = sample[sample.Count / 10];
        if (hi - lo <= 0.02f) return null;
        var thr = lo + 0.2f * (hi - lo);
        double sx = 0, sy = 0, sw = 0; int minX = w, maxX = 0, minY = h, maxY = 0;
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var v = l[y * w + x];
            if (v <= thr) continue;
            var wt = v - thr; sx += wt * x; sy += wt * y; sw += wt;
            minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
        }
        return sw > 0 ? (sx / sw, sy / sw, Math.Max(maxX - minX, maxY - minY)) : null;
    }

    public static double Sharpness(float[] l, int w, int h, double cx, double cy, int half)
    {
        int x0 = Math.Max(0, (int)cx - half) & ~1, x1 = Math.Min(w - 2, (int)cx + half), y0 = Math.Max(0, (int)cy - half) & ~1, y1 = Math.Min(h - 2, (int)cy + half);
        int bw = (x1 - x0) / 2, bh = (y1 - y0) / 2;
        if (bw <= 4 || bh <= 4) return 0;
        var bin = new float[bw * bh];
        for (var by = 0; by < bh; by++) for (var bx = 0; bx < bw; bx++)
        {
            int r0 = (y0 + 2 * by) * w + x0 + 2 * bx, r1 = r0 + w;
            bin[by * bw + bx] = (l[r0] + l[r0 + 1] + l[r1] + l[r1 + 1]) * 0.25f;
        }
        double e = 0, s = 0;
        for (var y = 1; y < bh - 1; y++) for (var x = 1; x < bw - 1; x++)
        {
            var c = bin[y * bw + x];
            var lap = 4 * c - bin[y * bw + x - 1] - bin[y * bw + x + 1] - bin[(y - 1) * bw + x] - bin[(y + 1) * bw + x];
            e += lap * lap; s += c;
        }
        var n = (double)(bw - 2) * (bh - 2); var mean = s / n;
        return mean > 0 ? e / n / (mean * mean) : 0;
    }

    public static RgbFrame Crop(RgbFrame f, double cx, double cy, int size)
    {
        var n = size * size; var r = new float[n]; var g = new float[n]; var b = new float[n];
        double ox = cx - size / 2.0, oy = cy - size / 2.0;
        int fx0 = (int)Math.Floor(ox), fy0 = (int)Math.Floor(oy);
        float tx = (float)(ox - fx0), ty = (float)(oy - fy0);
        float w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
        for (var y = 0; y < size; y++)
        {
            var y0 = fy0 + y; if (y0 < 0 || y0 + 1 >= f.Height) continue;
            for (var x = 0; x < size; x++)
            {
                var x0 = fx0 + x; if (x0 < 0 || x0 + 1 >= f.Width) continue;
                int i00 = y0 * f.Width + x0, i10 = i00 + 1, i01 = i00 + f.Width, i11 = i01 + 1, o = y * size + x;
                r[o] = f.R[i00] * w00 + f.R[i10] * w10 + f.R[i01] * w01 + f.R[i11] * w11;
                g[o] = f.G[i00] * w00 + f.G[i10] * w10 + f.G[i01] * w01 + f.G[i11] * w11;
                b[o] = f.B[i00] * w00 + f.B[i10] * w10 + f.B[i01] * w01 + f.B[i11] * w11;
            }
        }
        return new RgbFrame(size, size, r, g, b);
    }

    public static (double Dx, double Dy) ResidualShift(float[] reference, float[] img, int size, int range = 3)
    {
        var m = range + 2; var cost = new double[2 * range + 1, 2 * range + 1];
        (int dx, int dy, double c) best = (0, 0, double.MaxValue);
        for (var dy = -range; dy <= range; dy++) for (var dx = -range; dx <= range; dx++)
        {
            double ssd = 0;
            for (var y = m; y < size - m; y += 2) for (var x = m; x < size - m; x += 2)
            { var d = reference[y * size + x] - img[(y + dy) * size + x + dx]; ssd += d * d; }
            cost[dy + range, dx + range] = ssd;
            if (ssd < best.c) best = (dx, dy, ssd);
        }
        static double Para(double a, double b, double c) { var den = a - 2 * b + c; return den > 1e-12 ? 0.5 * (a - c) / den : 0; }
        double sx = best.dx, sy = best.dy; int ix = best.dx + range, iy = best.dy + range;
        if (ix > 0 && ix < 2 * range) sx += Para(cost[iy, ix - 1], cost[iy, ix], cost[iy, ix + 1]);
        if (iy > 0 && iy < 2 * range) sy += Para(cost[iy - 1, ix], cost[iy, ix], cost[iy + 1, ix]);
        return (sx, sy);
    }

    public static StackResult Stack(IFrameSource source, double keepPercent, bool refine, Action<string, double>? progress = null)
    {
        source.Rewind();
        var info = new List<(double Q, double Cx, double Cy)>(); var half = 0; var total = Math.Max(1, source.EstimatedFrames);
        while (info.Count < 5000 && source.Next() is { } f)
        {
            var l = f.Luminance();
            if (Locate(l, f.Width, f.Height) is not { } loc) { info.Add((0, 0, 0)); continue; }
            if (half == 0) half = Math.Max(24, (int)(loc.Box * 0.75) + 12);
            info.Add((Sharpness(l, f.Width, f.Height, loc.Cx, loc.Cy, half), loc.Cx, loc.Cy));
            if (info.Count % 10 == 0) progress?.Invoke(Strings.T("Analizando la nitidez (%@ fotogramas)…", info.Count), Math.Min(0.5, info.Count / (double)total * 0.5));
        }
        if (info.Count == 0) throw new InvalidDataException(Strings.T("El vídeo no tiene fotogramas legibles."));
        if (half == 0) throw new InvalidDataException(Strings.T("No encuentro ningún objeto brillante en el vídeo."));
        var size = Math.Min(2 * half + 32, Math.Min(source.Width, source.Height)) & ~1;
        var order = Enumerable.Range(0, info.Count).Where(i => info[i].Q > 0).OrderByDescending(i => info[i].Q).ToList();
        if (order.Count == 0) throw new InvalidDataException(Strings.T("No encuentro ningún objeto brillante en el vídeo."));
        var keep = Math.Max(1, (int)(order.Count * keepPercent / 100));
        var chosen = order.Take(keep).ToHashSet(); var bestIndex = order[0];
        source.Rewind();
        RgbFrame? reference = null; var idx = 0;
        while (source.Next() is { } f) { if (idx == bestIndex) { reference = Crop(f, info[idx].Cx, info[idx].Cy, size); break; } idx++; }
        var refL = reference!.Luminance();
        source.Rewind();
        var n = size * size; var sr = new float[n]; var sg = new float[n]; var sb = new float[n]; var used = 0; idx = 0;
        while (idx < info.Count && source.Next() is { } f)
        {
            var i = idx++;
            if (!chosen.Contains(i)) continue;
            double cx = info[i].Cx, cy = info[i].Cy;
            if (refine && i != bestIndex) { var sh = ResidualShift(refL, Crop(f, cx, cy, size).Luminance(), size); cx += sh.Dx; cy += sh.Dy; }
            var c = Crop(f, cx, cy, size);
            for (var k = 0; k < n; k++) { sr[k] += c.R[k]; sg[k] += c.G[k]; sb[k] += c.B[k]; }
            if (++used % 5 == 0) progress?.Invoke(Strings.T("Alineando y apilando (%@ de %@)…", used, keep), 0.5 + 0.5 * used / keep);
        }
        var inv = 1f / Math.Max(1, used);
        for (var k = 0; k < n; k++) { sr[k] *= inv; sg[k] *= inv; sb[k] *= inv; }
        return new StackResult(new RgbFrame(size, size, sr, sg, sb), reference, info.Select(x => x.Q).ToArray(), used, info.Count);
    }

    public sealed record Finish(double Fine = 1.2, double Medium = 0.6, double Gamma = 1.0, bool Balance = true);

    private static float[] Blur(float[] c, int w, int h, double sigma)
    {
        var rad = Math.Max(1, (int)Math.Ceiling(sigma * 3));
        var k = Enumerable.Range(-rad, 2 * rad + 1).Select(i => (float)Math.Exp(-i * i / (2 * sigma * sigma))).ToArray();
        var sum = k.Sum(); for (var i = 0; i < k.Length; i++) k[i] /= sum;
        var tmp = new float[c.Length]; var o = new float[c.Length];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) { float a = 0; for (var j = -rad; j <= rad; j++) a += k[j + rad] * c[y * w + Math.Clamp(x + j, 0, w - 1)]; tmp[y * w + x] = a; }
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) { float a = 0; for (var j = -rad; j <= rad; j++) a += k[j + rad] * tmp[Math.Clamp(y + j, 0, h - 1) * w + x]; o[y * w + x] = a; }
        return o;
    }

    /// <summary>Realce de detalle, niveles y equilibrio de color; devuelve BGRA de 8 bits.</summary>
    public static RenderedImage FinishImage(RgbFrame f, Finish o)
    {
        float[] Sharpen(float[] c)
        {
            if (o.Fine <= 0 && o.Medium <= 0) return c;
            var b1 = Blur(c, f.Width, f.Height, 1.0); var b2 = Blur(c, f.Width, f.Height, 2.5);
            var r = new float[c.Length];
            for (var i = 0; i < c.Length; i++) r[i] = c[i] + (float)o.Fine * (c[i] - b1[i]) + (float)o.Medium * (b1[i] - b2[i]);
            return r;
        }
        var R = Sharpen(f.R); var G = Sharpen(f.G); var B = Sharpen(f.B);
        var l = new float[R.Length]; for (var i = 0; i < l.Length; i++) l[i] = 0.2126f * R[i] + 0.7152f * G[i] + 0.0722f * B[i];
        var sorted = l.Where((_, i) => i % Math.Max(1, l.Length / 40000) == 0).OrderBy(x => x).ToArray();
        var black = sorted[sorted.Length / 20];
        var white = Math.Max(black + 1e-3f, sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * 0.999))]);
        float gr = 1, gb = 1;
        if (o.Balance)
        {
            var thr = black + 0.25f * (white - black); double mr = 0, mg = 0, mb = 0;
            for (var i = 0; i < l.Length; i++) if (l[i] > thr) { mr += R[i]; mg += G[i]; mb += B[i]; }
            if (mr > 0 && mb > 0) { gr = (float)(mg / mr); gb = (float)(mg / mb); }
        }
        var scale = 1 / (white - black); var inv = 1 / Math.Max(0.2, o.Gamma);
        byte Lv(float v, float gain) { var x = Math.Clamp((v * gain - black) * scale, 0, 1); return (byte)(Math.Pow(x, inv) * 255); }
        var outp = new byte[l.Length * 4];
        for (var i = 0; i < l.Length; i++) { outp[4 * i] = Lv(B[i], gb); outp[4 * i + 1] = Lv(G[i], 1); outp[4 * i + 2] = Lv(R[i], gr); outp[4 * i + 3] = 255; }
        return new RenderedImage(f.Width, f.Height, outp);
    }
}
