// Generado a partir de Sources/Astrolabio/Views/GuideViews.swift (mismos textos que en el Mac).
namespace Astrolabio.App.Views;

public sealed record ManualTopic(string Id, Section? Section, string TitleKey, string BodyKey);

public static class GuideContent
{
    public static readonly ManualTopic[] Topics =
    [
        new("start", Section.Start, "Primeros pasos", "Enciende el Seestar y conéctalo a la misma wifi que el ordenador (modo estación en la app oficial). En Astrolabio pulsa «Conectar»: busca el telescopio solo. Pon tu lugar en Ajustes para que las horas y las alturas sean correctas."),
        new("connect", Section.Telescope, "Conectar el telescopio", "Astrolabio habla con el Seestar por la red local. Si no lo encuentra, escribe su dirección IP en Ajustes (la ves en la app oficial o en el router). Las órdenes de movimiento con firmware reciente necesitan la clave PEM: indica la ruta del archivo en Ajustes; Astrolabio nunca la copia ni la envía."),
        new("tonight", Section.Tonight, "Qué mirar esta noche", "Ordena los objetos por tiempo útil alto y a oscuras, distancia a la Luna, nubes previstas y si caben en el campo. Pulsa un objeto para ver su foto, cuándo está mejor y para apuntar o añadirlo al plan."),
        new("pick", Section.Pick, "Elige por mí", "Si no sabes por dónde empezar, elige un estilo (lo mejor, fácil, un reto o sorpresa) y Astrolabio propone un objeto y un plan corto para ahora mismo."),
        new("goto", Section.Telescope, "Apuntar (GoTo)", "Antes de mover, Astrolabio comprueba que el objeto está sobre la altura mínima y lejos del Sol. Si el telescopio está apilando, pregunta antes de interrumpir. Tras el GoTo puede recentrar con resolución de placa."),
        new("live", Section.Live, "Vista en directo", "Muestra la imagen apilada mientras crece. Puedes estirarla, ajustar el color y guardar una copia. El modo «Fiesta de estrellas» la pone a pantalla completa para enseñarla."),
        new("planner", Section.Planner, "Planificar la noche", "Añade objetos con su tiempo de apilado, filtro y enfoque. La línea de tiempo muestra cuándo se hará cada uno y avisa si alguno queda tras el horizonte o después del amanecer."),
        new("session", Section.Session, "Sesión automática", "Ejecuta el plan sin vigilancia: espera a que oscurezca, apunta, enfoca, apila, pasa al siguiente, se pausa con nubes o tormenta y aparca al amanecer. Si el telescopio se reinicia, retoma el plan."),
        new("mosaic", Section.Mosaic, "Mosaicos", "Para objetos más grandes que el campo (44′ × 77′): divide el encuadre en paneles de hasta 3 × 3 con solape y los añade al plan."),
        new("lists", Section.Lists, "Listas y proyectos", "Las listas Messier y Caldwell marcan lo fotografiado. Un proyecto suma horas de varias noches sobre el mismo objeto hasta el objetivo que pongas."),
        new("horizon", Section.Horizon, "Mi horizonte", "Dibuja la altura de árboles y tejados alrededor. Lo que quede detrás no se sugiere y la sesión automática lo espera o lo salta."),
        new("moon", Section.Moon, "La Luna", "Fase, salida y puesta, y los cráteres que lucen esta noche junto al terminador, rotulados sobre la Luna. El Seestar la ve entera: usa el modo Luna y amplía la imagen."),
        new("planets", Section.Planets, "Planetas y apilador", "Cuándo se ve cada planeta, su tamaño y brillo. Para más detalle graba un vídeo con el modo planeta y apílalo en «Apilador planetario»."),
        new("events", Section.Events, "Eventos del cielo", "Lluvias de estrellas, conjunciones, oposiciones y cometas de las próximas seis semanas, con etiquetas que dicen si caben en el campo del Seestar."),
        new("satellites", Section.Satellites, "Satélites", "Pasos visibles de la Estación Espacial y satélites brillantes. Durante la sesión automática se avisa si alguno va a cruzar el objeto que se apila."),
        new("sheet", Section.NightSheet, "Hoja de la noche", "Una imagen con las horas de oscuridad, la Luna, los planetas, los mejores objetos y los eventos, para guardar, copiar o imprimir."),
        new("album", Section.Album, "Álbum", "Las fotos guardadas en el telescopio. Puedes verlas, descargarlas, copiar el álbum entero al ordenador o abrir una en el editor. Astrolabio nunca borra nada del telescopio."),
        new("editor", Section.Editor, "Retoque de fotos", "Quita el gradiente, el ruido y las trazas de satélite, ajusta color y brillo, recorta y añade los nombres de los objetos. Siempre se guarda una copia; el original no se toca."),
        new("weather", Section.Weather, "Tiempo", "Nubes por horas, viento, humedad y riesgo de rocío. Los avisos oficiales y el radar de lluvia ayudan a decidir si merece la pena sacar el telescopio."),
        new("phone", Section.Phone, "Control desde el móvil", "Activa el servidor, muestra el QR y escanéalo con el móvil en la misma wifi; escribe el código de 6 cifras. El móvil ve el estado y la imagen y puede parar, saltar o aparcar. Quita el acceso cuando quieras."),
        new("night", null, "Modo nocturno", "Tiñe toda la app de rojo para no perder la adaptación a la oscuridad. Se activa con Ctrl+N, con el botón del ojo o solo al anochecer."),
        new("safety", null, "Seguridad del telescopio", "Astrolabio no apunta cerca del Sol ni por debajo de la altura mínima, avisa de batería baja y de tormentas, y aparca al amanecer. Nunca apuntes al Sol sin el filtro solar."),
        new("beginner", null, "Modo principiante y avanzado", "En modo principiante la barra lateral muestra solo lo esencial y empieza en «Empieza aquí». Cambia a avanzado arriba en la barra lateral para ver todas las secciones."),
    ];

    public static readonly (Section Section, string TitleKey, string TextKey)[] Tutorial =
    [
        (Section.Start, "Bienvenido a Astrolabio", "Este recorrido de un par de minutos enseña lo esencial. Puedes salir cuando quieras y repetirlo desde «Empieza aquí»."),
        (Section.Telescope, "1. Conecta el Seestar", "Con el telescopio en tu wifi, pulsa «Conectar». Arriba a la derecha verás si está conectado y su batería."),
        (Section.Tonight, "2. Qué mirar esta noche", "Aquí están los mejores objetos de esta noche, ordenados para ti. La nota tiene en cuenta altura, oscuridad, Luna y nubes."),
        (Section.Tonight, "3. Abre un objeto", "Pulsa cualquier objeto para ver su foto, su mejor hora y los botones para apuntar o añadirlo al plan."),
        (Section.Pick, "4. ¿Indeciso?", "«Elige por mí» propone un objeto y un plan corto según el estilo que prefieras."),
        (Section.Telescope, "5. Apunta y apila", "Desde un objeto o desde aquí, el GoTo mueve el telescopio. Después pulsa «Apilar» para empezar a acumular luz."),
        (Section.Live, "6. Mira cómo crece la imagen", "La vista en directo muestra el apilado. Cuantos más minutos, menos ruido y más detalle."),
        (Section.Live, "7. Guarda la foto", "Guarda una copia en el ordenador cuando te guste. El telescopio también la guarda en su álbum."),
        (Section.Moon, "8. La Luna y los planetas", "La Luna y los planetas tienen su propia sección, con sus horas y los cráteres que lucen esta noche."),
        (Section.Weather, "9. Mira el tiempo", "Antes de salir, revisa las nubes por horas y el riesgo de rocío."),
        (Section.Album, "10. Tu álbum", "Todas tus fotos del telescopio, para verlas o copiarlas al ordenador."),
        (Section.Phone, "11. Controla desde el móvil", "Si quieres seguir la noche desde el sofá, activa el control desde el móvil y empareja tu teléfono con el QR."),
        (Section.Help, "12. Ayuda siempre a mano", "El botón «?» de arriba abre el manual en la sección donde estés. También puedes buscar cualquier tema."),
        (Section.Start, "13. Modo avanzado", "Cuando quieras más (planificar la noche, sesiones automáticas, mosaicos, retoque), cambia a «Avanzado» en la barra lateral."),
        (Section.Start, "¡Listo!", "Cielos despejados. Recuerda: nunca apuntes al Sol sin filtro solar."),
    ];
}
