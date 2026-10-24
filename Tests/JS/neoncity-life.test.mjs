// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = new URL('../../Resources/Wallpapers/NeonCity/', import.meta.url);
const night = { phase: 'night', trafficDensity: 1, neon: 1 };
function runtime(seed = 7319) {
  const context = vm.createContext({}); context.window = context;
  for (const file of ['city-state.js', 'three-city.js', 'city-life.js']) {
    vm.runInContext(readFileSync(new URL(`js/${file}`, root), 'utf8'), context);
  }
  context.NeonCityStatus = { tier: context.qualityTier({}) };
  return { context, life: context.createLife(seed, context.buildCity(seed)) };
}

test('life is reproducible, seeded, and exposes ground and elevated lanes', () => {
  const a = runtime(), b = runtime(), c = runtime(7320);
  for (let i = 0; i < 90; i++) { a.life.update(.5, night); b.life.update(.5, night); c.life.update(.5, night); }
  assert.equal(JSON.stringify(a.life), JSON.stringify(b.life));
  assert.notEqual(JSON.stringify(a.life.vehicles), JSON.stringify(c.life.vehicles));
  assert.ok(a.life.lanes.some(lane => lane.y < 2));
  assert.ok(a.life.lanes.some(lane => lane.y > 20));
});

test('vehicle count follows rounded traffic density and live quality countScale', () => {
  const { life, context } = runtime();
  for (const density of [0, .01, .27, .55, .99, 1]) {
    life.update(0, { ...night, trafficDensity: density });
    assert.equal(life.vehicles.length, Math.round(density * 20));
  }
  context.NeonCityStatus.tier = context.qualityTier({ onBattery: true });
  life.update(0, night); assert.equal(life.vehicles.length, 8);
  context.NeonCityStatus.tier = context.qualityTier({});
  life.update(0, night); assert.equal(life.vehicles.length, 20);
});

test('missing quality tier uses normal life counts', () => {
  const { life, context } = runtime();
  context.NeonCityStatus = {};
  life.update(0, night);
  assert.equal(life.vehicles.length, 20);
});

test('shared sign sites enumerate eligible towers in stable order', () => {
  const { context } = runtime();
  const model = { towers: ['far', 'near', 'mid', 'mid', 'near', 'far'].map(band => ({ band })) };
  const sites = context.signSites(model);
  assert.deepEqual(Array.from(sites, site => [site.towerIndex, site.signIndex]),
    [[1, 0], [1, 1], [1, 2], [1, 3], [3, 0], [4, 0], [4, 1], [4, 2], [4, 3]]);
});

test('individual speeds stay within ±30% of lane speed and ease at lane ends', () => {
  const { life } = runtime(); life.update(0, night);
  const speeds = new Set();
  for (const vehicle of life.vehicles) {
    const speed = life.lanes[vehicle.lane].speed;
    assert.ok(vehicle.speed >= speed * .7 && vehicle.speed <= speed * 1.3);
    speeds.add(vehicle.speed / speed);
  }
  assert.ok(speeds.size > 10);
  const vehicle = life.vehicles[0];
  vehicle.phase = 0; life.update(0, night); const start = vehicle.t;
  life.update(.01, night); const atEnd = vehicle.t - start;
  vehicle.phase = .5; life.update(0, night); const middle = vehicle.t;
  life.update(.01, night); const atMiddle = vehicle.t - middle;
  assert.ok(atMiddle > atEnd * 3, `${atMiddle} versus ${atEnd}`);
  for (let i = 0; i < 10000; i++) life.update(.1, night);
  assert.ok(life.vehicles.every(v => v.t >= 0 && v.t < 1));
});

test('2–5% of tubes remain dead while other signs flicker and recover', () => {
  for (const seed of [1, 7319, 99999]) {
    const { life } = runtime(seed);
    const dead = life.signs.filter(sign => sign.dead);
    assert.ok(dead.length / life.signs.length >= .02 && dead.length / life.signs.length <= .05);
    const dark = new Set(), recovered = new Set();
    for (let i = 0; i < 3000; i++) {
      life.update(.02, night);
      for (let j = 0; j < life.signs.length; j++) {
        const sign = life.signs[j];
        if (sign.dead) assert.equal(sign.on, false);
        else if (!sign.on) dark.add(j);
        else if (dark.has(j)) recovered.add(j);
      }
    }
    assert.ok(recovered.size > 0);
    assert.ok(recovered.size < life.signs.length / 4, 'restrained flicker');
  }
});

test('pooled events include sweeps, rooftop steam and blimps with 15-minute separation', () => {
  const { life } = runtime(); const starts = [];
  const events = Array.from(life.events), vehicles = Array.from(life.vehicles), signs = Array.from(life.signs);
  const seen = new Set(); let previous = -1;
  for (let second = 0; second < 7200; second++) {
    life.update(1, night);
    for (const event of life.events) if (event.active) seen.add(event.type);
    const blimp = life.events.find(event => event.type === 'blimp');
    if (blimp.starts !== previous) { if (blimp.starts) starts.push(blimp.lastStart); previous = blimp.starts; }
  }
  assert.deepEqual([...seen].sort(), ['blimp', 'searchlight', 'steam']);
  assert.ok(starts.length >= 2);
  for (let i = 1; i < starts.length; i++) assert.ok(starts[i] - starts[i - 1] >= 900);
  assert.ok(events.every((event, i) => event === life.events[i]));
  assert.ok(vehicles.every((vehicle, i) => vehicle === life.vehicles[i]));
  assert.ok(signs.every((sign, i) => sign === life.signs[i]));
});

test('saver eventScale halves event frequency; daytime reduces traffic, glow, speed and events', () => {
  const normal = runtime(), saver = runtime(), day = runtime();
  saver.context.NeonCityStatus.tier = saver.context.qualityTier({ qualityMode: 'eco' });
  const daytime = { phase: 'day', trafficDensity: .55, neon: .35 };
  for (let i = 0; i < 7200; i++) {
    normal.life.update(1, night); saver.life.update(1, night); day.life.update(1, daytime);
  }
  const starts = life => life.events.filter(e => e.type === 'steam' || e.type === 'searchlight').reduce((n, e) => n + e.starts, 0);
  const ratio = starts(saver.life) / starts(normal.life);
  assert.ok(ratio > .47 && ratio < .53, `saver ratio ${ratio}`);
  assert.ok(starts(day.life) < starts(normal.life) * .3);
  assert.equal(day.life.vehicles.length, 11);
  assert.ok(day.life.brightness < normal.life.brightness);
  assert.ok(day.life.motionScale < normal.life.motionScale);
});

test('production scene moves pooled instances, switches live counts and extinguishes dead sign glow', () => {
  const gradient = { addColorStop() {} };
  const drawing = new Proxy({}, { get(target, key) {
    if (key in target) return target[key];
    if (key === 'createRadialGradient') return () => gradient;
    return () => {};
  } });
  const canvas = () => ({ getContext: () => drawing, addEventListener() {} });
  const context = vm.createContext({ innerWidth: 1280, innerHeight: 720, document: { createElement: canvas } });
  context.window = context;
  for (const file of ['vendor/three-city.min.js', 'js/city-state.js', 'js/city-life.js', 'js/three-city.js']) {
    vm.runInContext(readFileSync(new URL(file, root), 'utf8'), context);
  }
  let rendered = 0;
  context.NeonCityThree = { ...context.NeonCityThree, WebGLRenderer: class {
    constructor() { this.debug = {}; }
    setPixelRatio(value) { this.ratio = value; } getPixelRatio() { return this.ratio; }
    setSize() {} render() { rendered++; } dispose() {}
  } };
  context.canvas = canvas();
  vm.runInContext(`window.NeonCityStatus = {tier:qualityTier({}),renderScale:.75,neonBrightness:100};
    if(!initializeThreeCity(canvas, buildCity(7319))) throw Error('scene initialization failed');`, context);
  const city = vm.runInContext('threeCity', context);
  const sceneSigns = Array.from(city.signBatches).flatMap(batch => Array.from(batch.signs));
  assert.equal(city.life.signs.length, city.signBatches.reduce((n, batch) => n + batch.mesh.count, 0));
  assert.deepEqual(sceneSigns.map(sign => sign.lifeIndex).sort((a, b) => a - b),
    Array.from({ length: city.life.signs.length }, (_, i) => i));
  const sites = context.signSites(context.buildCity(7319));
  for (const sign of sceneSigns) {
    const site = sites[sign.lifeIndex], lifeSign = city.life.signs[sign.lifeIndex];
    assert.equal(sign.towerIndex, site.towerIndex);
    assert.equal(sign.signIndex, site.signIndex);
    assert.equal(lifeSign.towerIndex, site.towerIndex);
    assert.equal(lifeSign.signIndex, site.signIndex);
  }
  const state = { ...night, weather: 'clear', rain: 0, fog: .08, windowsLit: .5 };
  const draw = t => context.renderThreeCity(t, state);
  draw(0);
  assert.equal(city.lifeView.body.count, 20); assert.equal(city.lifeView.lamps.count, 80);
  assert.ok(city.lifeView.streams.count > 0);
  const positions = city.lifeView.body.instanceMatrix.array;
  const initial = Array.from(positions);
  const resources = [city.scene.children.length, city.lifeView.body.geometry, city.lifeView.body.material, positions];
  for (let i = 1; i <= 90; i++) draw(i * 34);
  assert.notDeepEqual(Array.from(positions), initial);
  assert.equal(city.scene.children.length, resources[0]);
  assert.equal(city.lifeView.body.geometry, resources[1]);
  assert.equal(city.lifeView.body.material, resources[2]);
  assert.equal(city.lifeView.body.instanceMatrix.array, resources[3]);
  assert.ok(city.lifeView.beam.visible && city.lifeView.blimp.visible && city.lifeView.steam.count > 0);
  for (let i = 0; i < city.pools.length; i++) if (city.life.signs[city.pools[i].lifeIndex].dead) {
    assert.equal(city.poolMesh.instanceColor.array[i * 3], 0);
    assert.equal(city.poolMesh.instanceColor.array[i * 3 + 1], 0);
    assert.equal(city.poolMesh.instanceColor.array[i * 3 + 2], 0);
  }
  for (const halo of city.halos) if (city.life.signs[halo.lifeIndex].dead) assert.equal(halo.material.opacity, 0);
  context.NeonCityStatus.tier = context.qualityTier({ onBattery: true }); draw(4000);
  assert.equal(city.lifeView.body.count, 8); assert.equal(city.lifeView.lamps.count, 32);
  state.trafficDensity = 0; draw(4100);
  assert.equal(city.lifeView.body.count, 0); assert.equal(city.lifeView.streams.count, 0);
  assert.ok(rendered > 90);
});

test('large elapsed steps and tier changes never bunch blimp passes', () => {
  const { life, context } = runtime();
  life.update(0, night);
  let last = life.events.find(e => e.type === 'blimp').lastStart;
  for (let i = 0; i < 12; i++) {
    context.NeonCityStatus.tier = context.qualityTier({ onBattery: i % 2 === 0 });
    life.update(1000, night);
    const blimp = life.events.find(e => e.type === 'blimp');
    if (blimp.lastStart !== last) { assert.ok(blimp.lastStart - last >= 900); last = blimp.lastStart; }
  }
});
