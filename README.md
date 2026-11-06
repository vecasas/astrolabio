# Astrolabio

**Versión 1.1.0** · creada el 5 de noviembre de 2026 por Víctor Casas · contacto: vecasas@gmail.com

App nativa para macOS (SwiftUI) que controla un telescopio inteligente Seestar S50 desde el Mac por la red local.

## Qué hace

Tema oscuro en azules pensado para la noche y **modo nocturno** (⌃⌘N o el botón del ojo de la barra superior): toda la interfaz pasa a rojo tenue para no perder la adaptación a la oscuridad; puede activarse solo al anochecer y regularse el brillo en Ajustes. Arriba, siempre a la vista: la hora, la temperatura exterior (Open-Meteo) y la del Seestar, las nubes, la Luna, la fase de la noche y el estado de la conexión.

**Esta noche**
- **Qué mirar**: nota de calidad de la noche, horario de oscuridad, Luna y nubes, planetas visibles y los mejores objetos en tarjetas con su curva de altura. Filtros por tipo y botones «Ir y apilar» y «Al plan».
- **Elige por mí**: te propone un objeto concreto (lo mejor ahora, fácil y brillante, un reto o sorpréndeme) explicando por qué, con duración, exposición y filtro sugeridos y un botón para apuntar y apilar. También prepara un plan para el resto de la noche y lo manda a la sesión automática.
- **Carta estelar**: el cielo visible desde tu lugar, con unas 2 850 estrellas, las constelaciones, el catálogo de cielo profundo, la Luna, los planetas y la posición y el campo del telescopio. Zoom, arrastre y una barra para verlo a otra hora. Al hacer clic en algo se ven sus datos y se puede apuntar a él.

**Observar**
- **Telescopio**: busca el Seestar en la wifi, se conecta, se autentica y muestra batería, temperatura, firmware, espacio libre y la posición. Lee del propio telescopio la exposición, la ganancia, el dithering y el objeto en curso. Desde aquí: GoTo por nombre (catálogo o SIMBAD) o por coordenadas, sincronizar, apilar (con dithering y enfoque previo), mover, enfocar, abrir el brazo, aparcar, calentador, oscuros, alineación polar y apagado.
- **Vista en directo**: imagen apilada que se actualiza sola (o vista previa fotograma a fotograma), con estirado, saturación, quitar gradiente y reducir ruido. Guarda PNG y FITS lineal. El canal de imagen se reconecta solo.
- **Fiesta de estrellas**: ventana a pantalla completa (⌃⌘F).

**Sistema solar**
- **Luna**: imagen realista con la fase del momento (mapa real de la superficie iluminado desde la dirección del Sol), iluminación, distancia, salida, culminación y puesta, próximas fases, curva de altura, calendario de 30 días y botones del modo Luna.
- **Planetas**: altura, magnitud, tamaño aparente, distancia, separación del Sol y horarios de cada planeta, gráfica de la noche, GoTo y modo planeta.
- **Apilador planetario**: abre un vídeo MP4/MOV o un SER, ordena los fotogramas por nitidez, se queda con el porcentaje que elijas, los alinea (con ajuste fino subpíxel), los promedia y realza el detalle. Guarda PNG o TIFF de 16 bits.

**Planificar**
- **Planificar la noche**: unos 170 objetos ordenados por tiempo útil, Luna, nubes y encuadre, con gráfica de altura.
- **Sesión automática**: espera a la noche, apunta, enfoca, apila y pasa al siguiente; se pausa con nubes, para al amanecer, aparca y avisa en el Mac y en el móvil (ntfy).
- **Mosaicos**: hasta 3×3 paneles con vista previa.

**Archivo**
- **Álbum**: las fotos del Seestar (portada y número de archivos de cada sesión) con visor a tamaño completo y descarga, y las imágenes guardadas en el Mac.
- **Estadísticas**: horas de integración, noches, sesiones, objetos, gráficas por noche y por tipo y tabla por objeto. Astrolabio anota cada sesión mientras apila; también puede importar las sesiones antiguas del álbum del Seestar. Exporta a CSV.
- **Informes** (nuevo en 1.1): lista de noches de observación e informe completo de cada una (lugar, tiempo, Luna, ajustes y fotogramas de cada objeto, imagen apilada, batería, firmware y eventos), descargable en PDF A4 en el idioma elegido.

**Sistema**: previsión del tiempo de 48 horas y registro con diagnóstico.

## Idiomas

La interfaz está en español, inglés, francés, alemán, chino (simplificado) y ruso. El idioma se cambia en Ajustes › Idioma o en el menú «Idioma», y se aplica al momento. Los nombres de las constelaciones y de los objetos del catálogo también se traducen, y las descripciones se toman de la Wikipedia del idioma elegido. Los menús propios de macOS siguen el idioma del sistema.

Las traducciones están en `scripts/i18n/*.tsv` (una línea por texto: español, inglés, francés, alemán, chino, ruso). Tras editarlas:

```bash
python3 scripts/i18n_build.py   # valida (huecos %@, %.1f…) y regenera Translations.swift
```

## Requisitos

- macOS 14 Sonoma o posterior, con Xcode 15 o posterior.
- El Seestar en **modo estación**, unido a la misma wifi que el Mac. Se activa una vez desde la app oficial.
- **Clave PEM**: el firmware reciente (7.18 o posterior) solo obedece a clientes que firman un reto con una clave privada. Es la misma clave que usa seestar_alp en su opción `interop_pem`. Indícala en Ajustes (⌘,). Sin ella la app se conecta y ve los eventos, pero el telescopio ignorará las órdenes.

## Instalar

Descarga `Astrolabio-1.1.0.dmg` de la página de versiones (Releases) de GitHub, ábrelo y arrastra Astrolabio a Aplicaciones. La primera vez, haz clic derecho sobre la app y elige «Abrir»: está firmada localmente, no con un certificado de desarrollador de Apple, y macOS pide confirmarlo una vez.

Para crear el instalador desde el código: `./scripts/make_dmg.sh` (deja `dist/Astrolabio-<versión>.dmg`).

## Compilar y abrir

Con Xcode:

1. Abre `Package.swift` con Xcode (doble clic o `xed .`).
2. Elige el esquema **Astrolabio** y el destino **My Mac**.
3. Pulsa ▶︎ (⌘R).

Desde el Terminal:

```bash
swift run -c release          # compila y abre la app
./scripts/test.sh             # pruebas (equivale a `swift test`; funciona también solo con Command Line Tools)
./scripts/make_app.sh         # crea dist/Astrolabio.app (universal: Apple Silicon e Intel)
```

La primera vez, macOS puede pedir permiso para acceder a la **red local**. Hay que aceptarlo para que encuentre el telescopio.

Si Xcode está instalado pero `xcode-select -p` apunta a las Command Line Tools, los scripts usan Xcode automáticamente. Para que `swift build` y `swift test` a secas también lo usen, selecciona Xcode una vez:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Dentro de Astrolabio.app los avisos usan el centro de notificaciones de macOS (la primera vez pide permiso); con `swift run` se muestran mediante osascript.

## Cómo funciona por dentro

| Puerto | Uso |
|---|---|
| UDP 4720 | Descubrimiento (`scan_iscope`) |
| TCP 4700 | Órdenes y eventos JSON, un mensaje por línea (`\r\n`) |
| TCP 4800 | Imágenes: cabecera binaria de 80 bytes y datos. El id 21 es la vista previa Bayer y el 23 el apilado en ZIP |

Los nombres de los métodos del protocolo vienen de lo que ha documentado la comunidad en [seestar_alp](https://github.com/smart-underworld/seestar_alp) y [seestar-proxy](https://github.com/astrophotograph/seestar-proxy). Este proyecto no copia su código.

## Datos de terceros

- Estrellas, líneas y nombres de constelaciones: [d3-celestial](https://github.com/ofrohn/d3-celestial) de Olaf Frohn (licencia BSD de 3 cláusulas), derivados del catálogo HYG. Están incluidos en `Sources/Astrolabio/Astronomy/StarData.swift`.
- Descripciones de los objetos: resúmenes de la [Wikipedia en español](https://es.wikipedia.org) (CC BY-SA), con enlace al artículo.
- Mapa de la Luna: mosaico en color de la cámara LROC (NASA/GSFC/Arizona State University, [CGI Moon Kit](https://svs.gsfc.nasa.gov/4720)), de dominio público; incluido en `MoonTexture.swift`.
- Fotos de los objetos: cartografiado DSS2 a través de [SkyView](https://skyview.gsfc.nasa.gov) (NASA/GSFC); necesitan internet.
- Previsión del tiempo: [Open-Meteo](https://open-meteo.com). Búsqueda de objetos: Sesame/SIMBAD (CDS, Estrasburgo).

## Limitaciones conocidas

- La vista previa en vídeo del firmware actual va por RTSP (puerto 4554) y no está integrada. La vista en directo muestra la imagen apilada, que es lo útil en cielo profundo.
- Las posiciones de planetas y Luna son de baja precisión (minutos de arco). Basta porque el Seestar centra con resolución de placa.
- El telescopio solo informa de la portada y del número de archivos de cada carpeta del álbum, así que el álbum muestra una foto por sesión.
- El apilador planetario alinea el disco completo (sin puntos de alineación múltiples), suficiente para los vídeos cortos del Seestar.
- Astrolabio es independiente y no está afiliado a ZWO.

## English

Astrolabio is a native macOS app (SwiftUI, macOS 14+, no external dependencies) to control a ZWO Seestar S50 smart telescope over the local network: discovery, authentication (PEM key required by recent firmware), GoTo, stacking with live view and on-the-fly processing, a night planner with "what to see" and "pick for me", an interactive star chart, Moon and planets, an automatic session runner, mosaics, a planetary video stacker, the telescope album, observing statistics and per-night session reports exportable to PDF. The interface is available in Spanish, English, French, German, Chinese and Russian, with a red night mode.

Install from the `.dmg` in Releases (right-click → Open the first time), or build with `swift build` / `./scripts/make_app.sh` / `./scripts/make_dmg.sh`. Tests: `./scripts/test.sh`.

Author: Víctor Casas (vecasas@gmail.com). Astrolabio is independent and not affiliated with ZWO. The private key is never included in this repository.
