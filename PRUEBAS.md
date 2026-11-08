# Pruebas automáticas de Astrolabio

**Versión:** 1.8.0 · **Mac:** 105 pruebas en 22 grupos (+1 opcional con GraXpert real) · **Windows:** 60 pruebas · todas se ejecutan en cada cambio (GitHub Actions)

Cómo ejecutarlas:
- Mac: `./scripts/test.sh` (o `swift test`)
- Windows: `dotnet test windows/Astrolabio.Tests`

## El Seestar simulado

La mayor parte del protocolo se prueba contra un **Seestar simulado**:
- `Tests/AstrolabioTests/FakeSeestar.swift` en el Mac y `windows/Astrolabio.Tests/FakeSeestar.cs` en Windows;
- es un servidor TCP en `127.0.0.1` que habla el mismo protocolo JSON que el telescopio;
- comprueba la firma RSA de la clave;
- emite los eventos `AutoGoto`, `Stack`, `AutoFocus` y `DarkLibrary`;
- puede simular errores, silencios y reinicios;
- tiene un canal de imagen que envía apilados en ZIP con la misma cabecera de 80 bytes.

Las pruebas usan ajustes, plan e historial temporales: **nunca tocan los datos reales** del usuario ni muestran notificaciones.

## Qué cubre cada función

| Función | Qué se comprueba | Mac | Windows |
|---|---|:-:|:-:|
| Conexión y autenticación | Conecta, firma el reto con una clave RSA generada al momento, rechaza una clave incorrecta, lee batería, firmware, enfoque y memoria | ✅ | ✅ |
| Órdenes y errores | Errores del telescopio, tiempos de espera, la conexión sigue viva después | ✅ | ✅ |
| Reinicio del telescopio | Las órdenes pendientes fallan al momento y la app se reconecta sola | ✅ | ✅ |
| Marcador «verify» del firmware | Reglas por versión de firmware | — | ✅ |
| Seguridad del GoTo | Bloquea el Sol y los objetos bajos **sin enviar** la orden; el límite solar no se puede quitar | ✅ | ✅ |
| Recentrado tras el GoTo | Desvío de 3′ → vuelve a apuntar; 0,5′ → no; lectura absurda → no insiste | ✅ | ✅ |
| Confirmación al interrumpir | Pregunta antes de cortar un apilado; la sesión automática no pregunta | ✅ | — |
| GoTo fallido | Devuelve «no llegó» sin colgarse | ✅ | — |
| Canal de imagen | Recibe un apilado (cabecera + ZIP), lo descomprime y lo convierte en imagen | ✅ | ✅ |
| Sesión automática | Plan completo contra el simulador: hora y lugar, GoTo, apilado, tiempo cumplido, aparcar, estado guardado y borrado al terminar | ✅ | — |
| Reanudar tras un reinicio | Solo apila el tiempo que faltaba; oscuros al final; «dejarlo como está» no aparca | ✅ | ✅ (lógica) |
| Batería | Consumo medio de las sesiones, aviso antes del plan, horas del plan | ✅ | ✅ |
| Avisos | Batería baja, memoria del Seestar y del ordenador, telescopio mudo, sin repetirse | ✅ | ✅ |
| Historial e informes | Sesión registrada desde eventos reales con batería, firmware, tiempo, altura y eventos; noches agrupadas; JSON antiguo compatible; PDF A4 multipágina traducido | ✅ | ✅ |
| Importar álbum | Nombres reales de archivos del Seestar, sin duplicados, a través del protocolo | ✅ | ✅ |
| Vigilancia de enfoque | HFR con estrellas sintéticas (nítidas frente a desenfocadas), aviso al empeorar, sin falsos avisos | ✅ | ✅ |
| Rocío | Niveles según temperatura y punto de rocío | ✅ | ✅ |
| Tormentas | Avisos de MeteoAlarm (formato real), lluvia, rachas y tormentas previstas; solo dentro de su horario | ✅ | ✅ |
| Radar de lluvia | Lectura de RainViewer, rutas sospechosas descartadas, teselas del mapa | ✅ | ✅ |
| Tiempo (Open-Meteo) | Las horas sin datos no cuentan como cielo despejado | ✅ | — |
| Catálogo ampliado | Más de 1 500 objetos sin repetidos, búsqueda por NGC/IC y por número Caldwell, todos los Messier y Caldwell encontrados | ✅ | ✅ |
| Cometas | Lectura del archivo del MPC; posiciones de 4 cometas (elíptico, casi parabólico, periódico, hiperbólico) a menos de 3′ de JPL Horizons; filtro por magnitud | ✅ | ✅ |
| Seguimiento del cometa | En un plan contra el simulador, vuelve a apuntar cuando el cometa se ha movido más de 3′ | ✅ | — |
| Listas y maratón | Hechos y pendientes según el historial, CSV, orden del maratón Messier (≥ 95 de 110 en abril) | ✅ | ✅ |
| La semana | Puntuación por nubes, Luna y oscuridad; elige la noche despejada | ✅ | ✅ |
| Horizonte propio | Interpolación, importar y exportar, planificación y listas que lo respetan; la sesión salta un objeto tapado sin apuntar (Seestar simulado) | ✅ | ✅ |
| Línea de tiempo | Orden, espera por «no antes de», tiempo ya hecho, avisos de amanecer y de horizonte | ✅ | ✅ |
| Proyectos y copia de seguridad | Avance desde el historial; la copia nunca incluye la clave PEM y no la sobrescribe al restaurar | ✅ | ✅ |
| Retoque de fotos | FITS ida y vuelta (orientación y cabecera), estirado, recortes, reducción de estrellas y del ruido de color, exportación JPEG/PNG/TIFF 16 bits, pie de foto | ✅ | ✅ |
| Trazas de satélite | Detecta una traza real (y nada en un campo solo de estrellas), la quita; una traza desmarcada no se toca | ✅ | ✅ |
| Nombres de objetos | Proyección TAN, cabecera FITS con matriz CD, estimación con norte arriba, rosa N/E, centro desde el nombre del archivo | ✅ | ✅ |
| GraXpert | Argumentos exactos, programa falso que imita a GraXpert, errores y limpieza de temporales; prueba opcional con el GraXpert instalado (el gradiente bajó de 4920 a 49) | ✅ | ✅ (argumentos) |
| Copia del álbum | Índice HTML seguro (sin «..», rutas ni otros servidores), copia contra un servidor HTTP simulado, reanudación sin volver a descargar, recopia si el archivo local se estropea | ✅ | ✅ (índice) |
| Satélites (SGP4) | Lectura de TLE con suma de control; vectores de referencia de Vallado (error < 1 km); los 29 pasos de la ISS sobre Madrid en 5 días frente a Skyfield (salida y puesta a menos de 1 min, altura máxima a menos de 1,5°); cruce de un satélite por el campo; descarga solo HTTPS de celestrak.org con límite de tamaño | ✅ | ✅ |
| Luna | Libración y punto subsolar frente al ejemplo 53.a de Meeus; terminador en cuarto creciente; posición de los accidentes en el disco; imagen rotulada | ✅ | ✅ (sin imagen) |
| Eventos del cielo | Lluvias de estrellas, fases y conjunciones en seis semanas, orden por fecha, cálculo del mínimo | ✅ | ✅ |
| Hoja de la noche | Datos de la noche y PNG generado | ✅ | — |
| Astronomía | Día juliano, altura de la Polar, precesión, coordenadas, Luna, planetas, salidas y puestas | ✅ | ✅ |
| Qué mirar / Elige por mí | Sugerencias y plan corto; consejos de captura por tipo de objeto | ✅ | — |
| Mosaicos | Número y posición de paneles | ✅ | ✅ |
| Vista en directo | Recorte de bordes inclinados y con ruido, quitar gradiente y neutralizar el fondo | ✅ | ✅ |
| Apilador planetario | Vídeo MP4, SER RGB y Bayer, alineación subpíxel, nitidez | ✅ | — |
| Idiomas | Todos los textos traducidos a los 6 idiomas, cambio de idioma, formatos con variables | ✅ | ✅ |
| Seguridad | Rutas del álbum, bomba ZIP, CSV, ntfy, enlaces, clave PEM, cabecera FITS | ✅ | ✅ |

## Qué solo se puede probar con el Seestar real

Las pruebas no sustituyen a una noche con el telescopio. Conviene vigilar:

- **El recentrado.** Se basa en `scope_get_equ_coord` después del GoTo, tal como lo usa seestar_alp. En el registro aparecerán líneas como «M 31 quedó a X′ del centro…».
- **Los oscuros al final del plan.** Se espera el evento `DarkLibrary`; el nombre viene de seestar_alp.
- **El umbral de nitidez (30 %).** Está probado con estrellas sintéticas; con cielo real puede necesitar ajuste en Ajustes › Enfoque y rocío.
- **El apagado al final del plan** (`pi_shutdown` tras aparcar).
- **La interfaz.** Las pantallas se revisan con capturas, no con pruebas automáticas.
- **La versión de Windows en un PC real.** Compila y pasa las pruebas en Windows en GitHub, pero nadie la ha usado todavía con un telescopio.
