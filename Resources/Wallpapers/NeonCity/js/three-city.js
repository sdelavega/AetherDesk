// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stephen de la Vega
// See ../LICENSE.txt for the MIT license.
'use strict';

function qualityTier(system) {
  const saver = system.qualityMode === 'eco' || system.isLowPowerMode || system.onBattery;
  return saver ? { fps: 15, renderScale: 0.5, countScale: 0.4, eventScale: 0.5 } :
    { fps: 30, renderScale: 0.75, countScale: 1, eventScale: 1 };
}

function adaptRenderScale(current, p95FrameMs, msUnderBudget) {
  if (p95FrameMs > 20) return current > 0.6 ? 0.6 : 0.5;
  if (p95FrameMs < 12 && msUnderBudget >= 60000) return current < 0.6 ? 0.6 : 0.75;
  return current;
}

function cityRandom(seed) {
  return function() {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 4294967296;
  };
}

function buildCity(seed) {
  const random = cityRandom(seed), range = (a, b) => a + (b - a) * random();
  const towers = [];
  const add = (band, x, z, w, h, d) => towers.push({ band, x, z, w, h, d });
  for (let i = 0; i < 22; i++) add('near', (i % 2 ? 1 : -1) * range(43, 92),
    range(-270, 95), range(18, 31), range(90, 210), range(21, 40));
  for (let i = 0; i < 175; i++) {
    let x = range(-270, 270);
    if (Math.abs(x) < 30) x += x < 0 ? -40 : 40;
    add('mid', x, range(-670, -120), range(10, 25), range(27, 145), range(12, 28));
  }
  for (let i = 0; i < 100; i++) add('far', range(-600, 600), range(-1100, -650),
    range(14, 37), range(40, 180), range(15, 35));
  return { seed: seed >>> 0, towers };
}

const CITY_PALETTES = {
  night: { sky: '#02050e', horizon: '#102342', fog: '#071122', light: '#89b8dd', ambient: 0.8 },
  dawn: { sky: '#092347', horizon: '#eaa259', fog: '#6d5039', light: '#f5b982', ambient: 1.4 },
  day: { sky: '#334b65', horizon: '#889897', fog: '#566c7c', light: '#c0d6df', ambient: 2.5 },
  dusk: { sky: '#07182f', horizon: '#d57c38', fog: '#67442d', light: '#eea073', ambient: 1.2 }
};
let threeCity = null;

function initializeThreeCity(canvas, model) {
  const THREE = window.NeonCityThree;
  if (!THREE || !canvas) return false;
  let renderer, scene;
  canvas.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    demoteRenderer('three', 'WebGL context lost');
  });
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'low-power', precision: 'highp' });
    renderer.debug.onShaderError = () => demoteRenderer('three', 'Shader compilation failed');
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.05;
    scene = new THREE.Scene();
    scene.background = new THREE.Color(CITY_PALETTES.night.sky);
    scene.fog = new THREE.FogExp2(CITY_PALETTES.night.fog, 0.0034);
    const camera = new THREE.PerspectiveCamera(57, 1, 0.5, 1800);
    const ambient = new THREE.HemisphereLight('#668ab3', '#08121f', 0.8);
    const rim = new THREE.DirectionalLight('#89b8dd', 1.4);
    rim.position.set(-130, 260, 140);
    scene.add(ambient, rim);
    const uniforms = { uLit: { value: 0.23 }, uNeon: { value: 0.85 } };
    const towerMaterial = new THREE.MeshStandardMaterial({ color: '#182b40', roughness: 0.86, metalness: 0.25 });
    towerMaterial.onBeforeCompile = shader => {
      Object.assign(shader.uniforms, uniforms);
      shader.vertexShader = 'varying vec3 vFace; varying vec3 vLocal; varying vec3 vSize; varying float vSeed;\n' + shader.vertexShader;
      shader.vertexShader = shader.vertexShader.replace('#include <begin_vertex>', `#include <begin_vertex>
        vFace=normal; vLocal=position;
        vSize=vec3(length(instanceMatrix[0].xyz),length(instanceMatrix[1].xyz),length(instanceMatrix[2].xyz));
        vSeed=instanceMatrix[3].x+instanceMatrix[3].z;`);
      shader.fragmentShader = `uniform float uLit; uniform float uNeon;
        varying vec3 vFace; varying vec3 vLocal; varying vec3 vSize; varying float vSeed;
        float cityHash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
        ` + shader.fragmentShader;
      shader.fragmentShader = shader.fragmentShader.replace('#include <emissivemap_fragment>', `#include <emissivemap_fragment>
        vec2 surface=abs(vFace.z)>.5 ? vLocal.xy*vSize.xy : vec2(vLocal.z*vSize.z,vLocal.y*vSize.y);
        vec2 grid=surface/vec2(2.1,3.4),cell=floor(grid),f=fract(grid);
        float h=cityHash(cell+vSeed),suite=cityHash(vec2(floor(cell.x/3.),cell.y)+vSeed);
        float on=step(h,uLit*.48+suite*uLit*.9)*step(.19,suite);
        float width=mix(.32,.76,cityHash(cell+vSeed+8.));
        float mask=step(.16,f.x)*step(f.x,width)*step(.28,f.y)*step(f.y,.72);
        vec3 light=mix(vec3(1.,.43,.12),vec3(1.,.79,.50),step(.40,h));
        light=mix(light,vec3(.23,.57,1.),step(.93,cityHash(cell+vSeed+15.)));
        float facade=1.-step(.8,abs(vFace.y));
        totalEmissiveRadiance+=light*mask*on*facade*(.65+uNeon*1.25)*mix(.35,1.2,suite);
        // Broad edge illumination keeps masonry legible between sparse windows.
        float edge=pow(abs(dot(normalize(vNormal),normalize(vec3(.7,.25,1.)))),3.);
        totalEmissiveRadiance+=vec3(.017,.035,.065)*(.3+edge)*facade;`);
    };
    const box = new THREE.BoxGeometry(1, 1, 1), plane = new THREE.PlaneGeometry(1, 1);
    const dummy = new THREE.Object3D();
    function instance(mesh, index, x, y, z, w, h, d) {
      dummy.position.set(x, y, z); dummy.scale.set(w, h, d); dummy.rotation.set(0, 0, 0);
      dummy.updateMatrix(); mesh.setMatrixAt(index, dummy.matrix);
    }
    for (const band of ['near', 'mid', 'far']) {
      const towers = model.towers.filter(tower => tower.band === band);
      const mesh = new THREE.InstancedMesh(box, towerMaterial, towers.length);
      towers.forEach((b, i) => instance(mesh, i, b.x, b.h / 2, b.z, b.w, b.h, b.d));
      scene.add(mesh);
    }
    const random = cityRandom(model.seed ^ 0x4e454f4e), range = (a, b) => a + (b - a) * random();
    const softCanvas = document.createElement('canvas'); softCanvas.width = softCanvas.height = 64;
    const softContext = softCanvas.getContext('2d');
    const gradient = softContext.createRadialGradient(32, 32, 0, 32, 32, 32);
    for (const [at, alpha] of [[0, 1], [.18, .65], [.5, .15], [1, 0]]) gradient.addColorStop(at, `rgba(255,255,255,${alpha})`);
    softContext.fillStyle = gradient; softContext.fillRect(0, 0, 64, 64);
    const soft = new THREE.CanvasTexture(softCanvas), neonColors = ['#ff168a', '#00eaff', '#ff9e24', '#ac4dff'];
    const signMaterials = [], halos = [], signGroups = Array.from({ length: 8 }, () => []);
    model.towers.forEach((b, i) => {
      if (b.band === 'far' || (b.band === 'mid' && i % 3)) return;
      const count = b.band === 'near' ? 4 : 1;
      for (let j = 0; j < count; j++) {
        const vertical = j % 3 !== 2;
        signGroups[(vertical ? 0 : 4) + i % 4].push({
          x: b.x + (vertical ? (j % 2 ? 1 : -1) * b.w * .35 : 0),
          y: Math.min(b.h - 15, b.h * (.22 + j * .17)), z: b.z + b.d / 2 + .5,
          w: vertical ? range(2.8, 5.5) : b.w * .94, h: vertical ? range(14, 32) : 4.5,
          color: neonColors[(i + j) % 4], glow: j === 0
        });
      }
    });
    // Tube art is generated locally; deliberate strokes need no language font.
    for (let variant = 0; variant < signGroups.length; variant++) {
      const vertical = variant < 4, art = document.createElement('canvas');
      art.width = vertical ? 128 : 512; art.height = vertical ? 512 : 128;
      const ctx = art.getContext('2d');
      ctx.strokeStyle = ctx.fillStyle = '#fff'; ctx.lineWidth = 4;
      ctx.shadowColor = '#fff'; ctx.shadowBlur = 5;
      ctx.strokeRect(7, 7, art.width - 14, art.height - 14);
      if (vertical) {
        for (let n = 0; n < 4; n++) {
          ctx.save(); ctx.translate(24, 35 + n * 112); ctx.lineWidth = 6; ctx.beginPath();
          ctx.moveTo(4, 16); ctx.lineTo(76, 16); ctx.moveTo(40, 0); ctx.lineTo(40, 82);
          ctx.moveTo(9, 45); ctx.lineTo(72, 45); ctx.moveTo(12, 78); ctx.lineTo(34, 56);
          ctx.moveTo(48, 56); ctx.lineTo(73, 80);
          if ((variant + n) % 2) { ctx.moveTo(13, 27); ctx.lineTo(13, 64); ctx.lineTo(68, 64); ctx.lineTo(68, 27); }
          ctx.stroke(); ctx.restore();
        }
      } else {
        ctx.font = '600 68px monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText(['HOTEL', 'NEON', '24 : 00', 'MARKET'][variant % 4], 256, 66);
      }
      const texture = new THREE.CanvasTexture(art); texture.colorSpace = THREE.SRGBColorSpace;
      const material = new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthWrite: false, toneMapped: false });
      const signs = signGroups[variant], mesh = new THREE.InstancedMesh(plane, material, signs.length);
      const backing = new THREE.InstancedMesh(plane, new THREE.MeshBasicMaterial({ color: '#070c17' }), signs.length);
      signMaterials.push(material);
      signs.forEach((s, i) => {
        instance(mesh, i, s.x, s.y, s.z, s.w, s.h, 1);
        mesh.setColorAt(i, new THREE.Color(s.color));
        instance(backing, i, s.x, s.y, s.z - .1, s.w * 1.07, s.h * 1.04, 1);
        if (s.glow) {
          const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: soft, color: s.color, transparent: true,
            opacity: .3, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
          halo.position.set(s.x, s.y, s.z + .15); halo.scale.set(s.w * 5, s.h * 2.2, 1);
          scene.add(halo); halos.push(halo);
        }
      });
      scene.add(backing, mesh);
    }
    // Facade-aligned glow pools stay in front of the masonry while depth
    // testing still hides them behind closer towers. All pools share one draw.
    const pools = signGroups.flat();
    const poolMaterial = new THREE.MeshBasicMaterial({ map: soft, transparent: true, opacity: .1,
      blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false });
    const poolMesh = new THREE.InstancedMesh(plane, poolMaterial, pools.length);
    pools.forEach((s, i) => {
      instance(poolMesh, i, s.x, s.y, s.z + .3, Math.max(s.w * 9, 24), s.h * 2.8, 1);
      poolMesh.setColorAt(i, new THREE.Color(s.color));
    });
    scene.add(poolMesh); signMaterials.push(poolMaterial);
    const crowns = model.towers.filter((b, i) => b.band !== 'far' && i % 3 === 0);
    const edges = new THREE.InstancedMesh(plane, new THREE.MeshBasicMaterial({ toneMapped: false }), crowns.length * 3);
    crowns.forEach((b, i) => {
      const pieces = [[b.x, b.h - 1, b.w, .3], [b.x - b.w / 2 + .2, b.h * .61, .25, b.h * .74],
        [b.x + b.w / 2 - .2, b.h * .77, .22, b.h * .43]];
      pieces.forEach(([x, y, w, h], j) => {
        instance(edges, i * 3 + j, x, y, b.z + b.d / 2 + .6, w, h, 1);
        edges.setColorAt(i * 3 + j, new THREE.Color(neonColors[i % 4]));
      });
    });
    scene.add(edges); signMaterials.push(edges.material);
    const street = new THREE.Mesh(new THREE.PlaneGeometry(950, 1600),
      new THREE.MeshStandardMaterial({ color: '#07131d', roughness: .22, metalness: .75 }));
    street.rotation.x = -Math.PI / 2; street.position.set(0, -1, -420); scene.add(street);
    const reflectionMaterial = new THREE.MeshBasicMaterial({ transparent: true, opacity: .12, depthWrite: false });
    const reflections = new THREE.InstancedMesh(plane, reflectionMaterial, 32);
    for (let i = 0; i < 32; i++) {
      dummy.position.set(range(-31, 31), -.8, range(-450, 150));
      dummy.scale.set(range(.25, 1.8), range(20, 65), 1); dummy.rotation.set(-Math.PI / 2, 0, 0);
      dummy.updateMatrix(); reflections.setMatrixAt(i, dummy.matrix); reflections.setColorAt(i, new THREE.Color(neonColors[i % 4]));
    }
    scene.add(reflections);
    const skyUniforms = { zenith: { value: new THREE.Color('#02050e') }, horizon: { value: new THREE.Color('#102342') }, uTime: { value: 0 } };
    const sky = new THREE.Mesh(new THREE.SphereGeometry(1400, 24, 16), new THREE.ShaderMaterial({
      precision: 'highp', side: THREE.BackSide, depthWrite: false, uniforms: skyUniforms,
      vertexShader: 'varying vec3 direction; void main(){direction=position;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}',
      fragmentShader: `uniform vec3 zenith; uniform vec3 horizon; uniform float uTime; varying vec3 direction;
        void main(){vec3 d=normalize(direction);float gradient=pow(smoothstep(-.015,.34,d.y),.65);
        float layer=sin(d.y*62.+sin(d.x*7.+uTime*.012)*.65)*sin(d.x*11.+d.z*5.);
        vec3 col=mix(horizon,zenith,gradient)+horizon*layer*.10*exp(-max(0.,d.y)*7.);
        gl_FragColor=vec4(col,1.);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
        }`
    })); scene.add(sky);
    const particleCount = 2400, particleData = [];
    for (let i = 0; i < particleCount; i++) particleData.push({ x: range(-105, 105), y: range(-52, 110),
      z: range(-170, -3), speed: range(.7, 1.4), phase: range(0, Math.PI * 2) });
    const rainGeometry = new THREE.BufferGeometry();
    rainGeometry.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(particleCount * 6), 3));
    const rain = new THREE.LineSegments(rainGeometry, new THREE.LineBasicMaterial({ color: '#a6c5e4',
      transparent: true, opacity: .38, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false }));
    rain.frustumCulled = false; scene.add(rain);
    const snowGeometry = new THREE.BufferGeometry();
    snowGeometry.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(particleCount * 3), 3));
    snowGeometry.setAttribute('flakeSize', new THREE.Float32BufferAttribute(particleData.map(() => range(.24, .7)), 1));
    const snowMaterial = new THREE.ShaderMaterial({ precision: 'highp', transparent: true, depthWrite: false,
      uniforms: { uPixelRatio: { value: 1 } },
      vertexShader: `attribute float flakeSize; uniform float uPixelRatio;
        void main(){vec4 mv=modelViewMatrix*vec4(position,1.);gl_Position=projectionMatrix*mv;
        gl_PointSize=clamp(flakeSize*460.*uPixelRatio/-mv.z,2.,15.);}`,
      fragmentShader: `void main(){float r=length(gl_PointCoord-.5)*2.;if(r>1.)discard;
        gl_FragColor=vec4(.82,.9,1.,(1.-smoothstep(.18,1.,r))*.9);
        #include <colorspace_fragment>
        }`
    });
    const snow = new THREE.Points(snowGeometry, snowMaterial); snow.frustumCulled = false; scene.add(snow);
    const cameraPath = new THREE.CatmullRomCurve3([
      new THREE.Vector3(0, 44, 159), new THREE.Vector3(7, 46, 135),
      new THREE.Vector3(0, 43, 111), new THREE.Vector3(-7, 40, 135)
    ], true, 'catmullrom', .5);
    threeCity = { renderer, scene, camera, cameraPath, ambient, rim, uniforms, sky, skyUniforms, signMaterials, halos,
      reflectionMaterial, particleData, rain, snow, snowMaterial, lastTime: null, width: 0, height: 0, scale: 0,
      backgroundTarget: new THREE.Color(), horizonTarget: new THREE.Color(), fogTarget: new THREE.Color(), lightTarget: new THREE.Color() };
    return true;
  } catch (error) {
    disposeCityResources(scene, renderer);
    threeCity = null;
    return false;
  }
}

function disposeCityResources(scene, renderer) {
  const resources = new Set();
  if (scene) scene.traverse(object => {
    if (object.geometry) resources.add(object.geometry);
    for (const material of object.material ? [object.material].flat() : []) {
      for (const value of Object.values(material)) if (value && value.isTexture) resources.add(value);
      resources.add(material);
    }
  });
  for (const resource of resources) resource.dispose();
  if (renderer) renderer.dispose();
}

function disposeThreeCity() {
  if (!threeCity) return;
  disposeCityResources(threeCity.scene, threeCity.renderer);
  threeCity = null;
}

function renderThreeCity(t, cityState) {
  if (!threeCity) throw new Error('Three city is unavailable');
  const c = threeCity, state = cityState, tier = window.NeonCityStatus.tier;
  const scale = window.NeonCityStatus.renderScale;
  const width = Math.max(1, window.innerWidth), height = Math.max(1, window.innerHeight);
  if (c.width !== width || c.height !== height || c.scale !== scale) {
    c.width = width; c.height = height; c.scale = scale;
    c.renderer.setPixelRatio((window.devicePixelRatio || 1) * scale);
    c.renderer.setSize(width, height, false);
    c.camera.aspect = width / height; c.camera.updateProjectionMatrix();
    c.snowMaterial.uniforms.uPixelRatio.value = c.renderer.getPixelRatio();
  }
  const dt = c.lastTime === null ? 1 / tier.fps : Math.min((t - c.lastTime) / 1000, .1);
  c.lastTime = t;
  const palette = CITY_PALETTES[state.phase] || CITY_PALETTES.night;
  const a = 1 - Math.exp(-dt * 1.8);
  c.backgroundTarget.set(palette.sky); c.horizonTarget.set(palette.horizon); c.fogTarget.set(palette.fog);
  if (state.weather === 'snow') c.fogTarget.lerp(c.lightTarget.set('#526779'), .22);
  c.scene.background.lerp(c.backgroundTarget, a); c.scene.fog.color.lerp(c.fogTarget, a);
  c.skyUniforms.zenith.value.lerp(c.backgroundTarget, a); c.skyUniforms.horizon.value.lerp(c.horizonTarget, a);
  c.skyUniforms.uTime.value = t / 1000;
  c.scene.fog.density += (.0024 + state.fog * .0105 - c.scene.fog.density) * a;
  c.rim.color.lerp(c.lightTarget.set(palette.light), a);
  c.ambient.intensity += (palette.ambient - c.ambient.intensity) * a;
  c.uniforms.uLit.value += (state.windowsLit * .44 - c.uniforms.uLit.value) * a;
  const energy = state.neon * (window.NeonCityStatus.neonBrightness || 100) / 100;
  c.uniforms.uNeon.value += (energy - c.uniforms.uNeon.value) * a;
  c.signMaterials.forEach(material => material.color.setScalar(c.uniforms.uNeon.value * 3.6 + .025));
  c.halos.forEach(halo => { halo.material.opacity = c.uniforms.uNeon.value * .3; });
  c.reflectionMaterial.opacity = (state.rain > 0 ? .15 : .035) * c.uniforms.uNeon.value;
  // A closed ten-minute path, evaluated from absolute time so throttling cannot accelerate it.
  const cycle = (t % 600000) / 600000;
  c.camera.position.copy(c.cameraPath.getPointAt(cycle));
  c.camera.lookAt(Math.sin(cycle * Math.PI * 2 + .6) * 9, 64 + Math.sin(cycle * Math.PI * 2) * 3, -350);
  c.sky.position.copy(c.camera.position);
  const snowy = state.weather === 'snow';
  const amount = Math.round((snowy ? 1500 : state.rain * 2400) * tier.countScale);
  c.rain.visible = !snowy && amount > 0; c.snow.visible = snowy;
  c.rain.geometry.setDrawRange(0, amount * 2); c.snow.geometry.setDrawRange(0, amount);
  const positions = (snowy ? c.snow : c.rain).geometry.attributes.position;
  for (let i = 0; i < amount; i++) {
    const p = c.particleData[i];
    p.y -= dt * (snowy ? 3.4 : state.weather === 'downpour' ? 95 : 65) * p.speed;
    if (p.y < -52) p.y += 162;
    const x = p.x + c.camera.position.x + (snowy ? Math.sin(t * .0006 + p.phase) * 2.5 : 0);
    const y = p.y + c.camera.position.y, z = p.z + c.camera.position.z;
    const j = i * (snowy ? 3 : 6);
    positions.array[j] = x; positions.array[j + 1] = y; positions.array[j + 2] = z;
    if (!snowy) {
      positions.array[j + 3] = x - .25;
      positions.array[j + 4] = y + (state.weather === 'drizzle' ? 1.1 : state.weather === 'downpour' ? 3.4 : 2.3);
      positions.array[j + 5] = z;
    }
  }
  if (amount) positions.needsUpdate = true;
  c.renderer.render(c.scene, c.camera);
}
