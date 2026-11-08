using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Imaging;

public enum CropAspect { Original, Wide, Square, Portrait, Free }

/// <summary>Ajustes del retoque (igual que PhotoEditing.swift). El original no se modifica nunca.</summary>
public sealed record PhotoEdit
{
    public bool RemoveGradient { get; init; } = true;
    public bool NeutralBackground { get; init; } = true;
    public double BlackPoint { get; init; } = 0.3;
    public double Brightness { get; init; } = 0.4;
    public double Noise { get; init; } = 0.4;
    public double ColorNoise { get; init; } = 0.5;
    public double Sharpen { get; init; } = 0.2;
    public double Saturation { get; init; } = 1.3;
    public double StarReduction { get; init; }
    public CropAspect Crop { get; init; } = CropAspect.Original;
    public (double X, double Y, double W, double H) FreeCrop { get; init; } = (0.1, 0.1, 0.8, 0.8);
}

public sealed class EditableImage(LinearImage image, bool isLinear, string name, Dictionary<string, string>? header = null)
{
    public LinearImage Image { get; set; } = image;
    public bool IsLinear { get; } = isLinear;
    public string Name { get; } = name;
    public Dictionary<string, string> Header { get; } = header ?? new();
}

public static class PhotoEditor
{
    public const long MaxPixels = 100_000_000;

    public static (LinearImage Image, Dictionary<string, string> Header)? ReadFits(byte[] data)
    {
        var header = new Dictionary<string, string>();
        var offset = 0; var ended = false;
        while (offset + 2880 <= data.Length && !ended)
        {
            for (var k = 0; k < 36; k++)
            {
                var card = Encoding.ASCII.GetString(data, offset + k * 80, 80);
                var key = card[..8].Trim();
                if (key == "END") { ended = true; break; }
                if (card.Length < 10 || card.Substring(8, 2) != "= ") continue;
                var value = card[10..];
                var t = value.Trim();
                if (!t.StartsWith('\'') && value.IndexOf(" /", StringComparison.Ordinal) is var sl and >= 0) value = value[..sl];
                header[key] = value.Trim().Trim('\'').Trim();
            }
            offset += 2880;
        }
        int I(string k) => int.TryParse(header.GetValueOrDefault(k), out var v) ? v : 0;
        double D(string k, double d) => double.TryParse(header.GetValueOrDefault(k), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : d;
        int bitpix = I("BITPIX"), naxis = I("NAXIS"), w = I("NAXIS1"), h = I("NAXIS2");
        if (!ended || naxis < 2 || w <= 0 || h <= 0 || (long)w * h > MaxPixels) return null;
        var planes = naxis >= 3 ? Math.Clamp(I("NAXIS3"), 1, 3) : 1;
        var bytes = Math.Abs(bitpix) / 8;
        if (bytes is not (1 or 2 or 4 or 8) || offset + (long)w * h * planes * bytes > data.Length) return null;
        double bzero = D("BZERO", 0), bscale = D("BSCALE", 1);
        var raw = new double[w * h * planes];
        for (var i = 0; i < raw.Length; i++)
        {
            var q = offset + i * bytes;
            double v = bitpix switch
            {
                8 => data[q],
                16 => (short)((data[q] << 8) | data[q + 1]),
                32 => System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(q)),
                -32 => System.Buffers.Binary.BinaryPrimitives.ReadSingleBigEndian(data.AsSpan(q)),
                -64 => System.Buffers.Binary.BinaryPrimitives.ReadDoubleBigEndian(data.AsSpan(q)),
                _ => 0,
            };
            raw[i] = double.IsFinite(v) ? bzero + bscale * v : 0;
        }
        var maxV = raw.Length > 0 ? raw.Max() : 1;
        var kk = bitpix < 0 && maxV <= 1.5 ? 65535.0 : bitpix == 8 ? 257.0 : maxV > 65535 ? 65535 / maxV : 1;
        float[] Plane(int p)
        {
            var o = new float[w * h];
            var pp = Math.Min(p, planes - 1);
            for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
                o[y * w + x] = (float)Math.Max(0, raw[pp * w * h + (h - 1 - y) * w + x] * kk);   // FITS: primera fila abajo
            return o;
        }
        return (new LinearImage(w, h, Plane(0), Plane(1), Plane(2)), header);
    }

    public static float[] BoxBlur(float[] c, int w, int h, int r)
    {
        if (r <= 0) return (float[])c.Clone();
        var tmp = new float[c.Length]; var o = new float[c.Length];
        for (var y = 0; y < h; y++)
        {
            float acc = 0; var row = y * w;
            for (var x = -r; x <= r; x++) acc += c[row + Math.Clamp(x, 0, w - 1)];
            for (var x = 0; x < w; x++) { tmp[row + x] = acc / (2 * r + 1); acc += c[row + Math.Min(w - 1, x + r + 1)] - c[row + Math.Max(0, x - r)]; }
        }
        for (var x = 0; x < w; x++)
        {
            float acc = 0;
            for (var y = -r; y <= r; y++) acc += tmp[Math.Clamp(y, 0, h - 1) * w + x];
            for (var y = 0; y < h; y++) { o[y * w + x] = acc / (2 * r + 1); acc += tmp[Math.Min(h - 1, y + r + 1) * w + x] - tmp[Math.Max(0, y - r) * w + x]; }
        }
        return o;
    }

    public static float[] Luminance(LinearImage i)
    {
        var l = new float[i.Width * i.Height];
        for (var k = 0; k < l.Length; k++) l[k] = 0.2126f * i.R[k] + 0.7152f * i.G[k] + 0.0722f * i.B[k];
        return l;
    }

    public static (float Bg, float Sigma) BackgroundStats(float[] l)
    {
        var step = Math.Max(1, l.Length / 20000);
        var s = new List<float>();
        for (var i = 0; i < l.Length; i += step) s.Add(l[i]);
        s.Sort();
        if (s.Count == 0) return (0, 1);
        var med = s[s.Count / 2];
        var d = s.Select(v => Math.Abs(v - med)).OrderBy(v => v).ToList();
        return (med, Math.Max(1, d[d.Count / 2] * 1.4826f));
    }

    public static LinearImage Clone(LinearImage i) => new(i.Width, i.Height, (float[])i.R.Clone(), (float[])i.G.Clone(), (float[])i.B.Clone());

    public static LinearImage Process(EditableImage input, PhotoEdit e, IEnumerable<SatelliteTrail>? trails = null)
    {
        var img = Clone(input.Image);
        if (trails is not null) SatelliteTrails.Remove(trails, img);
        if (e.RemoveGradient) ImageProcessing.SubtractBackgroundModel(img);
        if (e.NeutralBackground)
        {
            ImageProcessing.NeutralizeBackground(img);
            if (input.IsLinear) { ImageProcessing.CalibrateColor(img); ImageProcessing.NeutralizeBackground(img); }
        }
        if (e.ColorNoise > 0) ReduceColorNoise(img, (float)e.ColorNoise);
        if (e.Noise > 0) ReduceLuminanceNoise(img, (float)e.Noise);
        if (e.StarReduction > 0) ReduceStars(img, (float)e.StarReduction);
        if (e.Sharpen > 0) Sharpen(img, (float)e.Sharpen);
        return img;
    }

    public static void ReduceColorNoise(LinearImage img, float amount)
    {
        int w = img.Width, h = img.Height;
        var l = Luminance(img);
        var r = Math.Max(1, (int)Math.Round(amount * 4));
        float[] Ch(float[] c) { var o = new float[c.Length]; for (var i = 0; i < c.Length; i++) o[i] = c[i] - l[i]; return BoxBlur(o, w, h, r); }
        var cr = Ch(img.R); var cg = Ch(img.G); var cb = Ch(img.B);
        var k = Math.Min(1, amount * 1.2f);
        for (var i = 0; i < w * h; i++)
        {
            img.R[i] = Math.Max(0, img.R[i] * (1 - k) + (l[i] + cr[i]) * k);
            img.G[i] = Math.Max(0, img.G[i] * (1 - k) + (l[i] + cg[i]) * k);
            img.B[i] = Math.Max(0, img.B[i] * (1 - k) + (l[i] + cb[i]) * k);
        }
    }

    public static void ReduceLuminanceNoise(LinearImage img, float amount)
    {
        int w = img.Width, h = img.Height;
        var l = Luminance(img);
        var ls = BoxBlur(l, w, h, 1 + (int)(amount * 2));
        var (bg, sigma) = BackgroundStats(l);
        for (var i = 0; i < w * h; i++)
        {
            var t = Math.Clamp((l[i] - bg) / (6 * sigma), 0, 1);
            var k = amount * 0.8f * (1 - t);
            var f = l[i] > 1 ? (l[i] * (1 - k) + ls[i] * k) / l[i] : 1;
            img.R[i] *= f; img.G[i] *= f; img.B[i] *= f;
        }
    }

    public static void ReduceStars(LinearImage img, float amount)
    {
        int w = img.Width, h = img.Height;
        if (w <= 4 || h <= 4) return;
        var l = Luminance(img);
        var local = BoxBlur(l, w, h, 6);
        var (_, sigma) = BackgroundStats(l);
        float[] Erode(float[] c)
        {
            var o = (float[])c.Clone();
            for (var y = 1; y < h - 1; y++) for (var x = 1; x < w - 1; x++)
            {
                var m = c[y * w + x];
                for (var dy = -1; dy <= 1; dy++) for (var dx = -1; dx <= 1; dx++) m = Math.Min(m, c[(y + dy) * w + x + dx]);
                o[y * w + x] = m;
            }
            return o;
        }
        var mask = new float[w * h];
        for (var i = 0; i < mask.Length; i++) mask[i] = Math.Clamp((l[i] - local[i] - 4 * sigma) / (10 * sigma), 0, 1);
        mask = BoxBlur(mask, w, h, 1);
        var er = Erode(img.R); var eg = Erode(img.G); var eb = Erode(img.B);
        for (var i = 0; i < mask.Length; i++)
        {
            var k = Math.Min(1, mask[i] * 2) * amount;
            img.R[i] = img.R[i] * (1 - k) + er[i] * k; img.G[i] = img.G[i] * (1 - k) + eg[i] * k; img.B[i] = img.B[i] * (1 - k) + eb[i] * k;
        }
    }

    public static void Sharpen(LinearImage img, float amount)
    {
        int w = img.Width, h = img.Height;
        var l = Luminance(img);
        var bl = BoxBlur(l, w, h, 2);
        var (bg, sigma) = BackgroundStats(l);
        for (var i = 0; i < w * h; i++)
        {
            var t = Math.Clamp((l[i] - bg) / (5 * sigma), 0, 1);
            var nl = Math.Max(0, l[i] + amount * 1.5f * t * (l[i] - bl[i]));
            var f = l[i] > 1 ? nl / l[i] : 1;
            img.R[i] *= f; img.G[i] *= f; img.B[i] *= f;
        }
    }

    /// <summary>Imagen final en RGB 0–1 (estirado, saturación y recorte).</summary>
    public static (int W, int H, float[] Rgb) Stretched(LinearImage img, bool isLinear, PhotoEdit e)
    {
        var n = img.Width * img.Height;
        var o = new float[n * 3];
        var (bg, sigma) = BackgroundStats(Luminance(img));
        var target = 0.06 + e.Brightness * 0.26;
        double c0, m;
        if (isLinear)
        {
            c0 = Math.Max(0, bg - (1 + 3 * (1 - e.BlackPoint)) * sigma) / 65535;
            m = ImageProcessing.Mtf((bg / 65535.0 - c0) / Math.Max(1e-6, 1 - c0), target);
        }
        else { c0 = e.BlackPoint * 0.25; m = 0.5 - (e.Brightness - 0.4) * 0.6; }
        var sat = (float)e.Saturation;
        float S(float v) => (float)ImageProcessing.Mtf((v / 65535.0 - c0) / Math.Max(1e-6, 1 - c0), m);
        for (var i = 0; i < n; i++)
        {
            float r = S(img.R[i]), g = S(img.G[i]), b = S(img.B[i]);
            var lum = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            var k = 1 + (sat - 1) * Math.Clamp((lum - 0.1f) / 0.3f, 0, 1);
            o[3 * i] = Math.Clamp(lum + (r - lum) * k, 0, 1); o[3 * i + 1] = Math.Clamp(lum + (g - lum) * k, 0, 1); o[3 * i + 2] = Math.Clamp(lum + (b - lum) * k, 0, 1);
        }
        return Crop((img.Width, img.Height, o), e);
    }

    public static (int X, int Y, int W, int H) CropRect(int w, int h, PhotoEdit e)
    {
        switch (e.Crop)
        {
            case CropAspect.Original: return (0, 0, w, h);
            case CropAspect.Free:
                var f = e.FreeCrop;
                int x = (int)(Math.Clamp(f.X, 0, 1) * w), y = (int)(Math.Clamp(f.Y, 0, 1) * h);
                return (x, y, Math.Max(1, Math.Min(w - x, (int)(f.W * w))), Math.Max(1, Math.Min(h - y, (int)(f.H * h))));
            default:
                var ratio = e.Crop switch { CropAspect.Wide => 16.0 / 9, CropAspect.Portrait => 4.0 / 5, _ => 1 };
                double cw = w, ch = cw / ratio;
                if (ch > h) { ch = h; cw = ch * ratio; }
                return ((int)Math.Round((w - cw) / 2), (int)Math.Round((h - ch) / 2), (int)Math.Round(cw), (int)Math.Round(ch));
        }
    }

    public static (int W, int H, float[] Rgb) Crop((int W, int H, float[] Rgb) img, PhotoEdit e)
    {
        var (x0, y0, cw, ch) = CropRect(img.W, img.H, e);
        cw = Math.Min(cw, img.W - x0); ch = Math.Min(ch, img.H - y0);
        if (cw <= 0 || ch <= 0 || (cw == img.W && ch == img.H)) return img;
        var o = new float[cw * ch * 3];
        for (var y = 0; y < ch; y++) Array.Copy(img.Rgb, ((y0 + y) * img.W + x0) * 3, o, y * cw * 3, cw * 3);
        return (cw, ch, o);
    }
}

/// <summary>Traza recta de satélite o avión, en píxeles.</summary>
public sealed class SatelliteTrail
{
    public double X1 { get; set; }
    public double Y1 { get; set; }
    public double X2 { get; set; }
    public double Y2 { get; set; }
    public double HalfWidth { get; set; } = 3;
    public bool Enabled { get; set; } = true;
    public bool Manual { get; set; }
    public double Length => Math.Sqrt((X2 - X1) * (X2 - X1) + (Y2 - Y1) * (Y2 - Y1));
}

public static class SatelliteTrails
{
    public static List<SatelliteTrail> Detect(LinearImage img, int maxTrails = 6)
    {
        var scale = Math.Max(1, (int)Math.Ceiling(Math.Max(img.Width, img.Height) / 700.0));
        int w = img.Width / scale, h = img.Height / scale;
        if (w <= 32 || h <= 32) return [];
        var l = new float[w * h];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            float s = 0;
            for (var dy = 0; dy < scale; dy++) for (var dx = 0; dx < scale; dx++)
            { var i = (y * scale + dy) * img.Width + x * scale + dx; s += 0.2126f * img.R[i] + 0.7152f * img.G[i] + 0.0722f * img.B[i]; }
            l[y * w + x] = s / (scale * scale);
        }
        var bgMap = PhotoEditor.BoxBlur(l, w, h, 8);
        var resid = new float[l.Length];
        for (var i = 0; i < l.Length; i++) resid[i] = l[i] - bgMap[i];
        var (_, sigma) = PhotoEditor.BackgroundStats(resid);
        var edge = resid.Select(v => v > 2.5f * sigma).ToArray();
        const int nTheta = 180;
        var diag = (int)Math.Ceiling(Math.Sqrt(w * w + h * h));
        var nRho = 2 * diag + 1;
        var acc = new int[nTheta * nRho];
        var cosT = Enumerable.Range(0, nTheta).Select(t => Math.Cos(t * Math.PI / 180)).ToArray();
        var sinT = Enumerable.Range(0, nTheta).Select(t => Math.Sin(t * Math.PI / 180)).ToArray();
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
            if (edge[y * w + x])
                for (var t = 0; t < nTheta; t++) acc[t * nRho + (int)Math.Round(x * cosT[t] + y * sinT[t]) + diag]++;
        var minVotes = (int)(Math.Min(w, h) * 0.25);
        var found = new List<(int T, int Rho)>();
        for (var k = 0; k < maxTrails; k++)
        {
            var best = 0; var bi = -1;
            for (var i = 0; i < acc.Length; i++) if (acc[i] > best) { best = acc[i]; bi = i; }
            if (bi < 0 || best < minVotes) break;
            int t0 = bi / nRho, r0 = bi % nRho;
            found.Add((t0, r0));
            for (var dt = -8; dt <= 8; dt++) for (var dr = -12; dr <= 12; dr++)
            { int tt = (t0 + dt + nTheta) % nTheta, rr = r0 + dr; if (rr >= 0 && rr < nRho) acc[tt * nRho + rr] = 0; }
        }
        var outList = new List<SatelliteTrail>();
        foreach (var (t, rho) in found)
        {
            double c = cosT[t], s = sinT[t], r = rho - diag, x0 = c * r, y0 = s * r;
            var pts = new List<(double X, double Y)>();
            for (var k = -diag; k <= diag; k++)
            {
                double x = x0 - s * k, y = y0 + c * k;
                int xi = (int)Math.Round(x), yi = (int)Math.Round(y);
                if (xi < 0 || yi < 0 || xi >= w || yi >= h) continue;
                var hit = false;
                for (var d = -1; d <= 1; d++)
                {
                    int xx = (int)Math.Round(x + c * d), yy = (int)Math.Round(y + s * d);
                    if (xx >= 0 && yy >= 0 && xx < w && yy < h && edge[yy * w + xx]) hit = true;
                }
                if (hit) pts.Add((x, y));
            }
            if (pts.Count < minVotes / 2) continue;
            var (fx, fy) = pts[0]; var (lx, ly) = pts[^1];
            var len = Math.Sqrt((lx - fx) * (lx - fx) + (ly - fy) * (ly - fy));
            if (len < Math.Min(w, h) * 0.3 || pts.Count < len * 0.6) continue;
            var trail = new SatelliteTrail { X1 = fx * scale, Y1 = fy * scale, X2 = lx * scale, Y2 = ly * scale, HalfWidth = 2 * scale + 1 };
            if (!outList.Any(o => Distance(trail.X1, trail.Y1, o) < 4 * scale + 6 && Distance(trail.X2, trail.Y2, o) < 4 * scale + 6)) outList.Add(trail);
        }
        return outList;
    }

    public static double Distance(double px, double py, SatelliteTrail t) =>
        t.Length <= 0 ? Math.Sqrt((px - t.X1) * (px - t.X1) + (py - t.Y1) * (py - t.Y1))
            : Math.Abs((t.X2 - t.X1) * (t.Y1 - py) - (t.X1 - px) * (t.Y2 - t.Y1)) / t.Length;

    public static void Remove(IEnumerable<SatelliteTrail> trails, LinearImage img)
    {
        int w = img.Width, h = img.Height;
        foreach (var t in trails.Where(t => t.Enabled && t.Length > 1))
        {
            double dx = (t.X2 - t.X1) / t.Length, dy = (t.Y2 - t.Y1) / t.Length, nx = -dy, ny = dx, hw = t.HalfWidth;
            for (var k = 0; k <= (int)Math.Round(t.Length); k++)
            {
                double cx = t.X1 + dx * k, cy = t.Y1 + dy * k;
                var side = new List<(float R, float G, float B)>();
                foreach (var off in new[] { hw + 3, -(hw + 3), hw + 5, -(hw + 5) })
                {
                    int x = (int)Math.Round(cx + nx * off), y = (int)Math.Round(cy + ny * off);
                    if (x >= 0 && y >= 0 && x < w && y < h) side.Add((img.R[y * w + x], img.G[y * w + x], img.B[y * w + x]));
                }
                if (side.Count == 0) continue;
                float fr = side.Average(v => v.R), fg = side.Average(v => v.G), fb = side.Average(v => v.B);
                for (var o = -hw; o <= hw; o += 0.5)
                {
                    int x = (int)Math.Round(cx + nx * o), y = (int)Math.Round(cy + ny * o);
                    if (x >= 0 && y >= 0 && x < w && y < h) { img.R[y * w + x] = fr; img.G[y * w + x] = fg; img.B[y * w + x] = fb; }
                }
            }
        }
    }
}

/// <summary>Solución astrométrica TAN (igual que SkyLabels.swift).</summary>
public sealed record ImageWcs(double RaDeg, double DecDeg, double RefX, double RefY, double Cd11, double Cd12, double Cd21, double Cd22, bool Solved)
{
    public static ImageWcs? FromFits(IReadOnlyDictionary<string, string> h, int width, int height)
    {
        double? D(string k) => h.TryGetValue(k, out var s) && double.TryParse(s.Replace('D', 'E'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
        if (D("CRVAL1") is not double ra || D("CRVAL2") is not double dec || D("CRPIX1") is not double px || D("CRPIX2") is not double py) return null;
        double? c11 = D("CD1_1"), c12 = D("CD1_2"), c21 = D("CD2_1"), c22 = D("CD2_2");
        if (c11 is null && D("CDELT1") is double s1 && D("CDELT2") is double s2)
        {
            var rot = (D("CROTA2") ?? 0) * Math.PI / 180;
            c11 = s1 * Math.Cos(rot); c12 = -s2 * Math.Sin(rot); c21 = s1 * Math.Sin(rot); c22 = s2 * Math.Cos(rot);
        }
        if (c11 is not double a || c22 is not double e) return null;
        double b = c12 ?? 0, c = c21 ?? 0;
        if (a == 0 && b == 0) return null;
        return new ImageWcs(ra, dec, px - 1, height - py, a, -b, c, -e, true);
    }

    public static ImageWcs Estimate(double raHours, double decDeg, int width, int height, double fovWidthDeg)
    {
        var s = fovWidthDeg / Math.Min(width, height);
        return new ImageWcs(raHours * 15, decDeg, width / 2.0, height / 2.0, -s, 0, 0, -s, false);
    }

    public (double X, double Y)? Pixel(double raDeg, double decDeg)
    {
        const double r = Math.PI / 180;
        double a = raDeg * r, d = decDeg * r, a0 = RaDeg * r, d0 = DecDeg * r;
        var cosc = Math.Sin(d0) * Math.Sin(d) + Math.Cos(d0) * Math.Cos(d) * Math.Cos(a - a0);
        if (cosc <= 0.1) return null;
        var xi = Math.Cos(d) * Math.Sin(a - a0) / cosc / r;
        var eta = (Math.Cos(d0) * Math.Sin(d) - Math.Sin(d0) * Math.Cos(d) * Math.Cos(a - a0)) / cosc / r;
        var det = Cd11 * Cd22 - Cd12 * Cd21;
        if (det == 0) return null;
        return (RefX + (Cd22 * xi - Cd12 * eta) / det, RefY + (-Cd21 * xi + Cd11 * eta) / det);
    }

    public double ArcsecPerPixel => Math.Sqrt(Math.Abs(Cd11 * Cd22 - Cd12 * Cd21)) * 3600;
}

public sealed record SkyLabel(string Id, string Name, double X, double Y, double Radius);

public static class SkyLabels
{
    public static List<SkyLabel> Labels(ImageWcs w, int width, int height, int max = 25) =>
        Catalog.Objects.Select(o => (o, p: w.Pixel(o.RaHours * 15, o.DecDeg)))
            .Where(t => t.p is { } p && p.X >= 0 && p.Y >= 0 && p.X < width && p.Y < height)
            .OrderBy(t => t.o.Magnitude).Take(max)
            .Select(t => new SkyLabel(t.o.Id, t.o.LocalizedName, t.p!.Value.X, t.p.Value.Y, Math.Max(12, t.o.SizeArcmin * 60 / Math.Max(1e-6, w.ArcsecPerPixel) / 2))).ToList();

    public static ((double X, double Y) North, (double X, double Y) East)? Compass(ImageWcs w)
    {
        if (w.Pixel(w.RaDeg, w.DecDeg) is not { } c || w.Pixel(w.RaDeg, Math.Min(89.9, w.DecDeg + 0.1)) is not { } n
            || w.Pixel(w.RaDeg + 0.1 / Math.Max(0.05, Math.Cos(w.DecDeg * Math.PI / 180)), w.DecDeg) is not { } e) return null;
        (double, double) U((double X, double Y) p) { double dx = p.X - c.X, dy = p.Y - c.Y, l = Math.Max(1e-9, Math.Sqrt(dx * dx + dy * dy)); return (dx / l, dy / l); }
        return (U(n), U(e));
    }

    public static (double RaHours, double DecDeg)? ApproximateCenter(IReadOnlyDictionary<string, string> header, string name)
    {
        double? D(string k) => header.TryGetValue(k, out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
        if (D("RA") is double ra && D("DEC") is double dec) return (ra / 15, dec);
        var parts = name.Split('_');
        for (var k = parts.Length - 1; k >= 0; k--)
            for (var len = 1; len <= 2 && k + len <= parts.Length; len++)
                if (Catalog.Find(string.Join(" ", parts[k..(k + len)])) is { } o) return (o.RaHours, o.DecDeg);
        return header.TryGetValue("OBJECT", out var obj) && Catalog.Find(obj) is { } oo ? (oo.RaHours, oo.DecDeg) : null;
    }
}

/// <summary>GraXpert por línea de órdenes: sin shell, lista de argumentos y carpeta temporal propia.</summary>
public static class GraXpert
{
    public enum Tool { Background, Denoise }

    public static IEnumerable<string> Candidates()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        yield return Path.Combine(local, "Programs", "GraXpert", "GraXpert.exe");
        yield return Path.Combine(pf, "GraXpert", "GraXpert.exe");
        yield return Path.Combine(local, "GraXpert", "GraXpert.exe");
    }

    public static string? Find(IEnumerable<string>? list = null) => (list ?? Candidates()).FirstOrDefault(File.Exists);

    public static List<string> Arguments(Tool tool, string input, string outputBase, double strength)
    {
        var s = Math.Clamp(strength, 0, 1).ToString("F2", CultureInfo.InvariantCulture);
        var a = new List<string> { input, "-cli", "-cmd", tool == Tool.Background ? "background-extraction" : "denoising", "-output", outputBase };
        if (tool == Tool.Background) a.AddRange(["-correction", "Subtraction", "-smoothing", s]); else a.AddRange(["-strength", s]);
        return a;
    }

    public static async Task<LinearImage> Run(Tool tool, LinearImage image, double strength, string? executable = null, double timeoutSeconds = 900, CancellationToken ct = default)
    {
        var exe = executable ?? Find() ?? throw new InvalidOperationException(Strings.T("GraXpert no está instalado."));
        var dir = Path.Combine(Path.GetTempPath(), "Astrolabio-GraXpert-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var input = Path.Combine(dir, "entrada.fits"); var outBase = Path.Combine(dir, "salida");
            ImageProcessing.SaveFits(image, input, "Astrolabio");
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = dir, RedirectStandardError = true, RedirectStandardOutput = true };
            foreach (var a in Arguments(tool, input, outBase, strength)) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("GraXpert");
            var errTask = p.StandardError.ReadToEndAsync(ct);
            _ = p.StandardOutput.ReadToEndAsync(ct);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            try { await p.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { try { p.Kill(true); } catch { } throw new TimeoutException(Strings.T("GraXpert tardó demasiado y se ha detenido.")); }
            if (p.ExitCode != 0)
            {
                var err = await errTask;
                throw new InvalidOperationException(Strings.T("GraXpert terminó con un error: %@", err.Length > 300 ? err[..300] : err));
            }
            foreach (var ext in new[] { ".fits", ".fit" })
                if (File.Exists(outBase + ext) && PhotoEditor.ReadFits(File.ReadAllBytes(outBase + ext)) is { } r) return r.Image;
            throw new InvalidOperationException(Strings.T("GraXpert no devolvió ninguna imagen."));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}

/// <summary>Copia del álbum por carpetas con reanudación y SHA-256. Nunca borra nada del telescopio.</summary>
public static partial class AlbumCopy
{
    public const long MaxFileBytes = 2_000_000_000;
    public const string ManifestName = ".astrolabio-copia.json";
    public sealed record Entry(string Name, long Size, string Sha256);
    public enum Outcome { Copied, AlreadyThere, Missing, Failed }

    [GeneratedRegex("href\\s*=\\s*\"([^\"]+)\"", RegexOptions.IgnoreCase)]
    private static partial Regex Href();

    public static List<string> ParseIndex(string html)
    {
        var allowed = new HashSet<string> { ".jpg", ".jpeg", ".png", ".fit", ".fits", ".tif", ".tiff", ".mp4", ".avi" };
        var o = new List<string>();
        foreach (Match m in Href().Matches(html))
        {
            var name = Uri.UnescapeDataString(m.Groups[1].Value);
            if (name.Contains('/') || name.Contains('\\') || name.Contains("..") || name.Contains(':') || name.StartsWith('.')) continue;
            if (!allowed.Contains(Path.GetExtension(name).ToLowerInvariant()) || o.Contains(name)) continue;
            o.Add(name);
        }
        return o;
    }

    public static async Task<List<Uri>> ListFolder(HttpClient http, Uri folder, Uri knownFull)
    {
        try
        {
            using var resp = await http.GetAsync(folder);
            if (resp.IsSuccessStatusCode && (resp.Content.Headers.ContentType?.MediaType ?? "").Contains("html") && resp.Content.Headers.ContentLength is null or < 5_000_000)
            {
                var names = ParseIndex(await resp.Content.ReadAsStringAsync());
                if (names.Count > 0) return names.Select(n => new Uri(folder, Uri.EscapeDataString(n))).ToList();
            }
        }
        catch { }
        var full = knownFull.ToString();
        return [knownFull, new Uri(full[..full.LastIndexOf('.')] + ".fit")];
    }

    public static string Sha256(string path)
    {
        using var f = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(f)).ToLowerInvariant();
    }

    public static Dictionary<string, Entry> LoadManifest(string folder)
    {
        try { return JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(Path.Combine(folder, ManifestName)))?.ToDictionary(e => e.Name) ?? new(); }
        catch { return new(); }
    }

    public static void SaveManifest(Dictionary<string, Entry> m, string folder)
    {
        try { File.WriteAllText(Path.Combine(folder, ManifestName), JsonSerializer.Serialize(m.Values.OrderBy(e => e.Name).ToList())); } catch { }
    }

    public static async Task<(Outcome Result, string? Error)> Copy(HttpClient http, Uri url, string folder, Dictionary<string, Entry> manifest)
    {
        var name = Model.SafeName.FileComponent(Uri.UnescapeDataString(url.Segments[^1]), "archivo");
        var dest = Path.Combine(folder, name);
        if (!Model.SafeName.IsInside(dest, folder)) return (Outcome.Failed, "ruta");
        if (manifest.TryGetValue(name, out var e) && File.Exists(dest) && new FileInfo(dest).Length == e.Size && Sha256(dest) == e.Sha256)
            return (Outcome.AlreadyThere, null);
        try
        {
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            if (resp.StatusCode == System.Net.HttpStatusCode.NotFound) return (Outcome.Missing, null);
            if (!resp.IsSuccessStatusCode) return (Outcome.Failed, $"HTTP {(int)resp.StatusCode}");
            var expected = resp.Content.Headers.ContentLength;
            if (expected > MaxFileBytes) return (Outcome.Failed, "tamaño");
            var tmp = dest + ".parcial";
            await using (var fs = File.Create(tmp)) await resp.Content.CopyToAsync(fs);
            var size = new FileInfo(tmp).Length;
            if (expected is long x && x != size) { File.Delete(tmp); return (Outcome.Failed, Strings.T("tamaño distinto del anunciado")); }
            File.Move(tmp, dest, true);
            manifest[name] = new Entry(name, size, Sha256(dest));
            return (Outcome.Copied, null);
        }
        catch (Exception ex) { return (Outcome.Failed, ex.Message); }
    }
}
