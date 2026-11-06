# Astrolabio para Windows 11

Versión de Astrolabio para Windows 10/11 (x64), escrita en C# con [Avalonia](https://avaloniaui.net) (.NET 10). Comparte con la versión de macOS el catálogo, las estrellas, la Luna y las traducciones (se generan con `scripts/windows_data.py`).

## Instalar

Descarga `Astrolabio-<versión>-Windows-Setup.exe` (instalador) o el ZIP portable de la página de versiones de GitHub. Como no está firmado con un certificado de Microsoft, la primera vez Windows SmartScreen puede avisar: «Más información» › «Ejecutar de todas formas».

## Compilar

```bash
python3 scripts/windows_data.py                     # regenera los datos compartidos
dotnet test windows/Astrolabio.Tests                # pruebas
dotnet run --project windows/Astrolabio.App         # abrir (también funciona en macOS/Linux)
dotnet publish windows/Astrolabio.App -c Release -r win-x64 --self-contained -o windows/publish/win-x64
```

El instalador se genera con Inno Setup (`windows/installer/Astrolabio.iss`); GitHub Actions lo hace automáticamente en Windows (`.github/workflows/windows.yml`).

## Diferencias con la versión de macOS

- El apilador planetario lee vídeos SER; los MP4/MOV todavía no (en macOS se leen con AVFoundation).
- Los avisos al móvil (ntfy) funcionan igual; no hay notificaciones del sistema de Windows.
- Interfaz más sencilla en algunos apartados (gráficas de tiempo y estadísticas como listas).
