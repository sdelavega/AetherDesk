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
# With no arguments, measure and evaluate both wallpapers. --evaluate retains
# compatibility with recorded WeatherAether data; select NeonCity explicitly.
if [[ $# -eq 0 ]]; then
    "$0" --wallpaper weather
    exec "$0" --wallpaper neoncity
fi
wallpaper=weather
measurement_dir=
while [[ $# -gt 0 ]]; do
    if [[ $# -lt 2 ]]; then exit 2; fi
    case "$1" in
        --wallpaper) wallpaper=$2 ;;
        --evaluate) measurement_dir=$2 ;;
        *) printf 'Usage: %s [--wallpaper weather|neoncity] [--evaluate directory]\n' "$0" >&2; exit 2 ;;
    esac
    shift 2
done
if [[ "$wallpaper" != weather && "$wallpaper" != neoncity ]]; then exit 2; fi
wait_for_installed_app() {
    local elapsed=0
    local waiting_file=.superpowers/sdd/2026-10-22-aetherdesk-v1.4/task-13e-waiting.txt
    while /bin/ps -axo comm= | /usr/bin/grep -F '/Applications/ÆtherDesk.app/' > /dev/null; do
        printf 'Waiting for installed ÆtherDesk to exit; elapsed %s seconds (limit 1800).\n' "$elapsed" | tee "$waiting_file"
        if [[ "$elapsed" -ge 1800 ]]; then return 1; fi
        sleep 30
        elapsed=$((elapsed + 30))
    done
}
if [[ -z "$measurement_dir" ]]; then
    measurement_dir=build/weather-perf
    if [[ "$wallpaper" == neoncity ]]; then measurement_dir=build/neoncity-perf; fi
    mkdir -p "$measurement_dir"
    rm -f "$measurement_dir/classic.json" "$measurement_dir/balanced.json" "$measurement_dir/eco.json" "$measurement_dir/soak.json"
    Tools/WeatherPerf/build.sh
    wait_for_installed_app
    /usr/bin/caffeinate -di build/WeatherPerf --wallpaper "$wallpaper" --renderer classic --quality balanced --seconds 30 \
        --out "$measurement_dir/classic.json" | tee "$measurement_dir/classic.log"
    for quality in balanced eco; do
        wait_for_installed_app
        /usr/bin/caffeinate -di build/WeatherPerf --wallpaper "$wallpaper" --renderer auto --quality "$quality" --seconds 30 \
            --out "$measurement_dir/$quality.json" | tee "$measurement_dir/$quality.log"
    done
    wait_for_installed_app
    /usr/bin/caffeinate -di build/WeatherPerf --wallpaper "$wallpaper" --renderer auto --quality balanced --soak 600 \
        --out "$measurement_dir/soak.json" | tee "$measurement_dir/soak.log"
fi

node - "$measurement_dir" "$wallpaper" <<'NODE'
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const dir=process.argv[2];
const neonCity=process.argv[3]==='neoncity';
const name=neonCity?'NeonCity':'WeatherAether';
const states=neonCity?['clear','drizzle','rain','downpour','fog','snow']:['clear','partly','overcast','fog','moderate-rain','freezing','snow','thunder','hail'];
const phases=neonCity?['night','dawn','day','dusk']:['day','night'];
function requireValid(condition,message){if(!condition)throw new Error(message);}
function read(name){return JSON.parse(fs.readFileSync(path.join(dir,name+'.json'),'utf8'));}
function finite(value){return typeof value==='number'&&Number.isFinite(value)&&value>=0;}
try{
  const results={};
  for(const tier of ['classic','balanced','eco']){
    const rows=read(tier);
    requireValid(Array.isArray(rows)&&rows.length===states.length*phases.length,tier+': expected '+states.length*phases.length+' state/phase rows');
    const map=new Map();
    for(const row of rows){
      requireValid(states.includes(row.state)&&phases.includes(row.phase)&&row.renderer===(tier==='classic'?'classic':'auto')&&row.quality===(tier==='classic'?'balanced':tier),'invalid state/phase/renderer/quality');
      if(neonCity){
        const saver=tier==='eco',quality=row.tier;
        requireValid(row.wallpaper==='neoncity','expected NeonCity measurement');
        requireValid(finite(row.fps)&&row.fps>=(saver?13:27)&&row.fps<=(saver?17:32),'invalid live painted frame rate');
        requireValid(quality&&quality.fps===(saver?15:30)&&quality.renderScale===(saver?0.5:0.75)&&quality.countScale===(saver?0.4:1)&&quality.eventScale===(saver?0.5:1),'invalid NeonCity tier');
        requireValid(finite(row.renderScale)&&(saver?row.renderScale===0.5:row.renderScale>=0.75&&row.renderScale<=1),'invalid NeonCity render scale');
        requireValid(row.viewportWidth===1920&&row.viewportHeight===1080,'expected 1920x1080 CSS viewport');
        if(tier!=='classic')requireValid(row.drawingWidth===Math.floor(row.viewportWidth*row.renderScale)&&row.drawingHeight===Math.floor(row.viewportHeight*row.renderScale),'drawing buffer differs from CSS-pixel scale');
      }
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
  soak.forEach((row,i)=>requireValid(row.seconds===i*10&&finite(row.rss)&&row.rss>0&&row.renderer==='auto'&&row.quality==='balanced'&&row.state===(neonCity?'rain':'thunder')&&row.phase==='night'&&(!neonCity||row.wallpaper==='neoncity'),'invalid soak sample'));
  let passed=true;
  const model=execFileSync('/usr/sbin/sysctl',['-n','hw.model'],{encoding:'utf8'}).trim();
  const lines=[`# ${name} performance budget`,'',`Reference Mac: ${model}.`, '',
    ...(neonCity?['R26: 4 phases × 6 weather states per tier through Tools/NeonCityPreview.html. Normal: 30 fps / scale 0.75 / count 1 / events 1; saver: 15 fps / 0.5 / 0.4 / 0.5. Auto drawing-buffer scale is relative to CSS pixels: 1440x810 normal and 960x540 saver at this viewport, including on Retina displays. Painted frame rate (27–32 normal, 13–17 saver), tier and actual buffer scale are validated. Classic uses its full CSS-size Canvas as a reference. Installed /Applications/ÆtherDesk.app must be absent; caffeinate keeps the display awake.','']:[]),
    '1920×1080 CSS pixels; production 30 fps rAF cap; 5 s warmup and 30 samples at 1 Hz per state/phase. CPU is pinned WebContent proc_pid_rusage user + system time deltas (Mach time units converted to seconds with mach_timebase_info), divided by monotonic wall time as percent of one core. Mean is total CPU time / total sampling window; p95 uses nearest rank of the 30 one-second interval rates. Raw CPU deltas and actual wall intervals are retained in JSON and checked against the reported aggregates; RSS is KiB. Auto must remain Three.js. Canvas is a recorded reference only. Offline deterministic previews; live frame rate must pass the wallpaper/tier guard. Quiet skies retain caching.','',
    'GPU: ioreg -r -d 1 -c IOAccelerator (XML output via -a), PerformanceStatistics → Device Utilization %, once per second, without sudo. Highest utilization across accelerators per sample. This is whole-device activity, including other applications; it cannot attribute GPU work to an individual wallpaper. Before each case, collect a 15 s idle baseline at 1 Hz with no harness web view loaded. Gate on marginal GPU (raw case mean minus idle baseline mean); negative differences are retained. Missing or invalid samples fail closed.',''];
  for(const tier of ['balanced','eco','classic']){
    lines.push(`## ${tier==='classic'?(neonCity?'Classic (Canvas) reference':'Canvas reference'):tier}`, '',
      tier==='balanced'?'Budgets: CPU mean ≤ 7.0%, p95 ≤ 10.0%, marginal GPU mean ≤ 20.0%.':tier==='eco'?'Budgets: CPU mean ≤ 4.25%, marginal GPU mean ≤ 12.0%.':'No performance gate.', '',
      '| State | Phase | CPU mean | CPU p95 | GPU baseline | GPU raw | GPU marginal | RSS start → end (KiB) | Result |',
      '|---|---|---:|---:|---:|---:|---:|---:|---|');
    for(const state of states)for(const phase of phases){
      const row=results[tier].get(state+'/'+phase);
      requireValid(row,'missing '+tier+'/'+state+'/'+phase);
      const pass=tier==='classic'||(tier==='balanced'?row.cpuMean<=7&&row.cpuP95<=10&&row.gpuMarginalMean<=20:row.cpuMean<=4.25&&row.gpuMarginalMean<=12);
      passed&&=pass;
      lines.push(`| ${state} | ${phase} | ${row.cpuMean.toFixed(2)} | ${row.cpuP95.toFixed(2)} | ${row.gpuBaselineMean.toFixed(2)} | ${row.gpuMean.toFixed(2)} | ${row.gpuMarginalMean.toFixed(2)} | ${row.rssStart} → ${row.rssEnd} | ${tier==='classic'?'REFERENCE':pass?'PASS':'FAIL'} |`);
    }
    lines.push('');
  }
  const minute=soak.filter(row=>row.seconds>=60);
  const growth=(minute.at(-1).rss-minute[0].rss)/minute[0].rss;
  const soakPass=growth<=0.10;
  passed&&=soakPass;
  lines.push(`Soak: ${soakPass?'PASS':'FAIL'} — ${neonCity?'rain':'thunder'}/night/balanced, 600 s, RSS minute 1 ${minute[0].rss} → minute 10 ${minute.at(-1).rss} KiB (${(growth*100).toFixed(2)}%).`,'',
    '| Soak seconds | RSS (KiB) |','|---:|---:|',...soak.map(row=>`| ${row.seconds} | ${row.rss} |`),'',
    'Process attribution: WKWebView _webProcessIdentifier validated against ps WebContent inventory; fallback accepts exactly one new process and pins it. This private accessor is standalone diagnostic code only. WebContent CPU excludes the separate GPU process; cumulative CPU counters are sampled once per second and only deltas inside each sampling window contribute. The ordered window has a small visible corner and must pass visibility, renderer and live-frame checks. GPU sampling continues at 1 Hz during soak; RSS is recorded every 10 seconds.','',
    `Overall: ${passed?'PASS':'FAIL'}`,'');
  const markdown=lines.join('\n');
  const ledger=neonCity?'neoncity-perf':'weather-perf';
  fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,ledger+'.md'),markdown);
  if(dir==='build/'+ledger)fs.writeFileSync('build/'+ledger+'.md',markdown);
  process.stdout.write(markdown);
  process.exitCode=passed?0:1;
}catch(error){console.error('Invalid measurement: '+error.message);process.exitCode=2;}
NODE
