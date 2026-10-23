#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail
cd "$(dirname "$0")/.."
measurement_dir=build/weather-perf
if [[ $# -eq 2 && "$1" == --evaluate ]]; then
    measurement_dir=$2
elif [[ $# -eq 0 ]]; then
    mkdir -p "$measurement_dir"
    # Remove stale artifacts first; a failed harness must never reuse a PASS.
    rm -f build/weather-perf.md "$measurement_dir/auto.json" "$measurement_dir/classic.json" "$measurement_dir/soak.json"
    Tools/WeatherPerf/build.sh
    for renderer in classic auto; do
        /usr/bin/caffeinate -di build/WeatherPerf --renderer "$renderer" --seconds 30 \
            --out "$measurement_dir/$renderer.json" | tee "$measurement_dir/$renderer.log"
    done
    /usr/bin/caffeinate -di build/WeatherPerf --renderer auto --soak 600 \
        --out "$measurement_dir/soak.json" | tee "$measurement_dir/soak.log"
else
    printf 'Usage: %s [--evaluate measurement-directory]\n' "$0" >&2
    exit 2
fi

node - "$measurement_dir" <<'NODE'
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const dir=process.argv[2];
const states=['clear','partly','overcast','fog','moderate-rain','freezing','snow','thunder','hail'];
function requireValid(condition,message){if(!condition)throw new Error(message);}
function read(name){return JSON.parse(fs.readFileSync(path.join(dir,name+'.json'),'utf8'));}
function finite(value){return typeof value==='number'&&Number.isFinite(value)&&value>=0;}
try{
  const results={};
  for(const renderer of ['classic','auto']){
    const rows=read(renderer);
    requireValid(Array.isArray(rows)&&rows.length===18,renderer+': expected 18 state/phase rows');
    const map=new Map();
    for(const row of rows){
      requireValid(states.includes(row.state)&&['day','night'].includes(row.phase)&&row.renderer===renderer,'invalid state/phase/renderer');
      for(const key of ['cpuMean','cpuP95','rssStart','rssEnd'])requireValid(finite(row[key]),'invalid '+key);
      requireValid(row.rssStart>0&&row.rssEnd>0,'invalid RSS');
      const key=row.state+'/'+row.phase;
      requireValid(!map.has(key),'duplicate '+key);map.set(key,row);
    }
    results[renderer]=map;
  }
  const soak=read('soak');
  requireValid(Array.isArray(soak)&&soak.length===61,'expected 61 ten-second soak samples');
  soak.forEach((row,i)=>requireValid(row.seconds===i*10&&finite(row.rss)&&row.rss>0&&row.renderer==='auto'&&row.state==='thunder'&&row.phase==='night','invalid soak sample'));
  let passed=true;
  const lines=['# WeatherAether performance budget','',
    '1920×1080 CSS pixels; balanced quality; production 30 fps rAF throttle; 5 s warmup, 30 samples at 1 Hz per row. CPU is ps %cpu (one core); RSS is KiB. Auto must remain Three.js; classic must remain Canvas. Offline deterministic previews; live rAF callback rate checked at 15–35 Hz. Quality passes may paint less frequently.','',
    '| State | Phase | Three CPU mean | p95 | Canvas CPU mean | p95 | Ratio | Three RSS start → end (KiB) | Canvas RSS start → end (KiB) | Result |',
    '|---|---|---:|---:|---:|---:|---:|---:|---:|---|'];
  for(const state of states)for(const phase of ['day','night']){
    const three=results.auto.get(state+'/'+phase),canvas=results.classic.get(state+'/'+phase);
    requireValid(three&&canvas,'missing '+state+'/'+phase);
    const pass=three.cpuMean<=1.5*canvas.cpuMean;
    passed&&=pass;
    const ratio=canvas.cpuMean? (three.cpuMean/canvas.cpuMean).toFixed(3):three.cpuMean?'∞':'0';
    lines.push(`| ${state} | ${phase} | ${three.cpuMean.toFixed(2)} | ${three.cpuP95.toFixed(2)} | ${canvas.cpuMean.toFixed(2)} | ${canvas.cpuP95.toFixed(2)} | ${ratio} | ${three.rssStart} → ${three.rssEnd} | ${canvas.rssStart} → ${canvas.rssEnd} | ${pass?'PASS':'FAIL'} |`);
  }
  const minute=soak.filter(row=>row.seconds>=60);
  const monotonic=minute.every((row,i)=>i===0||row.rss>=minute[i-1].rss);
  const growth=(minute.at(-1).rss-minute[0].rss)/minute[0].rss;
  const soakPass=!(monotonic&&growth>0.10);
  passed&&=soakPass;
  lines.push('',`Soak: ${soakPass?'PASS':'FAIL'} — thunder/night/auto, 600 s, RSS minute 1 ${minute[0].rss} → minute 10 ${minute.at(-1).rss} KiB (${(growth*100).toFixed(2)}%); nondecreasing at every 10 s sample: ${monotonic}.`,'',
    '| Soak seconds | RSS (KiB) |','|---:|---:|',...soak.map(row=>`| ${row.seconds} | ${row.rss} |`),'',
    'Process attribution: WKWebView _webProcessIdentifier when available, validated against ps WebContent processes. Fallback accepts exactly one new WebContent process since harness creation and pins that PID. Competing launches are rejected when ambiguous. This standalone diagnostic uses a private accessor; no app target includes it. WebContent CPU excludes the separate GPU process; ps CPU is a decaying scheduler average rather than an interval delta. The ordered offscreen window must pass document visibility and live-frame checks.','',
    `Overall: ${passed?'PASS':'FAIL'}`,'');
  const markdown=lines.join('\n');
  fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'weather-perf.md'),markdown);
  if(dir==='build/weather-perf')fs.writeFileSync('build/weather-perf.md',markdown);
  process.stdout.write(markdown);
  process.exitCode=passed?0:1;
}catch(error){console.error('Invalid measurement: '+error.message);process.exitCode=2;}
NODE
