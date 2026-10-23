// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stephen de la Vega
// See ../LICENSE.txt for the MIT license.
'use strict';

const cityProperties = {
  timeMode: 'live', weatherMode: 'drifting', renderer: 'auto',
  rainIntensity: 60, fogDensity: 30, neonBrightness: 100, vehicleCount: 8,
  locationMode: 'auto', manualLocation: ''
};
const cityChoices = {
  timeMode: ['live', 'night'], weatherMode: ['drifting', 'live', 'fixed'],
  renderer: ['auto', 'classic'], locationMode: ['auto', 'manual']
};
const citySliderBounds = {
  rainIntensity: [0, 120], fogDensity: [0, 100],
  neonBrightness: [20, 120], vehicleCount: [0, 20]
};
const cityWeatherSeed = (Math.imul(screen.width, 9301) + Math.imul(screen.height, 49297)) >>> 0;
let cityLiveWeather = null;

function refreshCityState() {
  const state = deriveCityState({ now: new Date(), timeMode: cityProperties.timeMode,
    weatherMode: cityProperties.weatherMode,
    fixed: { rain: cityProperties.rainIntensity, fog: cityProperties.fogDensity },
    live: cityLiveWeather, seed: cityWeatherSeed });
  // Classic is the available renderer in this first v3 task; Auto uses it too.
  window.ClassicCityRenderer.applyState(state, cityProperties);
  return state;
}

function livelyPropertyListener(name, val) {
  if (!Object.prototype.hasOwnProperty.call(cityProperties, name)) return;
  if (cityChoices[name]) {
    const choices = cityChoices[name];
    const text = String(val).toLowerCase();
    const value = choices.includes(text) ? text : choices[Number(val)];
    cityProperties[name] = name === 'timeMode' && text === 'always night' ? 'night' :
      value ?? cityProperties[name];
  } else if (citySliderBounds[name]) {
    const number = Number(val);
    if (!Number.isFinite(number)) return;
    const [min, max] = citySliderBounds[name];
    cityProperties[name] = Math.max(min, Math.min(max, number));
  } else {
    cityProperties[name] = String(val);
  }
  refreshCityState();
}

// Weather acquisition is supplied by the later Live-weather integration.
// Missing Live data follows the same deterministic Drifting schedule.
window.setCityLiveWeather = function(weather) {
  cityLiveWeather = weather;
  refreshCityState();
};
window.ClassicCityRenderer.start(refreshCityState(), cityProperties);
setInterval(refreshCityState, 1000);
