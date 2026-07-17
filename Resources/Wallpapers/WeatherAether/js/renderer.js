'use strict';

// ── rebuildParticles() ───────────────────────────────────────────────────────
// Constructs the particle pool for the current weather type. Called when
// weatherBucket changes (rain → clear, etc.) or on resize. Particle types:
//   rain/thunder  — fast diagonal lines
//   snow          — slow drifting circles with sinusoidal horizontal wobble
//   sleet         — mixed: fast lines (rain) + slower circles (ice pellets)
//   overcast/partly — slow drifting cloud puffs
//   clear night   — stationary twinkling stars
// showParticles:false short-circuits and clears all pools immediately.
function rebuildParticles(){
  S.particles=[];
  S.stars=[];
  S.particleType=null;
  S.fogAlpha=0;
  if(!S.props.showParticles)return;
  var w=cssW(),h=cssH(),bk=S.weatherBucket;
  S.particleType=bk;
  if(bk==='rain'||bk==='thunder'){
    for(var i=0;i<180;i++){
      S.particles.push({x:Math.random()*w,y:Math.random()*h,speed:300+Math.random()*400,len:12+Math.random()*22,op:0.15+Math.random()*0.35});
    }
  }else if(bk==='snow'){
    for(var i=0;i<120;i++){
      S.particles.push({x:Math.random()*w,y:Math.random()*h,speed:25+Math.random()*55,sz:1.5+Math.random()*3,wb:Math.random()*Math.PI*2,wbs:0.8+Math.random()*2,op:0.3+Math.random()*0.5});
    }
  }else if(bk==='sleet'){
    for(var i=0;i<130;i++){
      var ice=Math.random()<0.38;
      S.particles.push(ice?
        {x:Math.random()*w,y:Math.random()*h,speed:120+Math.random()*180,sz:1.2+Math.random()*2.2,op:0.25+Math.random()*0.35,ice:true}:
        {x:Math.random()*w,y:Math.random()*h,speed:250+Math.random()*320,len:6+Math.random()*10,op:0.15+Math.random()*0.28,ice:false});
    }
  }else if(bk==='overcast'||bk==='partly'){
    for(var i=0;i<7;i++){
      S.particles.push({x:Math.random()*w,y:Math.random()*h*0.5,speed:8+Math.random()*16,sz:60+Math.random()*80,op:0.06+Math.random()*0.1});
    }
  }
  if((bk==='clear'||bk==='partly')&&!S.isDay){
    S.stars=[];
    var starCnt=bk==='clear'?90:32;
    for(var i=0;i<starCnt;i++){
      S.stars.push({x:Math.random()*w,y:Math.random()*h*0.65,sz:0.5+Math.random()*1.5,tw:Math.random()*Math.PI*2,tws:1+Math.random()*2.5});
    }
  }
}


// ── updateParticles() ────────────────────────────────────────────────────────
// Advances particle positions by `dt` seconds scaled by animationSpeed. Each
// particle type has its own physics: rain falls diagonally, snow wobbles
// horizontally, cloud puffs drift rightward. Particles that exit the canvas
// are recycled back to a random position at the top (or left edge for puffs).
// Lightning alpha decays exponentially each frame; fog alpha ramps to target.
function updateParticles(dt){
  if(!S.props.showParticles)return;
  var w=cssW(),h=cssH(),atmosphere=S.atmosphere||deriveAtmosphericState(S.weather);
  var spd=S.props.animationSpeed*(0.65+atmosphere.motionEnergy*0.7),bk=S.weatherBucket;
  if(bk==='rain'||bk==='thunder'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      p.y+=p.speed*spd*dt;
      p.x-=1.2*spd*dt*60;
      if(p.y>h){p.y=-p.len;p.x=Math.random()*w;}
      if(p.x<-10)p.x=w+10;
    }
  }else if(bk==='snow'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      p.wb+=p.wbs*spd*dt;
      p.y+=p.speed*spd*dt;
      p.x+=Math.sin(p.wb)*0.4*spd;
      if(p.y>h){p.y=-p.sz;p.x=Math.random()*w;}
      if(p.x<-10)p.x=w+10;
      if(p.x>w+10)p.x=-10;
    }
  }else if(bk==='sleet'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      p.y+=p.speed*spd*dt;
      p.x-=(p.ice?0.6:1.3)*spd*dt*60;
      var bot=p.ice?h:h+(p.len||0);
      if(p.y>bot){p.y=p.ice?-p.sz:-p.len;p.x=Math.random()*w;}
      if(p.x<-10)p.x=w+10;
    }
  }else if(bk==='overcast'||bk==='partly'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      p.x+=p.speed*spd*dt;
      if(p.x>w+p.sz*2)p.x=-p.sz*2;
    }
  }
  for(var i=0;i<S.stars.length;i++){
    S.stars[i].tw+=S.stars[i].tws*spd*dt;
  }
  if(bk==='thunder'){
    S.lightningCooldown-=dt;
    if(S.lightningCooldown<=0&&Math.random()<0.03*spd){
      S.lightningAlpha=0.6+Math.random()*0.4;
      S.lightningCooldown=2+Math.random()*6;
    }
    S.lightningAlpha*=Math.pow(0.85,dt*60);
    if(S.lightningAlpha<0.005)S.lightningAlpha=0;
  }else{S.lightningAlpha=0;}
  if(bk==='fog'){
    if(S.fogAlpha<0.28)S.fogAlpha=Math.min(0.28,S.fogAlpha+0.004);
  }else{S.fogAlpha=0;}
}


// ── drawParticles() ──────────────────────────────────────────────────────────
// Renders all particles, stars, lightning flash, and fog overlay for the
// current frame. Each weather type uses a different drawing primitive:
// rain=strokeLine, snow=arc, sleet=mixed, cloud puffs=arc, stars=arc+twinkle.
// Lightning: full-canvas white fillRect at lightningAlpha opacity.
// Fog: full-canvas grey fillRect at fogAlpha opacity.
function drawParticles(ctx){
  if(!S.props.showParticles)return;
  var bk=S.weatherBucket;
  if(bk==='rain'||bk==='thunder'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      ctx.beginPath();
      ctx.moveTo(p.x,p.y);
      ctx.lineTo(p.x+1.2,p.y+p.len);
      ctx.strokeStyle=rgba([180,200,230],p.op);
      ctx.lineWidth=1;
      ctx.stroke();
    }
  }else if(bk==='snow'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      ctx.beginPath();
      ctx.arc(p.x,p.y,Math.max(0.5,p.sz),0,Math.PI*2);
      ctx.fillStyle=rgba([230,235,245],p.op);
      ctx.fill();
    }
  }else if(bk==='sleet'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      if(p.ice){
        ctx.beginPath();ctx.arc(p.x,p.y,Math.max(0.5,p.sz),0,Math.PI*2);
        ctx.fillStyle=rgba([215,228,242],p.op);ctx.fill();
      }else{
        ctx.beginPath();ctx.moveTo(p.x,p.y);ctx.lineTo(p.x+0.8,p.y+p.len);
        ctx.strokeStyle=rgba([180,205,228],p.op);ctx.lineWidth=1;ctx.stroke();
      }
    }
  }else if(bk==='overcast'||bk==='partly'){
    for(var i=0;i<S.particles.length;i++){
      var p=S.particles[i];
      ctx.beginPath();
      ctx.arc(p.x,p.y,Math.max(1,p.sz),0,Math.PI*2);
      ctx.fillStyle=rgba([200,210,220],p.op);
      ctx.fill();
    }
  }
  for(var i=0;i<S.stars.length;i++){
    var s=S.stars[i];
    var tw=0.25+0.75*Math.abs(Math.sin(s.tw));
    ctx.beginPath();
    ctx.arc(s.x,s.y,Math.max(0.3,s.sz),0,Math.PI*2);
    ctx.fillStyle=rgba([255,255,240],tw);
    ctx.fill();
  }
  if(S.lightningAlpha>0.005){
    ctx.fillStyle=rgba([255,255,255],S.lightningAlpha);
    ctx.fillRect(0,0,cssW(),cssH());
  }
  if(S.fogAlpha>0.005){
    ctx.fillStyle=rgba([180,185,195],S.fogAlpha);
    ctx.fillRect(0,0,cssW(),cssH());
  }
}


// ── getLunarPhase() ──────────────────────────────────────────────────────────
// Returns the current lunar phase as a value 0–1 (0 = new moon, 0.5 = full
// moon) using the Julian Day Number formula. Used by drawBgMoon() to render
// the correct crescent/gibbous phase rather than always drawing a full moon.
function getLunarPhase(){
  var JD=Date.now()/86400000+2440587.5;
  var age=(JD-2451549.5)%29.53058867;
  if(age<0)age+=29.53058867;
  return age/29.53058867; // 0=new, 0.5=full
}


// ── drawBgSun() / drawBgMoon() / drawBgCelestial() ──────────────────────────
// Render the large background sun or moon disc in the sky canvas. These are
// separate from the small card icons — they're the ambient light sources
// painted directly behind the city/sky gradient, not inside the UI card.
//
// drawBgSun: radial gradient disc + outer glow halo + slowly rotating rays.
// drawBgMoon: lunar phase using clip + overlapping arc technique (no images).
// drawBgCelestial: dispatcher — chooses sun or moon based on S.isDay,
//   and fades the body out for non-clear conditions (overcast hides the sun).
function drawBgSun(ctx,cx,cy,r,t){
  r=Math.max(4,r);
  // outer glow halo
  var og=ctx.createRadialGradient(cx,cy,r,cx,cy,r*4.5);
  og.addColorStop(0,'rgba(255,210,60,0.22)');
  og.addColorStop(0.55,'rgba(255,170,30,0.07)');
  og.addColorStop(1,'rgba(255,140,0,0)');
  ctx.fillStyle=og;ctx.beginPath();ctx.arc(cx,cy,r*4.5,0,Math.PI*2);ctx.fill();
  // slowly rotating rays
  ctx.save();ctx.translate(cx,cy);ctx.rotate(t*0.000055);
  ctx.lineCap='round';
  ctx.strokeStyle='rgba(255,220,80,0.30)';ctx.lineWidth=Math.max(1.5,r*0.14);
  for(var i=0;i<8;i++){var a=i*Math.PI/4;ctx.beginPath();ctx.moveTo(Math.cos(a)*r*1.55,Math.sin(a)*r*1.55);ctx.lineTo(Math.cos(a)*r*2.5,Math.sin(a)*r*2.5);ctx.stroke();}
  ctx.strokeStyle='rgba(255,210,70,0.14)';ctx.lineWidth=Math.max(1,r*0.09);
  for(var i=0;i<8;i++){var a=i*Math.PI/4+Math.PI/8;ctx.beginPath();ctx.moveTo(Math.cos(a)*r*1.8,Math.sin(a)*r*1.8);ctx.lineTo(Math.cos(a)*r*2.7,Math.sin(a)*r*2.7);ctx.stroke();}
  ctx.restore();
  // sun disk with radial gradient
  var sg=ctx.createRadialGradient(cx-r*0.25,cy-r*0.25,r*0.1,cx,cy,r);
  sg.addColorStop(0,'rgba(255,252,200,1)');
  sg.addColorStop(0.55,'rgba(255,215,55,1)');
  sg.addColorStop(1,'rgba(255,170,20,1)');
  ctx.fillStyle=sg;ctx.beginPath();ctx.arc(cx,cy,r,0,Math.PI*2);ctx.fill();
}

function drawBgMoon(ctx,cx,cy,r){
  r=Math.max(4,r);
  var phase=getLunarPhase(); // 0=new, 0.5=full
  // soft glow halo
  var grd=ctx.createRadialGradient(cx,cy,r*0.6,cx,cy,r*3.2);
  grd.addColorStop(0,'rgba(210,218,190,0.16)');
  grd.addColorStop(1,'rgba(180,190,160,0)');
  ctx.fillStyle=grd;ctx.beginPath();ctx.arc(cx,cy,r*3.2,0,Math.PI*2);ctx.fill();
  // clip to moon disc then draw phase
  ctx.save();
  ctx.beginPath();ctx.arc(cx,cy,r,0,Math.PI*2);ctx.clip();
  ctx.fillStyle='#0C0F1E';ctx.fillRect(cx-r,cy-r,r*2,r*2);
  if(phase>0.02&&phase<0.98){
    if(phase<=0.5){
      // waxing: lit on right
      ctx.fillStyle='#E4E6D2';
      ctx.beginPath();ctx.arc(cx,cy,r,-Math.PI/2,Math.PI/2);ctx.closePath();ctx.fill();
      var ex=Math.cos(phase*Math.PI*2)*r;
      if(ex>0.5){
        // crescent: dark ellipse over right side
        ctx.fillStyle='#0C0F1E';
        ctx.beginPath();ctx.ellipse(cx,cy,ex,r,0,-Math.PI/2,Math.PI/2);ctx.closePath();ctx.fill();
      }else if(ex<-0.5){
        // gibbous: add lit ellipse on left
        ctx.fillStyle='#E4E6D2';
        ctx.beginPath();ctx.ellipse(cx,cy,-ex,r,0,Math.PI/2,-Math.PI/2);ctx.closePath();ctx.fill();
      }
    }else{
      // waning: lit on left
      ctx.fillStyle='#E4E6D2';
      ctx.beginPath();ctx.arc(cx,cy,r,Math.PI/2,-Math.PI/2);ctx.closePath();ctx.fill();
      var ex=Math.cos(phase*Math.PI*2)*r;
      if(ex<-0.5){
        // gibbous: add lit ellipse on right
        ctx.fillStyle='#E4E6D2';
        ctx.beginPath();ctx.ellipse(cx,cy,-ex,r,0,-Math.PI/2,Math.PI/2);ctx.closePath();ctx.fill();
      }else if(ex>0.5){
        // crescent: dark ellipse over left side
        ctx.fillStyle='#0C0F1E';
        ctx.beginPath();ctx.ellipse(cx,cy,ex,r,0,Math.PI/2,-Math.PI/2);ctx.closePath();ctx.fill();
      }
    }
  }
  ctx.restore();
}

function drawBgCelestial(ctx,w,h,t){
  var atmosphere=S.atmosphere||deriveAtmosphericState(S.weather);
  var op=atmosphere.celestialVisibility;
  if(op===0)return;
  ctx.save();ctx.globalAlpha=op;
  var r=Math.min(w,h)*0.055;
  if(S.isDay)drawBgSun(ctx,w*0.72,h*0.20,r,t);
  else drawBgMoon(ctx,w*0.28,h*0.20,r*0.85);
  ctx.restore();
}


// ── setupVisibility() ────────────────────────────────────────────────────────
// Pauses the rAF loop when the page is hidden (e.g., display turned off or
// wallpaper covered by a full-screen app) and resumes it when visible again.
// This prevents unnecessary CPU/GPU usage when the wallpaper isn't visible.
// Uses the Page Visibility API (document.hidden / 'visibilitychange').
function setupVisibility(){
  document.addEventListener('visibilitychange',function(){
    if(document.hidden){
      if(S.animationFrameId){cancelAnimationFrame(S.animationFrameId);S.animationFrameId=null;}
    }else{
      if(!S.animationFrameId){S.lastFrameTime=0;S.animationFrameId=requestAnimationFrame(render);}
    }
  });
}

function resizeCanvas(){
  var dpr=window.devicePixelRatio||1;
  var w=window.innerWidth,h=window.innerHeight;
  S.canvas.width=w*dpr;S.canvas.height=h*dpr;
  S.canvas.style.width=w+'px';S.canvas.style.height=h+'px';
  S.ctx.setTransform(dpr,0,0,dpr,0,0);
  rebuildParticles();
}


// ── render() — main animation loop ───────────────────────────────────────────
// Called every frame via requestAnimationFrame. Computes elapsed time (dt),
// advances particle physics, and paints the sky gradient + particles to the
// canvas. Does NOT update the DOM UI — that happens only in applyWeather() /
// renderUI() when data changes. Separating data updates from frame rendering
// keeps the render loop lean and avoids DOM thrashing every 33ms.
function render(timestamp){
  if(!timestamp)timestamp=performance.now();
  var dt=S.lastFrameTime?Math.min((timestamp-S.lastFrameTime)/1000,0.1):0.016;
  S.lastFrameTime=timestamp;
  var w=cssW(),h=cssH(),ctx=S.ctx;
  var colors=getPhaseColors();
  var grad=ctx.createLinearGradient(0,0,0,h);
  grad.addColorStop(0,rgb(colors.top));
  grad.addColorStop(0.5,rgb(colors.mid));
  grad.addColorStop(1,rgb(colors.bot));
  ctx.fillStyle=grad;
  ctx.fillRect(0,0,w,h);
  drawBgCelestial(ctx,w,h,timestamp);
  updateParticles(dt);
  drawParticles(ctx);
  if(!document.hidden){
    S.animationFrameId=requestAnimationFrame(render);
  }
}
