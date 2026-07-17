'use strict';

// ── init() — boot sequence ────────────────────────────────────────────────────
// Entry point. Runs once when the DOM is ready.
//
//   1. Bind canvas and set up sizing.
//   2. Register bridge, visibility, and resize handlers.
//   3. Load last-known location from localStorage → pre-populate S.lat/lon.
//   4. Load last-known weather from localStorage → applyWeather() for instant
//      display (even if stale from a previous session).
//   5. Start the rAF render loop — sky animation begins immediately.
//   6. If cached location exists, call refreshWeather() right away so fresh
//      data arrives without waiting for geolocation to complete. This is the
//      key fix for the stale-data bug: we no longer depend on resolveLocation()
//      settling before the first network fetch.
//   7. Kick off resolveLocation() in parallel — updates S.lat/lon with the
//      current device location, then calls refreshWeather() again with the
//      fresh coordinates. The second call overwrites step 6's result if the
//      location has moved.
function init(){
  S.canvas=document.getElementById('wa-sky');
  S.ctx=S.canvas.getContext('2d');
  var now=new Date();
  var hr=now.getHours();
  S.isDay=hr>=6&&hr<18;
  resizeCanvas();
  window.addEventListener('resize',resizeCanvas);
  setupBridge();
  setupAttribution();
  setupVisibility();
  var cachedLoc=loadCachedLocation();
  if(cachedLoc){S.lat=cachedLoc.lat;S.lon=cachedLoc.lon;S.label=cachedLoc.label;}
  var cachedW=loadCachedWeather();
  if(cachedW){applyWeather(cachedW);}
  else{renderFallbackUI();showPill('waiting for weather\u2026');}
  S.animationFrameId=requestAnimationFrame(render);
  // Eagerly refresh the cached coordinates ONLY in auto mode, where the cached
  // location is the user's last real location and showing it fast is the point.
  // In manual mode the cached coordinates may belong to a different place, and
  // firing this forecast would race the manual-location forecast below — the
  // race that made the current-conditions credit flip sources. Manual mode
  // instead waits for resolveLocation() (geocode) to produce the one forecast
  // for the location the user actually chose.
  if(S.props.locationMode!=='manual'&&S.lat!=null&&S.lon!=null){
    setTimeout(function(){refreshWeather();},100);
  }
  resolveLocation().then(function(){
    refreshWeather();
  });
}

if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',init);}
else{init();}
