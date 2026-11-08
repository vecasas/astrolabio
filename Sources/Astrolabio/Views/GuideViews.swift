import SwiftUI

// MARK: - Contenido (manual y tutorial)

/// Tema del manual integrado. `section` enlaza la ayuda «?» de cada pantalla.
struct ManualTopic: Identifiable {
    let id: String
    let section: AppSection?
    let title: String
    let body: String
}

enum Guide {
    /// Secciones que se ven en modo principiante.
    static let beginnerSections: Set<AppSection> = [.start, .tonight, .pick, .telescope, .live, .moon, .planets, .album, .weather, .phone, .help]

    static var topics: [ManualTopic] {
        [
            ManualTopic(id: "start", section: .start, title: tr("Primeros pasos"),
                        body: tr("Enciende el Seestar y conéctalo a la misma wifi que el ordenador (modo estación en la app oficial). En Astrolabio pulsa «Conectar»: busca el telescopio solo. Pon tu lugar en Ajustes para que las horas y las alturas sean correctas.")),
            ManualTopic(id: "connect", section: .telescope, title: tr("Conectar el telescopio"),
                        body: tr("Astrolabio habla con el Seestar por la red local. Si no lo encuentra, escribe su dirección IP en Ajustes (la ves en la app oficial o en el router). Las órdenes de movimiento con firmware reciente necesitan la clave PEM: indica la ruta del archivo en Ajustes; Astrolabio nunca la copia ni la envía.")),
            ManualTopic(id: "tonight", section: .tonight, title: tr("Qué mirar esta noche"),
                        body: tr("Ordena los objetos por tiempo útil alto y a oscuras, distancia a la Luna, nubes previstas y si caben en el campo. Pulsa un objeto para ver su foto, cuándo está mejor y para apuntar o añadirlo al plan.")),
            ManualTopic(id: "pick", section: .pick, title: tr("Elige por mí"),
                        body: tr("Si no sabes por dónde empezar, elige un estilo (lo mejor, fácil, un reto o sorpresa) y Astrolabio propone un objeto y un plan corto para ahora mismo.")),
            ManualTopic(id: "goto", section: .telescope, title: tr("Apuntar (GoTo)"),
                        body: tr("Antes de mover, Astrolabio comprueba que el objeto está sobre la altura mínima y lejos del Sol. Si el telescopio está apilando, pregunta antes de interrumpir. Tras el GoTo puede recentrar con resolución de placa.")),
            ManualTopic(id: "live", section: .live, title: tr("Vista en directo"),
                        body: tr("Muestra la imagen apilada mientras crece. Puedes estirarla, ajustar el color y guardar una copia. El modo «Fiesta de estrellas» la pone a pantalla completa para enseñarla.")),
            ManualTopic(id: "planner", section: .planner, title: tr("Planificar la noche"),
                        body: tr("Añade objetos con su tiempo de apilado, filtro y enfoque. La línea de tiempo muestra cuándo se hará cada uno y avisa si alguno queda tras el horizonte o después del amanecer.")),
            ManualTopic(id: "session", section: .session, title: tr("Sesión automática"),
                        body: tr("Ejecuta el plan sin vigilancia: espera a que oscurezca, apunta, enfoca, apila, pasa al siguiente, se pausa con nubes o tormenta y aparca al amanecer. Si el telescopio se reinicia, retoma el plan.")),
            ManualTopic(id: "mosaic", section: .mosaic, title: tr("Mosaicos"),
                        body: tr("Para objetos más grandes que el campo (44′ × 77′): divide el encuadre en paneles de hasta 3 × 3 con solape y los añade al plan.")),
            ManualTopic(id: "lists", section: .lists, title: tr("Listas y proyectos"),
                        body: tr("Las listas Messier y Caldwell marcan lo fotografiado. Un proyecto suma horas de varias noches sobre el mismo objeto hasta el objetivo que pongas.")),
            ManualTopic(id: "horizon", section: .horizon, title: tr("Mi horizonte"),
                        body: tr("Dibuja la altura de árboles y tejados alrededor. Lo que quede detrás no se sugiere y la sesión automática lo espera o lo salta.")),
            ManualTopic(id: "moon", section: .moon, title: tr("La Luna"),
                        body: tr("Fase, salida y puesta, y los cráteres que lucen esta noche junto al terminador, rotulados sobre la Luna. El Seestar la ve entera: usa el modo Luna y amplía la imagen.")),
            ManualTopic(id: "planets", section: .planets, title: tr("Planetas y apilador"),
                        body: tr("Cuándo se ve cada planeta, su tamaño y brillo. Para más detalle graba un vídeo con el modo planeta y apílalo en «Apilador planetario».")),
            ManualTopic(id: "events", section: .events, title: tr("Eventos del cielo"),
                        body: tr("Lluvias de estrellas, conjunciones, oposiciones y cometas de las próximas seis semanas, con etiquetas que dicen si caben en el campo del Seestar.")),
            ManualTopic(id: "satellites", section: .satellites, title: tr("Satélites"),
                        body: tr("Pasos visibles de la Estación Espacial y satélites brillantes. Durante la sesión automática se avisa si alguno va a cruzar el objeto que se apila.")),
            ManualTopic(id: "sheet", section: .nightSheet, title: tr("Hoja de la noche"),
                        body: tr("Una imagen con las horas de oscuridad, la Luna, los planetas, los mejores objetos y los eventos, para guardar, copiar o imprimir.")),
            ManualTopic(id: "album", section: .album, title: tr("Álbum"),
                        body: tr("Las fotos guardadas en el telescopio. Puedes verlas, descargarlas, copiar el álbum entero al ordenador o abrir una en el editor. Astrolabio nunca borra nada del telescopio.")),
            ManualTopic(id: "editor", section: .editor, title: tr("Retoque de fotos"),
                        body: tr("Quita el gradiente, el ruido y las trazas de satélite, ajusta color y brillo, recorta y añade los nombres de los objetos. Siempre se guarda una copia; el original no se toca.")),
            ManualTopic(id: "weather", section: .weather, title: tr("Tiempo"),
                        body: tr("Nubes por horas, viento, humedad y riesgo de rocío. Los avisos oficiales y el radar de lluvia ayudan a decidir si merece la pena sacar el telescopio.")),
            ManualTopic(id: "phone", section: .phone, title: tr("Control desde el móvil"),
                        body: tr("Activa el servidor, muestra el QR y escanéalo con el móvil en la misma wifi; escribe el código de 6 cifras. El móvil ve el estado y la imagen y puede parar, saltar o aparcar. Quita el acceso cuando quieras.")),
            ManualTopic(id: "night", section: nil, title: tr("Modo nocturno"),
                        body: tr("Tiñe toda la app de rojo para no perder la adaptación a la oscuridad. Se activa con ⌃⌘N, con el botón del ojo o solo al anochecer.")),
            ManualTopic(id: "safety", section: nil, title: tr("Seguridad del telescopio"),
                        body: tr("Astrolabio no apunta cerca del Sol ni por debajo de la altura mínima, avisa de batería baja y de tormentas, y aparca al amanecer. Nunca apuntes al Sol sin el filtro solar.")),
            ManualTopic(id: "beginner", section: nil, title: tr("Modo principiante y avanzado"),
                        body: tr("En modo principiante la barra lateral muestra solo lo esencial y empieza en «Empieza aquí». Cambia a avanzado arriba en la barra lateral para ver todas las secciones.")),
        ]
    }

    /// Pasos del tutorial: sección que se abre y explicación.
    static var tutorial: [(section: AppSection, title: String, text: String)] {
        [
            (.start, tr("Bienvenido a Astrolabio"), tr("Este recorrido de un par de minutos enseña lo esencial. Puedes salir cuando quieras y repetirlo desde «Empieza aquí».")),
            (.telescope, tr("1. Conecta el Seestar"), tr("Con el telescopio en tu wifi, pulsa «Conectar». Arriba a la derecha verás si está conectado y su batería.")),
            (.tonight, tr("2. Qué mirar esta noche"), tr("Aquí están los mejores objetos de esta noche, ordenados para ti. La nota tiene en cuenta altura, oscuridad, Luna y nubes.")),
            (.tonight, tr("3. Abre un objeto"), tr("Pulsa cualquier objeto para ver su foto, su mejor hora y los botones para apuntar o añadirlo al plan.")),
            (.pick, tr("4. ¿Indeciso?"), tr("«Elige por mí» propone un objeto y un plan corto según el estilo que prefieras.")),
            (.telescope, tr("5. Apunta y apila"), tr("Desde un objeto o desde aquí, el GoTo mueve el telescopio. Después pulsa «Apilar» para empezar a acumular luz.")),
            (.live, tr("6. Mira cómo crece la imagen"), tr("La vista en directo muestra el apilado. Cuantos más minutos, menos ruido y más detalle.")),
            (.live, tr("7. Guarda la foto"), tr("Guarda una copia en el ordenador cuando te guste. El telescopio también la guarda en su álbum.")),
            (.moon, tr("8. La Luna y los planetas"), tr("La Luna y los planetas tienen su propia sección, con sus horas y los cráteres que lucen esta noche.")),
            (.weather, tr("9. Mira el tiempo"), tr("Antes de salir, revisa las nubes por horas y el riesgo de rocío.")),
            (.album, tr("10. Tu álbum"), tr("Todas tus fotos del telescopio, para verlas o copiarlas al ordenador.")),
            (.phone, tr("11. Controla desde el móvil"), tr("Si quieres seguir la noche desde el sofá, activa el control desde el móvil y empareja tu teléfono con el QR.")),
            (.help, tr("12. Ayuda siempre a mano"), tr("El botón «?» de arriba abre el manual en la sección donde estés. También puedes buscar cualquier tema.")),
            (.start, tr("13. Modo avanzado"), tr("Cuando quieras más (planificar la noche, sesiones automáticas, mosaicos, retoque), cambia a «Avanzado» en la barra lateral.")),
            (.start, tr("¡Listo!"), tr("Cielos despejados. Recuerda: nunca apuntes al Sol sin filtro solar.")),
        ]
    }
}

// MARK: - Empieza aquí

@MainActor
struct StartView: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: SeestarClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(tr("Empieza aquí")).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(tr("Cuatro pasos para tu primera foto con el Seestar.")).font(.title3).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18)], spacing: 18) {
                    tile(client.isConnected ? tr("Conectado") : tr("Conectar"), "dot.radiowaves.left.and.right",
                         client.isConnected ? tr("El telescopio está listo.") : tr("Busca el Seestar en tu wifi y conéctate."), .telescope)
                    tile(tr("Qué mirar esta noche"), "binoculars", tr("Los mejores objetos para hoy, ordenados."), .tonight)
                    tile(tr("Elige por mí"), "wand.and.stars", tr("Un objeto y un plan corto, sin pensar."), .pick)
                    tile(tr("Ver en directo"), "camera.aperture", tr("Mira cómo crece la imagen apilada."), .live)
                }
                HStack(spacing: 12) {
                    Button { nav.tutorialStep = 0 } label: { Label(tr("Ver el tutorial"), systemImage: "graduationcap") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { nav.helpTopic = nil; nav.selection = .help } label: { Label(tr("Manual"), systemImage: "book") }
                        .controlSize(.large)
                }
                Card(title: tr("Modo de la app"), systemImage: "slider.horizontal.3") {
                    Picker(tr("Modo"), selection: $settings.beginnerMode) {
                        Text(tr("Principiante")).tag(true)
                        Text(tr("Avanzado")).tag(false)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320).labelsHidden()
                    Text(settings.beginnerMode ? tr("Ves solo las secciones esenciales.") : tr("Ves todas las secciones."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .navigationTitle(tr("Empieza aquí"))
    }

    private func tile(_ title: String, _ icon: String, _ text: String, _ target: AppSection) -> some View {
        Button { nav.selection = target } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.system(size: 38)).foregroundStyle(Theme.accentSoft)
                Text(title).font(.title2.weight(.bold))
                Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Manual

@MainActor
struct HelpView: View {
    @EnvironmentObject var nav: AppNavigation
    @State private var query = ""

    var body: some View {
        let topics = Guide.topics
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let shown = q.isEmpty ? topics : topics.filter {
            ($0.title + " " + $0.body).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q)
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(tr("Buscar en el manual…"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    if shown.isEmpty { Text(tr("No hay temas con esas palabras.")).foregroundStyle(.secondary) }
                    ForEach(shown) { t in
                        Card(title: t.title, systemImage: t.section?.icon ?? "questionmark.circle") {
                            Text(t.body).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if let s = t.section, s != .help {
                                Button(tr("Ir a «%@»", s.label)) { nav.selection = s }.controlSize(.small)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent, lineWidth: nav.helpTopic == t.id ? 2 : 0))
                        .id(t.id)
                    }
                }
                .padding(20)
            }
            .onAppear { if let id = nav.helpTopic { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: nav.helpTopic) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        }
        .navigationTitle(tr("Manual"))
    }
}

/// Botón «?» de la barra superior: abre el manual en el tema de la sección actual.
struct HelpButton: View {
    @EnvironmentObject var nav: AppNavigation
    var body: some View {
        Button {
            let current = nav.selection ?? .tonight
            nav.helpTopic = Guide.topics.first { $0.section == current }?.id
            nav.selection = .help
        } label: {
            Image(systemName: "questionmark.circle").font(.title2)
        }
        .buttonStyle(.plain)
        .help(tr("Ayuda de esta pantalla"))
    }
}

// MARK: - Tutorial

struct TutorialOverlay: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if let i = nav.tutorialStep {
            let steps = Guide.tutorial
            let step = steps[min(i, steps.count - 1)]
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(step.title).font(.title3.weight(.bold))
                        Spacer()
                        Text("\(i + 1) / \(steps.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(step.text).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: Double(i + 1), total: Double(steps.count))
                    HStack {
                        Button(tr("Salir")) { finish() }
                        Spacer()
                        Button(tr("Anterior")) { go(i - 1) }.disabled(i == 0)
                        Button(i == steps.count - 1 ? tr("Terminar") : tr("Siguiente")) {
                            if i == steps.count - 1 { finish() } else { go(i + 1) }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.navy))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 20)
                .padding(24)
            }
            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            .onAppear { nav.selection = step.section }
        }
    }

    private func go(_ i: Int) {
        nav.tutorialStep = i
        nav.selection = Guide.tutorial[i].section
    }

    private func finish() {
        nav.tutorialStep = nil
        settings.tutorialSeen = true
    }
}
