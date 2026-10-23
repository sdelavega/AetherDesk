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
    rm -f build/weather-perf.md "$measurement_dir/classic.json" "$measurement_dir/balanced.json" "$measurement_dir/eco.json" "$measurement_dir/soak.json"
    Tools/WeatherPerf/build.sh
    /usr/bin/caffeinate -di build/WeatherPerf --renderer classic --quality balanced --seconds 30 \
        --out "$measurement_dir/classic.json" | tee "$measurement_dir/classic.log"
    for quality in balanced eco; do
        /usr/bin/caffeinate -di build/WeatherPerf --renderer auto --quality "$quality" --seconds 30 \
            --out "$measurement_dir/$quality.json" | tee "$measurement_dir/$quality.log"
    done
    /usr/bin/caffeinate -di build/WeatherPerf --renderer auto --quality balanced --soak 600 \
        --out "$measurement_dir/soak.json" | tee "$measurement_dir/soak.log"
else
    printf 'Usage: %s [--evaluate measurement-directory]\n' "$0" >&2
    exit 2
fi

node - "$measurement_dir" <<'NODE'
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const dir=process.argv[2];
const states=['clear','partly','overcast','fog','moderate-rain','freezing','snow','thunder','hail'];
function requireValid(condition,message){if(!condition)throw new Error(message);}
function read(name){return JSON.parse(fs.readFileSync(path.join(dir,name+'.json'),'utf8'));}
function finite(value){return typeof value==='number'&&Number.isFinite(value)&&value>=0;}
try{
  const results={};
  for(const tier of ['classic','balanced','eco']){
    const rows=read(tier);
    requireValid(Array.isArray(rows)&&rows.length===18,tier+': expected 18 state/phase rows');
    const map=new Map();
    for(const row of rows){
      requireValid(states.includes(row.state)&&['day','night'].includes(row.phase)&&row.renderer===(tier==='classic'?'classic':'auto')&&row.quality===(tier==='classic'?'balanced':tier),'invalid state/phase/renderer/quality');
      for(const key of ['cpuMean','cpuP95','rssStart','rssEnd','gpuMean'])requireValid(finite(row[key]),'invalid '+key);
      requireValid(row.cpuMethod==='proc_pid_rusage','expected interval CPU-time measurement');
      requireValid(Array.isArray(row.cpuDeltas)&&row.cpuDeltas.length===30&&row.cpuDeltas.every(finite)&&
        Array.isArray(row.cpuIntervals)&&row.cpuIntervals.length===30&&row.cpuIntervals.every(value=>finite(value)&&value>0),'expected 30 valid CPU-time intervals');
      const cpuTime=row.cpuDeltas.reduce((sum,value)=>sum+value,0);
      const cpuWindow=row.cpuIntervals.reduce((sum,value)=>sum+value,0);
      const rates=row.cpuDeltas.map((value,i)=>100*value/row.cpuIntervals[i]).sort((a,b)=>a-b);
      requireValid(finite(row.cpuTimeSeconds)&&finite(row.cpuWindowSeconds)&&row.cpuWindowSeconds>0&&
        Math.abs(row.cpuTimeSeconds-cpuTime)<1e-9&&Math.abs(row.cpuWindowSeconds-cpuWindow)<1e-9&&
        Math.abs(row.cpuMean-100*cpuTime/cpuWindow)<1e-9&&Math.abs(row.cpuP95-rates[28])<1e-9,'inconsistent CPU-time accounting');
      requireValid(row.gpuMean<=100&&row.gpuSamples===30,'expected 30 valid GPU samples');
      requireValid(finite(row.gpuBaselineMean)&&row.gpuBaselineMean<=100&&row.gpuBaselineSamples===15,'expected 15 valid idle GPU samples');
      requireValid(typeof row.gpuMarginalMean==='number'&&Number.isFinite(row.gpuMarginalMean)&&
        Math.abs(row.gpuMarginalMean-(row.gpuMean-row.gpuBaselineMean))<1e-9,'invalid marginal GPU mean');
      requireValid(row.rssStart>0&&row.rssEnd>0,'invalid RSS');
      const key=row.state+'/'+row.phase;
      requireValid(!map.has(key),'duplicate '+key);map.set(key,row);
    }
    results[tier]=map;
  }
  const soak=read('soak');
  requireValid(Array.isArray(soak)&&soak.length===61,'expected 61 ten-second soak samples');
  soak.forEach((row,i)=>requireValid(row.seconds===i*10&&finite(row.rss)&&row.rss>0&&row.renderer==='auto'&&row.quality==='balanced'&&row.state==='thunder'&&row.phase==='night','invalid soak sample'));
  let passed=true;
  const model=execFileSync('/usr/sbin/sysctl',['-n','hw.model'],{encoding:'utf8'}).trim();
  const lines=['# WeatherAether performance budget','',`Reference Mac: ${model}.`, '',
    '1920×1080 CSS pixels; production 30 fps rAF cap; 5 s warmup and 30 samples at 1 Hz per state/phase. CPU is pinned WebContent proc_pid_rusage user + system time deltas (Mach time units converted to seconds with mach_timebase_info), divided by monotonic wall time as percent of one core. Mean is total CPU time / total sampling window; p95 uses nearest rank of the 30 one-second interval rates. Raw CPU deltas and actual wall intervals are retained in JSON and checked against the reported aggregates; RSS is KiB. Auto must remain Three.js. Canvas is a recorded reference only. Offline deterministic previews; live rAF callback rate checked at 15–35 Hz. Quiet skies retain caching.','',
    'GPU: ioreg -r -d 1 -c IOAccelerator (XML output via -a), PerformanceStatistics → Device Utilization %, once per second, without sudo. Highest utilization across accelerators per sample. This is whole-device activity, including other applications; it cannot attribute GPU work to WeatherAether. Before each case, collect a 15 s idle baseline at 1 Hz with no harness web view loaded. Gate on marginal GPU (raw case mean minus idle baseline mean); negative differences are retained. Missing or invalid samples fail closed.',''];
  for(const tier of ['balanced','eco','classic']){
    lines.push(`## ${tier==='classic'?'Canvas reference':tier}`, '',
      tier==='balanced'?'Budgets: CPU mean ≤ 7.0%, p95 ≤ 10.0%, marginal GPU mean ≤ 20.0%.':tier==='eco'?'Budgets: CPU mean ≤ 3.5%, marginal GPU mean ≤ 12.0%.':'No performance gate.', '',
      '| State | Phase | CPU mean | CPU p95 | GPU baseline | GPU raw | GPU marginal | RSS start → end (KiB) | Result |',
      '|---|---|---:|---:|---:|---:|---:|---:|---|');
    for(const state of states)for(const phase of ['day','night']){
      const row=results[tier].get(state+'/'+phase);
      requireValid(row,'missing '+tier+'/'+state+'/'+phase);
      const pass=tier==='classic'||(tier==='balanced'?row.cpuMean<=7&&row.cpuP95<=10&&row.gpuMarginalMean<=20:row.cpuMean<=3.5&&row.gpuMarginalMean<=12);
      passed&&=pass;
      lines.push(`| ${state} | ${phase} | ${row.cpuMean.toFixed(2)} | ${row.cpuP95.toFixed(2)} | ${row.gpuBaselineMean.toFixed(2)} | ${row.gpuMean.toFixed(2)} | ${row.gpuMarginalMean.toFixed(2)} | ${row.rssStart} → ${row.rssEnd} | ${tier==='classic'?'REFERENCE':pass?'PASS':'FAIL'} |`);
    }
    lines.push('');
  }
  const minute=soak.filter(row=>row.seconds>=60);
  const growth=(minute.at(-1).rss-minute[0].rss)/minute[0].rss;
  const soakPass=growth<=0.10;
  passed&&=soakPass;
  lines.push(`Soak: ${soakPass?'PASS':'FAIL'} — thunder/night/balanced, 600 s, RSS minute 1 ${minute[0].rss} → minute 10 ${minute.at(-1).rss} KiB (${(growth*100).toFixed(2)}%).`,'',
    '| Soak seconds | RSS (KiB) |','|---:|---:|',...soak.map(row=>`| ${row.seconds} | ${row.rss} |`),'',
    'Process attribution: WKWebView _webProcessIdentifier validated against ps WebContent inventory; fallback accepts exactly one new process and pins it. This private accessor is standalone diagnostic code only. WebContent CPU excludes the separate GPU process; cumulative CPU counters are sampled once per second and only deltas inside each sampling window contribute. The ordered window has a small visible corner and must pass visibility, renderer and live-frame checks. GPU sampling continues at 1 Hz during soak; RSS is recorded every 10 seconds.','',
    `Overall: ${passed?'PASS':'FAIL'}`,'');
  const markdown=lines.join('\n');
  fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'weather-perf.md'),markdown);
  if(dir==='build/weather-perf')fs.writeFileSync('build/weather-perf.md',markdown);
  process.stdout.write(markdown);
  process.exitCode=passed?0:1;
}catch(error){console.error('Invalid measurement: '+error.message);process.exitCode=2;}
NODE
