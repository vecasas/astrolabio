using System.Text;

namespace Astrolabio.Core.Imaging;

/// <summary>Fotograma recibido del puerto de imagen (datos de 16 bits).</summary>
public sealed record RawFrame(bool Stacked, int Width, int Height, ushort[] Pixels, int Channels)
{
    public DateTime Received { get; } = DateTime.Now;
}

/// <summary>Imagen lineal en planos RGB (valores de 0 a 65535).</summary>
public sealed class LinearImage(int width, int height, float[] r, float[] g, float[] b)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public float[] R { get; set; } = r;
    public float[] G { get; set; } = g;
    public float[] B { get; set; } = b;
    public LinearImage Clone() => new(Width, Height, (float[])R.Clone(), (float[])G.Clone(), (float[])B.Clone());
}

public sealed record ProcessingOptions
{
    public double TargetBackground { get; init; } = 0.16;
    public double ShadowsClip { get; init; } = 2.8;
    public bool RemoveGradient { get; init; } = true;
    public double Saturation { get; init; } = 1.3;
    public bool Denoise { get; init; } = true;
    public bool Linked { get; init; } = true;
    public bool CropEdges { get; init; } = true;
    public bool ColorBalance { get; init; } = true;
}

/// <summary>Imagen de 8 bits lista para mostrar (BGRA, como espera Avalonia).</summary>
public sealed record RenderedImage(int Width, int Height, byte[] Bgra);

/// <summary>
/// Procesado de la vista en directo (el mismo que la versión de macOS): recorte de los bordes del
/// apilado, modelo polinómico del fondo, fondo neutro, color de las estrellas, ruido y estirado.
/// </summary>
public static class ImageProcessing
{
    public const float Pedestal = 1500;

    public static LinearImage Linear(RawFrame f)
    {
        if (f.Channels == 3)
        {
            var n = f.Width * f.Height;
            var r = new float[n]; var g = new float[n]; var b = new float[n];
            for (var i = 0; i < n; i++) { r[i] = f.Pixels[3 * i]; g[i] = f.Pixels[3 * i + 1]; b[i] = f.Pixels[3 * i + 2]; }
            return new LinearImage(f.Width, f.Height, r, g, b);
        }
        // Bayer GRBG → superpíxel (mitad de resolución).
        int w2 = f.Width / 2, h2 = f.Height / 2, W = f.Width;
        var rr = new float[w2 * h2]; var gg = new float[w2 * h2]; var bb = new float[w2 * h2];
        for (var y = 0; y < h2; y++)
        {
            int row0 = 2 * y * W, row1 = row0 + W;
            for (var x = 0; x < w2; x++)
            {
                var x0 = 2 * x; var o = y * w2 + x;
                gg[o] = (f.Pixels[row0 + x0] + f.Pixels[row1 + x0 + 1]) * 0.5f;
                rr[o] = f.Pixels[row0 + x0 + 1];
                bb[o] = f.Pixels[row1 + x0];
            }
        }
        return new LinearImage(w2, h2, rr, gg, bb);
    }

    private static float QuickMedian(float[] v)
    {
        if (v.Length == 0) return 0;
        var step = Math.Max(1, v.Length / 4000);
        var s = new List<float>(v.Length / step + 1);
        for (var i = 0; i < v.Length; i += step) s.Add(v[i]);
        s.Sort();
        return s[s.Count / 2];
    }

    private static (float Med, float Mad) MedianMad(float[] data, int step = 7)
    {
        var s = new List<float>();
        for (var i = 0; i < data.Length; i += step) s.Add(data[i]);
        if (s.Count == 0) return (0, 1);
        s.Sort();
        var med = s[s.Count / 2];
        var dev = s.Select(x => Math.Abs(x - med)).OrderBy(x => x).ToList();
        return (med, Math.Max(dev[dev.Count / 2] * 1.4826f, 1));
    }

    public static double Mtf(double x, double m)
    {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        if (m == 0.5) return x;
        return (m - 1) * x / ((2 * m - 1) * x - m);
    }

    // ------------------------------------------------------------ Bordes del apilado

    public static LinearImage CropStackEdges(LinearImage img)
    {
        int w = img.Width, h = img.Height;
        if (w <= 128 || h <= 128) return img;
        var maxCut = Math.Max(16, Math.Min(w, h) / 9);

        (float N, float C)[] Metrics(int count, Func<int, int> index)
        {
            var segments = Math.Max(5, count / 200);
            var segLen = count / segments;
            var res = new (float, float)[segments];
            for (var s = 0; s < segments; s++)
            {
                var diffs = new List<float>(); var chroma = new List<float>();
                for (var k = s * segLen + 2; k < (s + 1) * segLen; k += 2)
                {
                    int i = index(k), j = index(k - 2);
                    diffs.Add(Math.Abs(img.G[i] - img.G[j]));
                    chroma.Add(img.B[i] - img.R[i]);
                }
                diffs.Sort(); chroma.Sort();
                res[s] = diffs.Count == 0 ? (0, 0) : (diffs[diffs.Count / 2], chroma[chroma.Count / 2]);
            }
            return res;
        }
        (float, float)[] RowM(int y) => Metrics(w, x => y * w + x);
        (float, float)[] ColM(int x) => Metrics(h, y => y * w + x);

        int Cut(Func<int, (float N, float C)[]> m, int size, bool fromEnd)
        {
            (float N, float C)[] Line(int k) => m(fromEnd ? size - 1 - k : k);
            var ks = Enumerable.Range(0, 12).Select(i => maxCut + 4 * i).ToArray();
            var refs = ks.Select(Line).ToArray();
            var segments = refs[0].Length;
            var refNoise = new float[segments]; var mc = new double[segments]; var slope = new double[segments];
            var mk = ks.Average();
            for (var s = 0; s < segments; s++)
            {
                refNoise[s] = refs.Select(r => r[s].N).OrderBy(x => x).ElementAt(refs.Length / 2);
                var cs = refs.Select(r => (double)r[s].C).ToArray();
                mc[s] = cs.Average();
                double sxy = 0, sxx = 0;
                for (var i = 0; i < ks.Length; i++) { sxy += (ks[i] - mk) * (cs[i] - mc[s]); sxx += (ks[i] - mk) * (ks[i] - mk); }
                slope[s] = sxx > 0 ? sxy / sxx : 0;
            }
            var raw = Enumerable.Range(0, maxCut + 2).Select(Line).ToArray();
            (float N, float C) Smoothed(int k, int s)
            {
                int lo = Math.Max(0, k - 2), hi = Math.Min(raw.Length - 1, k + 2);
                var ns = Enumerable.Range(lo, hi - lo + 1).Select(i => raw[i][s].N).OrderBy(x => x).ToArray();
                var cs = Enumerable.Range(lo, hi - lo + 1).Select(i => raw[i][s].C).OrderBy(x => x).ToArray();
                return (ns[ns.Length / 2], cs[cs.Length / 2]);
            }
            int last = -1, quiet = 0;
            for (var k = 0; k < maxCut; k++)
            {
                var flagged = false;
                for (var s = 0; s < segments; s++)
                {
                    var (n, c) = Smoothed(k, s);
                    var expected = mc[s] + slope[s] * (k - mk);
                    if (n > refNoise[s] * 1.45 + 1 || Math.Abs(c - expected) > Math.Max(30, refNoise[s] * 2.5)) flagged = true;
                }
                if (flagged) { last = k; quiet = 0; }
                else if (++quiet > 12) break;
            }
            return last < 3 ? 0 : last + 1 + 20;
        }

        int top = Cut(RowM, h, false), bottom = Cut(RowM, h, true), left = Cut(ColM, w, false), right = Cut(ColM, w, true);
        if (top + bottom + left + right == 0 || w - left - right <= w / 2 || h - top - bottom <= h / 2) return img;
        int nw = w - left - right, nh = h - top - bottom;
        float[] Crop(float[] c)
        {
            var o = new float[nw * nh];
            for (var y = 0; y < nh; y++) Array.Copy(c, (y + top) * w + left, o, y * nw, nw);
            return o;
        }
        return new LinearImage(nw, nh, Crop(img.R), Crop(img.G), Crop(img.B));
    }

    // ------------------------------------------------------------ Fondo y color

    public static void SubtractBackgroundModel(LinearImage img)
    {
        int w = img.Width, h = img.Height;
        int gx = Math.Max(6, w / 64), gy = Math.Max(6, h / 64);
        static double[] Basis(double x, double y) => [1, x, y, x * x, x * y, y * y];
        float[] Process(float[] ch)
        {
            var pts = new List<(double X, double Y, double V)>();
            for (var cy = 0; cy < gy; cy++)
            for (var cx = 0; cx < gx; cx++)
            {
                int x0 = cx * w / gx, x1 = (cx + 1) * w / gx, y0 = cy * h / gy, y1 = (cy + 1) * h / gy;
                var s = new List<float>();
                for (var y = y0; y < y1; y += 3) for (var x = x0; x < x1; x += 3) s.Add(ch[y * w + x]);
                if (s.Count <= 8) continue;
                s.Sort();
                pts.Add(((double)(x0 + x1) / w - 1, (double)(y0 + y1) / h - 1, s[s.Count * 3 / 10]));
            }
            if (pts.Count < 12) return ch;
            var active = Enumerable.Repeat(true, pts.Count).ToArray();
            var coef = new double[6];
            for (var it = 0; it < 4; it++)
            {
                var ata = new double[6, 6]; var atb = new double[6];
                for (var i = 0; i < pts.Count; i++)
                {
                    if (!active[i]) continue;
                    var b = Basis(pts[i].X, pts[i].Y);
                    for (var r = 0; r < 6; r++) { atb[r] += b[r] * pts[i].V; for (var c = 0; c < 6; c++) ata[r, c] += b[r] * b[c]; }
                }
                var sol = Solve(ata, atb);
                if (sol is null) return ch;
                coef = sol;
                var res = pts.Select(p => p.V - Basis(p.X, p.Y).Zip(coef, (a, b) => a * b).Sum()).ToArray();
                var act = res.Where((_, i) => active[i]).Select(Math.Abs).OrderBy(x => x).ToArray();
                var mad = Math.Max(1, act[act.Length / 2] * 1.4826);
                for (var i = 0; i < pts.Count; i++) active[i] = res[i] < 2.5 * mad && res[i] > -4 * mad;
            }
            var o = new float[ch.Length];
            for (var y = 0; y < h; y++)
            {
                var fy = (2.0 * y + 1) / h - 1;
                double a0 = coef[0] + coef[2] * fy + coef[5] * fy * fy, a1 = coef[1] + coef[4] * fy, a2 = coef[3];
                for (var x = 0; x < w; x++)
                {
                    var fx = (2.0 * x + 1) / w - 1;
                    var i = y * w + x;
                    o[i] = Math.Max(0, ch[i] - (float)(a0 + a1 * fx + a2 * fx * fx) + Pedestal);
                }
            }
            return o;
        }
        img.R = Process(img.R); img.G = Process(img.G); img.B = Process(img.B);
    }

    private static double[]? Solve(double[,] a, double[] b)
    {
        var n = b.Length;
        var m = (double[,])a.Clone(); var v = (double[])b.Clone();
        for (var col = 0; col < n; col++)
        {
            var piv = col;
            for (var r = col + 1; r < n; r++) if (Math.Abs(m[r, col]) > Math.Abs(m[piv, col])) piv = r;
            if (Math.Abs(m[piv, col]) < 1e-12) return null;
            for (var c = 0; c < n; c++) (m[col, c], m[piv, c]) = (m[piv, c], m[col, c]);
            (v[col], v[piv]) = (v[piv], v[col]);
            for (var r = col + 1; r < n; r++)
            {
                var f = m[r, col] / m[col, col];
                for (var c = col; c < n; c++) m[r, c] -= f * m[col, c];
                v[r] -= f * v[col];
            }
        }
        var x = new double[n];
        for (var r = n - 1; r >= 0; r--)
        {
            var s = v[r];
            for (var c = r + 1; c < n; c++) s -= m[r, c] * x[c];
            x[r] = s / m[r, r];
        }
        return x;
    }

    public static void NeutralizeBackground(LinearImage img)
    {
        float mr = QuickMedian(img.R), mg = QuickMedian(img.G), mb = QuickMedian(img.B);
        var t = Math.Max(mr, Math.Max(mg, mb));
        for (var i = 0; i < img.R.Length; i++) { img.R[i] += t - mr; img.G[i] += t - mg; img.B[i] += t - mb; }
    }

    public static void CalibrateColor(LinearImage img)
    {
        float bgR = QuickMedian(img.R), bgG = QuickMedian(img.G), bgB = QuickMedian(img.B);
        var n = img.R.Length;
        var dev = new List<float>();
        for (var i = 0; i < n; i += Math.Max(1, n / 20000)) dev.Add(Math.Abs(img.G[i] - bgG));
        dev.Sort();
        var sigma = Math.Max(1, dev[dev.Count / 2] * 1.4826f);
        var rr = new List<float>(); var rb = new List<float>();
        for (var i = 0; i < n; i++)
        {
            float r = img.R[i] - bgR, g = img.G[i] - bgG, b = img.B[i] - bgB;
            if (g > 15 * sigma && g < 300 * sigma && r > 3 * sigma && b > 3 * sigma && Math.Max(img.R[i], Math.Max(img.G[i], img.B[i])) < 58000)
            { rr.Add(g / r); rb.Add(g / b); }
        }
        if (rr.Count <= 200) return;
        rr.Sort(); rb.Sort();
        var kr = (float)Math.Clamp(Math.Sqrt(rr[rr.Count / 2]), 0.7, 1.4);
        var kb = (float)Math.Clamp(Math.Sqrt(rb[rb.Count / 2]), 0.7, 1.4);
        for (var i = 0; i < n; i++)
        {
            img.R[i] = Math.Max(0, (img.R[i] - bgR) * kr + bgR);
            img.B[i] = Math.Max(0, (img.B[i] - bgB) * kb + bgB);
        }
    }

    private static float[] BoxBlur(float[] c, int w, int h, int r)
    {
        var a = (float[])c.Clone(); var b = new float[c.Length];
        var norm = 1f / (2 * r + 1);
        for (var pass = 0; pass < 2; pass++)
        {
            for (var y = 0; y < h; y++)
            {
                var row = y * w; float acc = 0;
                for (var k = -r; k <= r; k++) acc += a[row + Math.Clamp(k, 0, w - 1)];
                for (var x = 0; x < w; x++)
                {
                    b[row + x] = acc * norm;
                    acc += a[row + Math.Min(w - 1, x + r + 1)] - a[row + Math.Max(0, x - r)];
                }
            }
            for (var x = 0; x < w; x++)
            {
                float acc = 0;
                for (var k = -r; k <= r; k++) acc += b[Math.Clamp(k, 0, h - 1) * w + x];
                for (var y = 0; y < h; y++)
                {
                    a[y * w + x] = acc * norm;
                    acc += b[Math.Min(h - 1, y + r + 1) * w + x] - b[Math.Max(0, y - r) * w + x];
                }
            }
        }
        return a;
    }

    public static void ReduceNoise(LinearImage img)
    {
        int w = img.Width, h = img.Height, n = w * h;
        if (w <= 8 || h <= 8) return;
        var l = new float[n];
        for (var i = 0; i < n; i++) l[i] = (img.R[i] + img.G[i] + img.B[i]) / 3;
        var cr = new float[n]; var cg = new float[n]; var cb = new float[n];
        for (var i = 0; i < n; i++) { cr[i] = img.R[i] - l[i]; cg[i] = img.G[i] - l[i]; cb[i] = img.B[i] - l[i]; }
        cr = BoxBlur(cr, w, h, 2); cg = BoxBlur(cg, w, h, 2); cb = BoxBlur(cb, w, h, 2);
        var ls = BoxBlur(l, w, h, 1);
        var bg = QuickMedian(l);
        var dev = new List<float>();
        for (var i = 0; i < n; i += Math.Max(1, n / 20000)) dev.Add(Math.Abs(l[i] - bg));
        dev.Sort();
        var sigma = Math.Max(1, dev[dev.Count / 2] * 1.4826f);
        for (var i = 0; i < n; i++)
        {
            var t = Math.Clamp((l[i] - bg) / (8 * sigma), 0, 1);
            var k = 0.6f * (1 - t);
            var lum = l[i] * (1 - k) + ls[i] * k;
            img.R[i] = Math.Max(0, lum + cr[i]); img.G[i] = Math.Max(0, lum + cg[i]); img.B[i] = Math.Max(0, lum + cb[i]);
        }
    }

    // ------------------------------------------------------------ Estirado

    public static RenderedImage Render(LinearImage input, ProcessingOptions o)
    {
        var img = input.Clone();
        if (o.CropEdges) img = CropStackEdges(img);
        if (o.RemoveGradient) SubtractBackgroundModel(img);
        if (o.ColorBalance) { NeutralizeBackground(img); CalibrateColor(img); NeutralizeBackground(img); }
        if (o.Denoise) ReduceNoise(img);

        var stats = new[] { MedianMad(img.R), MedianMad(img.G), MedianMad(img.B) };
        (double C0, double M) Params((float Med, float Mad) s)
        {
            double med = s.Med / 65535.0, mad = s.Mad / 65535.0;
            var c0 = Math.Max(0, med - o.ShadowsClip * mad);
            var x = (med - c0) / Math.Max(1e-6, 1 - c0);
            return (c0, Mtf(x, o.TargetBackground));
        }
        var p = stats.Select(Params).ToArray();
        if (o.Linked) { var c0 = p.Average(q => q.C0); var m = p.Average(q => q.M); p = [(c0, m), (c0, m), (c0, m)]; }
        const int lutSize = 4096;
        var luts = p.Select(q => Enumerable.Range(0, lutSize)
            .Select(i => (float)Mtf((i / (double)(lutSize - 1) - q.C0) / Math.Max(1e-6, 1 - q.C0), q.M)).ToArray()).ToArray();
        int n = img.Width * img.Height;
        var outp = new byte[n * 4];
        var sat = (float)o.Saturation;
        const float scale = (lutSize - 1) / 65535f;
        for (var i = 0; i < n; i++)
        {
            float r = luts[0][Math.Clamp((int)(img.R[i] * scale), 0, lutSize - 1)];
            float g = luts[1][Math.Clamp((int)(img.G[i] * scale), 0, lutSize - 1)];
            float b = luts[2][Math.Clamp((int)(img.B[i] * scale), 0, lutSize - 1)];
            if (sat != 1)
            {
                var l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
                var t = Math.Clamp((l - 0.12f) / 0.35f, 0, 1);
                var k = 1 + (sat - 1) * t * t * (3 - 2 * t);
                r = l + (r - l) * k; g = l + (g - l) * k; b = l + (b - l) * k;
            }
            outp[4 * i] = (byte)Math.Clamp(b * 255, 0, 255);
            outp[4 * i + 1] = (byte)Math.Clamp(g * 255, 0, 255);
            outp[4 * i + 2] = (byte)Math.Clamp(r * 255, 0, 255);
            outp[4 * i + 3] = 255;
        }
        return new RenderedImage(img.Width, img.Height, outp);
    }

    /// <summary>FITS de 16 bits con los datos lineales, para Siril o GraXpert.</summary>
    public static void SaveFits(LinearImage img, string path, string obj)
    {
        var header = new StringBuilder();
        void Card(string key, string value)
        {
            var line = key.PadRight(8) + "= " + (value.Length < 20 ? value.PadLeft(20) : value);
            header.Append(line.PadRight(80));
        }
        Card("SIMPLE", "T"); Card("BITPIX", "16"); Card("NAXIS", "3");
        Card("NAXIS1", img.Width.ToString()); Card("NAXIS2", img.Height.ToString()); Card("NAXIS3", "3");
        Card("BZERO", "32768"); Card("BSCALE", "1");
        Card("OBJECT", "'" + new string(obj.Where(c => c is >= ' ' and <= '~' and not '\'').Take(60).ToArray()) + "'");
        Card("CREATOR", "'Astrolabio'");
        Card("DATE", "'" + DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss") + "'");
        header.Append("END".PadRight(80));
        while (header.Length % 2880 != 0) header.Append(' ');
        using var fs = File.Create(path);
        fs.Write(Encoding.ASCII.GetBytes(header.ToString()));
        foreach (var plane in new[] { img.R, img.G, img.B })
        for (var y = img.Height - 1; y >= 0; y--)
        {
            var row = new byte[img.Width * 2];
            for (var x = 0; x < img.Width; x++)
            {
                var v = (int)Math.Clamp(plane[y * img.Width + x], 0, 65535) - 32768;
                var u = (ushort)(short)v;
                row[2 * x] = (byte)(u >> 8); row[2 * x + 1] = (byte)(u & 0xFF);
            }
            fs.Write(row);
        }
        var pad = (2880 - fs.Length % 2880) % 2880;
        fs.Write(new byte[pad]);
    }
}
