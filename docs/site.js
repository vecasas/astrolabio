// Web de Astrolabio: enlaces a la última versión y botón de donación.
// Sin cookies, sin analítica y sin servicios de terceros salvo la API pública de GitHub.
(function () {
  "use strict";
  var RELEASES = "https://github.com/vecasas/astrolabio/releases/download/";
  fetch("https://api.github.com/repos/vecasas/astrolabio/releases/latest")
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (rel) {
      if (!rel || !Array.isArray(rel.assets)) return;
      var map = { mac: /\.dmg$/i, win: /Setup\.exe$/i, zip: /portable\.zip$/i };
      document.querySelectorAll("[data-asset]").forEach(function (el) {
        var re = map[el.dataset.asset];
        var a = rel.assets.find(function (x) { return re && re.test(x.name); });
        // Solo se aceptan enlaces de descarga de este repositorio.
        if (a && typeof a.browser_download_url === "string" && a.browser_download_url.indexOf(RELEASES) === 0) {
          el.href = a.browser_download_url;
        }
      });
      if (typeof rel.tag_name === "string" && /^v\d+\.\d+\.\d+$/.test(rel.tag_name)) {
        document.getElementById("ver").textContent = rel.tag_name;
      }
    })
    .catch(function () {});

  // Botón de donación (se configura en config.js). Solo enlaces HTTPS.
  var url = (window.ASTROLABIO || {}).donateUrl;
  if (typeof url === "string" && /^https:\/\//.test(url)) {
    var b = document.getElementById("donate");
    b.href = url;
    b.rel = "noopener";
    b.hidden = false;
    document.getElementById("donate-soon").hidden = true;
  }
})();
