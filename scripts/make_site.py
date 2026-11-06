#!/usr/bin/env python3
"""Genera la web de descarga (docs/index.html en español y docs/en/index.html en inglés).
Uso: python3 scripts/make_site.py"""
import os, html

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
REPO = 'https://github.com/vecasas/astrolabio'
LATEST = REPO + '/releases/latest'
DL = LATEST + '/download/'
EMAIL = 'vecasas@gmail.com'
AUTHOR = 'Víctor Casas'

APPLE = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9 0 0-2.7-1-2.7-4.1zM13.9 4.9c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.3 2-1.1 3.1 1.1.1 2.3-.6 3.1-1.5z"/></svg>'
WIN = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 5.5 10.4 4.5v7H3zM11.4 4.4 21 3v8.5h-9.6zM3 12.5h7.4v7L3 18.5zM11.4 12.5H21V21l-9.6-1.4z"/></svg>'

T = {
 'es': {
  'lang': 'es', 'other': 'English', 'other_href': 'en/', 'prefix': '',
  'title': 'Astrolabio — control del Seestar S50 para Mac y Windows',
  'desc': 'Aplicación gratuita para planificar la noche, controlar el telescopio Seestar S50 y procesar tus fotos, en Mac y Windows.',
  'nav': ['Funciones', 'Capturas', 'Instalar', 'Conectar'],
  'eyebrow': 'Gratis · Código abierto · Mac y Windows',
  'h1': 'Tu Seestar, <em>desde el ordenador</em>',
  'lead': 'Astrolabio te dice qué mirar esta noche, apunta el telescopio, muestra la imagen en directo y guarda un informe de cada sesión. Todo en una ventana, en seis idiomas.',
  'mac': 'Descargar para Mac', 'mac_sub': 'macOS 14 o posterior · .dmg',
  'win': 'Descargar para Windows', 'win_sub': 'Windows 10 y 11 · instalador',
  'zip': 'Versión portable (.zip)', 'all': 'Todas las versiones',
  'f_title': 'Lo que hace', 'f_sub': 'Pensada para sacar partido al Seestar sin depender del móvil, con pantalla grande y teclado.',
  'features': [
   ('🔭', 'Qué mirar esta noche', 'Objetos visibles según tu lugar, la Luna y las nubes, con foto, descripción y la mejor hora.'),
   ('✨', 'Elige por mí', 'Un clic y te propone un objetivo según el tiempo que tengas y lo que te apetezca ver.'),
   ('🎯', 'Control completo', 'GoTo, apilado, enfoque, filtro antipolución, dither, mosaicos y sesiones automáticas.'),
   ('📷', 'Vista en directo mejorada', 'Recorte de bordes, fondo y color calibrados y estirado para ver el apilado como debe.'),
   ('🌙', 'Luna y planetas', 'Fases, efemérides, carta estelar y un apilador planetario para tus vídeos.'),
   ('📄', 'Informes en PDF', 'Cada noche queda registrada: objetos, tiempo, condiciones, ajustes y eventos, listo para descargar.'),
   ('📊', 'Estadísticas y álbum', 'Horas de integración, objetos favoritos y las imágenes guardadas en el telescopio.'),
   ('🌑', 'Modo nocturno', 'Todo en rojo tenue para no perder la adaptación a la oscuridad.'),
   ('🌍', 'Seis idiomas', 'Español, inglés, francés, alemán, chino y ruso.'),
  ],
  'g_title': 'Capturas', 'g_sub': 'Imágenes reales de la aplicación en el Mac.',
  'shots': [('tonight', 'Qué mirar: sugerencias para esta noche'), ('pick', 'Elige por mí'), ('skyChart', 'Carta estelar'),
            ('telescope', 'Control del telescopio'), ('moon', 'Luna'), ('mosaic', 'Mosaicos sobre la imagen del objeto')],
  'i_title': 'Instalar', 'i_sub': 'La aplicación no está firmada por Apple ni por Microsoft (es un proyecto personal y gratuito), así que el sistema avisa la primera vez.',
  'i_mac': 'Mac', 'i_win': 'Windows',
  'mac_steps': ['Abre el <code>.dmg</code> y arrastra Astrolabio a Aplicaciones.',
                'La primera vez, haz clic derecho sobre la app y elige <b>Abrir</b>.',
                'Si macOS no lo permite, ve a <b>Ajustes del Sistema › Privacidad y seguridad</b> y pulsa <b>Abrir igualmente</b>.'],
  'mac_cmd': 'O desde Terminal:',
  'win_steps': ['Ejecuta <code>Astrolabio-…-Windows-Setup.exe</code>.',
                'Si aparece «Windows protegió su PC» (SmartScreen), pulsa <b>Más información › Ejecutar de todas formas</b>.',
                'También puedes usar la versión portable: descomprime el .zip y abre <code>Astrolabio.exe</code>.'],
  'c_title': 'Conectar con el Seestar',
  'c_steps': ['En la app oficial, activa el <b>modo estación</b> para que el Seestar se una a la wifi de tu casa.',
              'Conecta el ordenador a esa misma wifi.',
              'Abre Astrolabio: busca el telescopio solo, o escribe su IP (la verás en tu router o en la app oficial).'],
  'pem_title': 'Sobre la clave de autenticación (PEM)',
  'pem': 'Con el firmware reciente, el Seestar solo obedece a aplicaciones que se identifican con una clave privada. Astrolabio <b>no incluye ni distribuye</b> ninguna clave. La comunidad ha publicado <a href="https://github.com/bguthro/seestar-tool">seestar-tool</a>, que permite obtenerla a partir de tu propia copia de la app oficial; después indicas el archivo <code>.pem</code> en los Ajustes de Astrolabio. Hazlo solo con tu propio equipo y bajo tu responsabilidad. Sin clave, Astrolabio puede mostrar el estado, pero el telescopio puede ignorar las órdenes.',
  'req_title': 'Requisitos', 'req': ['macOS 14 Sonoma o posterior (Apple Silicon o Intel).', 'Windows 10 u 11 de 64 bits.', 'Seestar S50 con conexión wifi en modo estación.'],
  'd_title': '¿Te es útil?', 'd_sub': 'Astrolabio es gratis. Si quieres apoyar su desarrollo, puedes invitarme a un café.',
  'd_btn': 'Apoyar el proyecto', 'd_soon': 'Las donaciones estarán disponibles pronto.',
  'disclaimer': 'Compatible con Seestar S50. Proyecto independiente, no afiliado a ZWO.',
  'made': 'Creado por', 'contact': 'Contacto', 'code': 'Código fuente',
 },
 'en': {
  'lang': 'en', 'other': 'Español', 'other_href': '../', 'prefix': '../',
  'title': 'Astrolabio — Seestar S50 control for Mac and Windows',
  'desc': 'A free app to plan your night, control the Seestar S50 telescope and process your images, on Mac and Windows.',
  'nav': ['Features', 'Screenshots', 'Install', 'Connect'],
  'eyebrow': 'Free · Open source · Mac and Windows',
  'h1': 'Your Seestar, <em>from your computer</em>',
  'lead': 'Astrolabio tells you what to observe tonight, points the telescope, shows the live image and keeps a report of every session. All in one window, in six languages.',
  'mac': 'Download for Mac', 'mac_sub': 'macOS 14 or later · .dmg',
  'win': 'Download for Windows', 'win_sub': 'Windows 10 and 11 · installer',
  'zip': 'Portable version (.zip)', 'all': 'All releases',
  'f_title': 'What it does', 'f_sub': 'Built to get the most out of the Seestar without relying on your phone, with a big screen and a keyboard.',
  'features': [
   ('🔭', 'What to observe tonight', 'Objects visible from your site given the Moon and clouds, with a picture, description and the best time.'),
   ('✨', 'Pick for me', 'One click suggests a target based on how much time you have and what you feel like seeing.'),
   ('🎯', 'Full control', 'GoTo, stacking, focus, light-pollution filter, dithering, mosaics and automatic sessions.'),
   ('📷', 'Better live view', 'Edge cropping, calibrated background and colour, and a proper stretch for your stack.'),
   ('🌙', 'Moon and planets', 'Phases, ephemerides, a star chart and a planetary stacker for your videos.'),
   ('📄', 'PDF reports', 'Every night is logged: objects, timing, conditions, settings and events, ready to download.'),
   ('📊', 'Statistics and album', 'Integration hours, favourite objects and the images stored on the telescope.'),
   ('🌑', 'Night mode', 'Everything in dim red so you keep your dark adaptation.'),
   ('🌍', 'Six languages', 'Spanish, English, French, German, Chinese and Russian.'),
  ],
  'g_title': 'Screenshots', 'g_sub': 'Real screenshots of the app on a Mac.',
  'shots': [('tonight', 'What to observe: tonight’s suggestions'), ('pick', 'Pick for me'), ('skyChart', 'Star chart'),
            ('telescope', 'Telescope control'), ('moon', 'Moon'), ('mosaic', 'Mosaics over the object’s image')],
  'i_title': 'Install', 'i_sub': 'The app is not signed by Apple or Microsoft (it is a free personal project), so your system will warn you the first time.',
  'i_mac': 'Mac', 'i_win': 'Windows',
  'mac_steps': ['Open the <code>.dmg</code> and drag Astrolabio to Applications.',
                'The first time, right-click the app and choose <b>Open</b>.',
                'If macOS refuses, go to <b>System Settings › Privacy &amp; Security</b> and click <b>Open Anyway</b>.'],
  'mac_cmd': 'Or from Terminal:',
  'win_steps': ['Run <code>Astrolabio-…-Windows-Setup.exe</code>.',
                'If “Windows protected your PC” (SmartScreen) appears, click <b>More info › Run anyway</b>.',
                'You can also use the portable version: unzip it and open <code>Astrolabio.exe</code>.'],
  'c_title': 'Connecting to the Seestar',
  'c_steps': ['In the official app, enable <b>station mode</b> so the Seestar joins your home Wi-Fi.',
              'Connect your computer to the same Wi-Fi.',
              'Open Astrolabio: it finds the telescope automatically, or type its IP (shown in your router or the official app).'],
  'pem_title': 'About the authentication key (PEM)',
  'pem': 'With recent firmware, the Seestar only obeys apps that identify themselves with a private key. Astrolabio <b>does not include or distribute</b> any key. The community has published <a href="https://github.com/bguthro/seestar-tool">seestar-tool</a>, which can obtain it from your own copy of the official app; you then select the <code>.pem</code> file in Astrolabio’s Settings. Do this only with your own equipment and at your own responsibility. Without a key Astrolabio can show the status, but the telescope may ignore commands.',
  'req_title': 'Requirements', 'req': ['macOS 14 Sonoma or later (Apple Silicon or Intel).', '64-bit Windows 10 or 11.', 'Seestar S50 on Wi-Fi in station mode.'],
  'd_title': 'Find it useful?', 'd_sub': 'Astrolabio is free. If you want to support its development, you can buy me a coffee.',
  'd_btn': 'Support the project', 'd_soon': 'Donations will be available soon.',
  'disclaimer': 'Compatible with Seestar S50. Independent project, not affiliated with ZWO.',
  'made': 'Made by', 'contact': 'Contact', 'code': 'Source code',
 },
}


def page(t):
    p = t['prefix']
    lang = t['lang']
    feats = '\n'.join(f'<div class="card"><div class="icon">{i}</div><h3>{h}</h3><p>{d}</p></div>' for i, h, d in t['features'])
    shots = '\n'.join(f'<figure><img loading="lazy" src="{p}img/{k}-{lang}.jpg" alt="{html.escape(c)}" width="1400" height="1202"><figcaption>{c}</figcaption></figure>' for k, c in t['shots'])
    li = lambda xs: '\n'.join(f'<li>{x}</li>' for x in xs)
    n = t['nav']
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<meta name="description" content="{t['desc']}">
<meta property="og:title" content="{t['title']}">
<meta property="og:description" content="{t['desc']}">
<meta property="og:image" content="https://vecasas.github.io/astrolabio/img/tonight-{lang}.jpg">
<link rel="icon" href="{p}favicon.png">
<link rel="alternate" hreflang="es" href="https://vecasas.github.io/astrolabio/">
<link rel="alternate" hreflang="en" href="https://vecasas.github.io/astrolabio/en/">
<link rel="stylesheet" href="{p}style.css">
<script src="{p}config.js"></script>
</head>
<body>
<header class="top"><div class="wrap">
  <a class="brand" href="#"><img src="{p}img/icon.png" alt="">Astrolabio</a>
  <nav class="links">
    <a href="#features">{n[0]}</a><a href="#screens">{n[1]}</a><a href="#install">{n[2]}</a><a href="#connect">{n[3]}</a>
    <a class="lang" href="{t['other_href']}">{t['other']}</a>
  </nav>
</div></header>

<main>
<div class="wrap hero" id="download">
  <div>
    <div class="eyebrow">{t['eyebrow']}</div>
    <h1>{t['h1']}</h1>
    <p class="lead">{t['lead']}</p>
    <div class="cta">
      <a class="btn primary" data-asset="mac" href="{LATEST}">{APPLE}<span>{t['mac']}<small>{t['mac_sub']}</small></span></a>
      <a class="btn" data-asset="win" href="{LATEST}">{WIN}<span>{t['win']}<small>{t['win_sub']}</small></span></a>
    </div>
    <p class="note"><a data-asset="zip" href="{LATEST}">{t['zip']}</a> · <a href="{REPO}/releases">{t['all']}</a> · <span id="ver"></span></p>
  </div>
  <img class="shot" src="{p}img/tonight-{lang}.jpg" alt="Astrolabio" width="1400" height="1202">
</div>

<section id="features"><div class="wrap">
  <h2>{t['f_title']}</h2><p class="sub">{t['f_sub']}</p>
  <div class="grid">
{feats}
  </div>
</div></section>

<section id="screens"><div class="wrap">
  <h2>{t['g_title']}</h2><p class="sub">{t['g_sub']}</p>
  <div class="gallery">
{shots}
  </div>
</div></section>

<section id="install"><div class="wrap">
  <h2>{t['i_title']}</h2><p class="sub">{t['i_sub']}</p>
  <div class="two">
    <div class="card"><h3>{APPLE.replace('<svg', '<svg width="18" height="18" style="vertical-align:-3px"')} {t['i_mac']}</h3>
      <ol class="steps">{li(t['mac_steps'])}</ol>
      <p class="note">{t['mac_cmd']}</p>
      <pre>xattr -dr com.apple.quarantine /Applications/Astrolabio.app</pre>
    </div>
    <div class="card"><h3>{WIN.replace('<svg', '<svg width="18" height="18" style="vertical-align:-3px"')} {t['i_win']}</h3>
      <ol class="steps">{li(t['win_steps'])}</ol>
    </div>
  </div>
  <div class="card" style="margin-top:18px"><h3>{t['req_title']}</h3><ul>{li(t['req'])}</ul></div>
</div></section>

<section id="connect"><div class="wrap">
  <h2>{t['c_title']}</h2>
  <div class="two">
    <div class="card"><ol class="steps">{li(t['c_steps'])}</ol></div>
    <div class="callout"><h3 style="color:var(--text);margin-top:0">{t['pem_title']}</h3><p>{t['pem']}</p></div>
  </div>
</div></section>

<section class="donate"><div class="wrap">
  <h2>{t['d_title']}</h2><p class="sub" style="margin:0 auto">{t['d_sub']}</p>
  <a class="btn primary" id="donate" href="#" hidden>☕ {t['d_btn']}</a>
  <p class="note" id="donate-soon">{t['d_soon']}</p>
</div></section>
</main>

<footer><div class="wrap">
  <div>
    <p><b>Astrolabio</b> · {t['disclaimer']}</p>
    <p>{t['made']} {AUTHOR} · {t['contact']}: <a href="mailto:{EMAIL}">{EMAIL}</a></p>
  </div>
  <div><p><a href="{REPO}">{t['code']} (GitHub)</a></p></div>
</div></footer>

<script>
// Enlaces directos a la última versión publicada (si la API de GitHub no responde, se queda la página de versiones).
fetch("https://api.github.com/repos/vecasas/astrolabio/releases/latest").then(r => r.ok ? r.json() : null).then(rel => {{
  if (!rel) return;
  const find = re => (rel.assets || []).find(a => re.test(a.name));
  const map = {{ mac: /\\.dmg$/i, win: /Setup\\.exe$/i, zip: /portable\\.zip$/i }};
  document.querySelectorAll("[data-asset]").forEach(el => {{
    const a = find(map[el.dataset.asset]); if (a) el.href = a.browser_download_url;
  }});
  document.getElementById("ver").textContent = rel.tag_name;
}}).catch(() => {{}});
// Botón de donación: se configura en config.js.
const url = (window.ASTROLABIO || {{}}).donateUrl;
if (url) {{
  const b = document.getElementById("donate"); b.href = url; b.hidden = false;
  document.getElementById("donate-soon").hidden = true;
}}
</script>
</body>
</html>
'''


for key, t in T.items():
    out = os.path.join(ROOT, 'docs', '' if key == 'es' else key, 'index.html')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'w', encoding='utf-8').write(page(t))
    print('ok', os.path.relpath(out, ROOT))
