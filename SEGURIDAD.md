# Análisis de seguridad de Astrolabio

**Versión analizada:** 1.3.0 (más las correcciones de este análisis, que se publican en la 1.4.0)
**Fecha:** 8 de noviembre de 2026
**Alcance:**
- la app de macOS (Swift);
- la app de Windows (C# / Avalonia);
- la web de descarga (`docs/`);
- la compilación automática en GitHub Actions.

## Resumen

Astrolabio no tiene servidor propio, cuentas de usuario ni base de datos en internet. Todo se ejecuta en el ordenador del usuario y habla con cuatro tipos de destino:

1. **El Seestar en la red local**, con el protocolo del fabricante (TCP 4700 y 4800 sin cifrar, HTTP para el álbum). Ese protocolo no admite TLS, así que la red local se considera de confianza limitada.
2. **Servicios públicos de datos, todos por HTTPS:** Open-Meteo, NASA SkyView, Wikipedia, CDS Sesame, MeteoAlarm, RainViewer y las teselas del mapa de CARTO.
3. **ntfy**, solo si el usuario activa los avisos al móvil.
4. **La API pública de GitHub**, desde la web, para enlazar la última versión.

Se revisaron estas áreas:
- la clave PEM;
- todo lo que llega del telescopio y de internet (JSON, cabeceras binarias, ZIP);
- las escrituras de archivos;
- los procesos externos;
- la configuración de red (ATS);
- los avisos al móvil;
- las dependencias y sus licencias;
- la cadena de compilación;
- la web.

**Se encontraron y corrigieron:**
- 2 problemas de severidad **alta**;
- 4 de severidad **media**;
- 6 de severidad **baja**.

No se encontró ningún problema que permita a alguien de fuera de la red local atacar el ordenador. Los dos casos de severidad alta exigen un dispositivo malicioso en la misma wifi que se haga pasar por el Seestar.

## Hallazgos y correcciones

| # | Severidad | Área | Problema | Corrección |
|---|---|---|---|---|
| 1 | Alta | Álbum (Mac) | **Escritura fuera de la carpeta de descargas.** El nombre de la carpeta del álbum viene del telescopio y se usaba tal cual en la ruta. Un falso Seestar podía enviar `../../Library/LaunchAgents` y escribir archivos en cualquier carpeta del usuario, incluso para ejecutarse al iniciar sesión. | Los nombres se limpian (sin `/`, `\`, `..`, caracteres de control ni nombres reservados) y antes de escribir se comprueba que la ruta final queda dentro de la carpeta de descargas. |
| 2 | Alta | Imagen apilada (Mac y Windows) | **Bomba de descompresión.** La imagen llega en un ZIP cuyo tamaño descomprimido declara el propio telescopio. Un ZIP manipulado podía pedir 4 GB (Mac) o descomprimirse sin límite (Windows) y tumbar la app. | Límite de 128 MB descomprimidos (una imagen 4K de 16 bits ocupa unos 50 MB). En Windows se descomprime por bloques y se corta al pasar el límite. |
| 3 | Media | Vista en directo (Mac y Windows) | **Nombre de archivo con el nombre del objeto.** Solo se quitaba `/`. En Windows, un nombre con `..\` o `:` podía escribir fuera de la carpeta o fallar. | Mismo limpiador que en el punto 1, en las dos plataformas. |
| 4 | Media | Canal de imagen (Windows) | **Desbordamiento de enteros.** Ancho × alto × 6 se calculaba en 32 bits; con una cabecera manipulada (65535 × 65535) desbordaba y podía aceptar una imagen con dimensiones falsas. | Cálculo en 64 bits. En el Mac ya era de 64 bits. |
| 5 | Media | Red (Mac) | **ATS desactivado para todo internet** (`NSAllowsArbitraryLoads`): la app habría aceptado conexiones HTTP sin cifrar a cualquier servidor. | Solo se permite HTTP en la red local (`NSAllowsLocalNetworking`). Se comprobó con una app de prueba: la IP del Seestar responde y el HTTP público queda bloqueado. |
| 6 | Media | Compilación (GitHub Actions) | **Token con permiso de escritura en todos los trabajos y acciones fijadas por etiqueta.** Una acción comprometida podía modificar el repositorio o las versiones publicadas. | Las acciones van fijadas por SHA. Los trabajos de compilación solo pueden leer. Solo el trabajo final de publicación (y solo con etiquetas) puede escribir, y sube los archivos con `gh`, sin acciones de terceros. Se publican sumas SHA-256 de cada descarga. |
| 7 | Baja | Exportación CSV (Mac y Windows) | **Inyección de fórmulas.** Un nombre de objeto como `=HYPERLINK(...)` se habría ejecutado al abrir el CSV en Excel o Numbers. Las comillas tampoco se escapaban. | Comillas dobladas y apóstrofo delante de `= + - @`. |
| 8 | Baja | Avisos al móvil (Mac y Windows) | Se aceptaba un servidor ntfy por HTTP sin cifrar y cualquier texto como tema; el título podía llevar saltos de línea (inyección de cabeceras). | Solo HTTPS, o HTTP dentro de la red local para un servidor propio. Tema con los caracteres válidos de ntfy. Título sin saltos de línea y con longitud limitada. |
| 9 | Baja | Clave PEM (Mac y Windows) | Se leía un archivo de cualquier tamaño y no se avisaba si otros usuarios podían leerlo. | Límite de 64 KB. En el Mac, aviso en Ajustes y en el diagnóstico si el archivo no tiene permisos `600`. La clave del autor ya los tenía. |
| 10 | Baja | Informes | La miniatura del álbum guardada en el historial podía apuntar a cualquier URL. | Solo se descarga si es HTTP a una dirección de la red local. |
| 11 | Baja | Qué mirar (Mac) | El enlace «Leer en Wikipedia» venía de la respuesta de la API sin comprobar. | Solo se muestra si es HTTPS a `*.wikipedia.org`. |
| 12 | Baja | Web | Sin política de seguridad de contenido; script en línea; el enlace de donación no se validaba. | CSP estricta (`default-src 'none'`, scripts solo propios, conexión solo a `api.github.com`), script en un archivo aparte, enlaces de descarga limitados a este repositorio y donación solo por HTTPS. |

Además se corrigió un fallo de robustez: la cabecera FITS se corrompía si el nombre del objeto tenía acentos o caracteres chinos, porque FITS solo admite ASCII en tarjetas de 80 bytes.

Todas las correcciones tienen pruebas automáticas:
- **Mac:** `Tests/AstrolabioTests/SecurityTests.swift`;
- **Windows:** `SecurityTests` en `windows/Astrolabio.Tests/CoreTests.cs`.

## Lo que ya estaba bien

- **Clave PEM:**
  - nunca se escribe en el registro, en los informes, en el historial ni en las copias de los datos;
  - solo se guarda la ruta al archivo;
  - la clave se carga en memoria al firmar el reto, y el reto firmado no sirve para otra conexión;
  - el repositorio no incluye ninguna clave.
- **Mensajes del telescopio:**
  - cada línea JSON tiene un límite de 4 MB;
  - cada mensaje de imagen, de 200 MB;
  - las imágenes solo se aceptan si el tamaño coincide con las dimensiones declaradas;
  - el JSON se interpreta con los analizadores del sistema, sin `eval` ni código dinámico.
- **Procesos externos:**
  - no se ejecuta ningún comando con texto que venga de fuera;
  - en el Mac solo se lanza `osascript` (avisos cuando la app se ejecuta sin empaquetar), con el texto escapado;
  - en Windows solo se abren rutas de archivos propios o URLs construidas por la app.
- **GraXpert (desde la versión 1.7):** es el único programa externo que lanza Astrolabio, y solo si el usuario lo pide. Se ejecuta directamente, sin shell, con una lista fija de argumentos; trabaja sobre copias en una carpeta temporal propia que se borra al terminar, tiene un tiempo máximo y el original nunca se toca.
- **Copia del álbum (desde la versión 1.7):** de la lista del telescopio solo se aceptan nombres de imagen o vídeo de esa carpeta (sin rutas, sin «..» y sin enlaces a otros servidores). Cada archivo se comprueba por tamaño y SHA-256, y Astrolabio no borra nada del telescopio: no hay orden documentada para hacerlo.
- **Datos de internet:**
  - todas las fuentes van por HTTPS;
  - RainViewer y MeteoAlarm se validan (solo hosts HTTPS, rutas sin `..`, tamaño máximo del feed).
- **Privacidad:**
  - no hay analítica, cookies ni identificadores;
  - a los servicios de datos solo se envían las coordenadas del lugar (redondeadas a 4 decimales) o el nombre del objeto buscado;
  - la web no usa servicios de terceros salvo la API pública de GitHub.
- **Dependencias:**
  - la app de Mac no usa ninguna librería externa;
  - la de Windows usa Avalonia 11.3.22 (MIT), QuestPDF 2025.12.4 (licencia Community, gratuita para proyectos de código abierto) y, solo para las pruebas, xUnit (Apache 2.0);
  - las versiones ahora van fijadas, sin comodines.

## Riesgos que quedan (y por qué)

1. **El protocolo del Seestar no está cifrado ni autenticado en sentido servidor → cliente.**
   - Un equipo malicioso en la misma wifi podría hacerse pasar por el telescopio o leer el tráfico.
   - Es una limitación del fabricante.
   - Astrolabio lo mitiga validando todo lo que recibe (puntos 1–4).
   - Recomendación: usar el Seestar en la wifi de casa y no en redes públicas o de eventos.
2. **Las apps no están firmadas por Apple ni por Microsoft.**
   - Usan firma local (Mac) y ninguna firma (Windows), por eso aparecen los avisos de Gatekeeper y SmartScreen.
   - Para comprobar que una descarga no se ha manipulado, la versión publica sus sumas SHA-256.
   - Firmar y notarizar requiere las cuentas de desarrollador (99 $/año en Apple; un certificado de firma en Windows).
3. **El tema de ntfy funciona como una contraseña.**
   - Quien lo conozca puede leer los avisos: nombres de objetos, estado del plan y batería.
   - No contienen la ubicación ni datos personales.
   - El generador de Ajustes crea temas aleatorios difíciles de adivinar.
4. **Inno Setup se instala en la compilación con `choco` sin versión fija.** Solo afecta al empaquetado del instalador, no al código de la app.
5. **La app de Mac no usa el sandbox de macOS.** Necesita acceso libre a la carpeta de imágenes que elija el usuario y a la red local; se puede revisar en una versión futura.

## Cómo informar de un problema de seguridad

Escribe a **vecasas@gmail.com** con el asunto «Seguridad Astrolabio», sin publicarlo antes en GitHub. Contestaré en cuanto pueda y publicaré la corrección en una nueva versión.
