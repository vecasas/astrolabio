using System.Security.Cryptography;
using System.Text;

namespace Astrolabio.Core.Protocol;

/// <summary>
/// Autenticación que exige el firmware moderno del Seestar (7.18 en adelante): el telescopio
/// envía un texto de reto (get_verify_str) y el cliente responde con su firma SHA1withRSA en
/// base64 (verify_client). La clave privada la aporta el usuario como archivo PEM.
/// </summary>
public sealed class SeestarSigner : IDisposable
{
    private readonly RSA _rsa;

    public SeestarSigner(string pemText)
    {
        _rsa = RSA.Create();
        try { _rsa.ImportFromPem(pemText); }                    // admite PKCS#1 y PKCS#8
        catch (Exception e) { _rsa.Dispose(); throw new InvalidDataException(Strings.T("El archivo PEM no es válido."), e); }
    }

    /// <summary>Una clave RSA en PEM ocupa unos pocos KB; algo mayor no es una clave.</summary>
    public const int MaxPemBytes = 64 * 1024;

    public static SeestarSigner FromFile(string path)
    {
        var len = new FileInfo(path).Length;
        if (len == 0 || len > MaxPemBytes) throw new InvalidDataException("PEM");
        return new(File.ReadAllText(path));
    }

    public string Sign(string challenge) =>
        Convert.ToBase64String(_rsa.SignData(Encoding.UTF8.GetBytes(challenge), HashAlgorithmName.SHA1, RSASignaturePadding.Pkcs1));

    public void Dispose() => _rsa.Dispose();
}
