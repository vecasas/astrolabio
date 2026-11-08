// Generado por scripts/companion_build.py a partir de scripts/companion/page.html. No editar a mano.
enum CompanionPage {
    static let html = #"""
<!doctype html>
<html lang="__LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#050d1f">
<title>Astrolabio</title>
<style nonce="__NONCE__">
:root{--bg:#050d1f;--card:#0d1b39;--line:#25407a;--text:#eef3ff;--dim:#9fb2d8;--acc:#52a1ff;--good:#59d9bf;--warn:#ffb859;--bad:#ff7373}
body.night{--bg:#000;--card:#140000;--line:#4a0000;--text:#ff3b2f;--dim:#b3241b;--acc:#ff3b2f;--good:#ff3b2f;--warn:#ff3b2f;--bad:#ff3b2f}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.35 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;padding:16px 16px calc(16px + env(safe-area-inset-bottom))}
h1{font-size:20px;margin:0}
header{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px;gap:8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px 14px;margin-bottom:12px}
.row{display:flex;justify-content:space-between;gap:12px;padding:3px 0}
.dim{color:var(--dim)}
.big{font-size:22px;font-weight:700}
img{width:100%;border-radius:10px;background:#000;display:block;min-height:80px}
body.night img{filter:sepia(1) saturate(6) hue-rotate(-50deg) brightness(.75)}
.bar{height:8px;border-radius:4px;background:var(--line);overflow:hidden;margin-top:6px}
.bar>div{height:100%;background:var(--acc);width:0}
.btns{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px}
button{font:inherit;font-weight:600;border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:12px;padding:14px 8px;min-height:52px}
button.danger{border-color:var(--bad);color:var(--bad)}
button.small{padding:8px 12px;min-height:0}
input{font:inherit;font-size:28px;letter-spacing:6px;text-align:center;width:100%;padding:10px;border-radius:12px;border:1px solid var(--line);background:#000;color:var(--text)}
#msg{min-height:1.4em}
.hidden{display:none}
ul{margin:0;padding-left:18px}
.wide{width:100%}
.top{margin-top:12px}
</style>
</head>
<body>
<header><h1>🔭 Astrolabio</h1><button id="night" class="small"></button></header>
<section id="pair" class="card hidden">
  <p id="pairText"></p>
  <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]*">
  <p><button id="pairBtn" class="wide"></button></p>
</section>
<section id="main" class="hidden">
  <div class="card">
    <div class="row"><span class="dim" id="lTarget"></span><span class="big" id="target">—</span></div>
    <div class="row"><span class="dim" id="lPhase"></span><span id="phase">—</span></div>
    <div class="row"><span class="dim" id="lFrames"></span><span id="frames">—</span></div>
    <div class="row"><span class="dim" id="lBattery"></span><span id="battery">—</span></div>
    <div class="row"><span class="dim" id="lPlan"></span><span id="plan">—</span></div>
    <div class="bar"><div id="planBar"></div></div>
  </div>
  <div class="card"><img id="img" alt=""><div class="dim" id="imgInfo"></div></div>
  <div class="btns"><button id="stop" class="danger"></button><button id="skip"></button><button id="park" class="danger"></button></div>
  <div class="card top"><div class="dim" id="lLog"></div><ul id="log"></ul></div>
</section>
<p id="msg" class="dim"></p>
<script nonce="__NONCE__" id="i18n" type="application/json">__I18N__</script>
<script nonce="__NONCE__">
(function(){
"use strict";
var T=JSON.parse(document.getElementById("i18n").textContent);
function $(id){return document.getElementById(id)}
function txt(id,s){$(id).textContent=s}
function store(k,v){try{if(v===null)localStorage.removeItem(k);else localStorage.setItem(k,v)}catch(e){}}
function load(k){try{return localStorage.getItem(k)}catch(e){return null}}
var key=load("astrolabio.key"), imgUrl=null, lastImg=0;
["Target","Phase","Frames","Battery","Plan","Log"].forEach(function(n){txt("l"+n,T["l"+n])});
txt("stop",T.stop);txt("skip",T.skip);txt("park",T.park);txt("pairText",T.pairText);txt("pairBtn",T.pairBtn);
function setNight(on){document.body.classList.toggle("night",on);txt("night",on?T.dayMode:T.nightMode);store("astrolabio.night",on?"1":null)}
setNight(load("astrolabio.night")==="1");
$("night").onclick=function(){setNight(!document.body.classList.contains("night"))};
function api(method,path,body){
  var h={"Authorization":"Bearer "+key};
  if(body){h["Content-Type"]="application/json"}
  return fetch(path,{method:method,headers:h,body:body?JSON.stringify(body):undefined,cache:"no-store",credentials:"omit"});
}
var pairToken=null;
var m=/[#&]p=([A-Za-z0-9_-]{16,64})/.exec(location.hash);
if(m){pairToken=m[1];history.replaceState(null,"",location.pathname)}
function showPair(){$("pair").classList.remove("hidden");$("main").classList.add("hidden");if(!pairToken)txt("pairText",T.needQR)}
function showMain(){$("pair").classList.add("hidden");$("main").classList.remove("hidden")}
$("pairBtn").onclick=function(){
  if(!pairToken){return}
  fetch("/api/pair",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({pair:pairToken,code:$("code").value}),cache:"no-store",credentials:"omit"})
  .then(function(r){return r.json().then(function(j){return{ok:r.ok,j:j}})})
  .then(function(x){if(x.ok&&x.j.key){key=x.j.key;store("astrolabio.key",key);txt("msg","");showMain();tick()}else{txt("msg",x.j.error||T.pairFail)}})
  .catch(function(){txt("msg",T.offline)});
};
function act(name,question){
  if(!confirm(question))return;
  api("POST","/api/"+name).then(function(r){return r.json()}).then(function(j){txt("msg",j.message||"")}).catch(function(){txt("msg",T.offline)});
}
$("stop").onclick=function(){act("stop",T.askStop)};
$("skip").onclick=function(){act("skip",T.askSkip)};
$("park").onclick=function(){act("park",T.askPark)};
function render(s){
  txt("target",s.target||"—");txt("phase",s.phase||"—");
  txt("frames",s.frames!=null?s.frames+(s.exposure?" × "+s.exposure+" s":""):"—");
  txt("battery",s.battery!=null?s.battery+" %"+(s.charging?" ⚡":""):"—");
  if(s.plan&&s.plan.total){txt("plan",s.plan.done+" / "+s.plan.total+(s.plan.remainingMin!=null?" · "+s.plan.remainingMin+" min":""));$("planBar").style.width=Math.round(100*s.plan.done/s.plan.total)+"%"}
  else{txt("plan","—");$("planBar").style.width="0"}
  var ul=$("log");while(ul.firstChild)ul.removeChild(ul.firstChild);
  (s.messages||[]).forEach(function(t){var li=document.createElement("li");li.textContent=t;ul.appendChild(li)});
  txt("msg",s.connected?"":T.noScope);
  $("stop").disabled=$("park").disabled=!s.connected;$("skip").disabled=!s.running;
}
function image(){
  api("GET","/api/image.jpg").then(function(r){if(r.status===200)return r.blob();return null}).then(function(b){
    if(!b)return;var u=URL.createObjectURL(b);$("img").src=u;if(imgUrl)URL.revokeObjectURL(imgUrl);imgUrl=u;
    txt("imgInfo",T.updated+" "+new Date().toLocaleTimeString());
  }).catch(function(){});
}
function tick(){
  if(!key){showPair();return}
  api("GET","/api/status").then(function(r){
    if(r.status===401){key=null;store("astrolabio.key",null);showPair();return null}
    return r.json();
  }).then(function(s){if(!s)return;showMain();render(s);if(Date.now()-lastImg>15000){lastImg=Date.now();image()}})
  .catch(function(){txt("msg",T.offline)});
}
if(pairToken||!key)showPair();else showMain();
tick();setInterval(tick,5000);
})();
</script>
</body>
</html>
"""#
}
