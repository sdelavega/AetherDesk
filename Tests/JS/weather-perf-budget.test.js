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

'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const states=['clear','partly','overcast','fog','moderate-rain','freezing','snow','thunder','hail'];
function cpuWindow(row,mean,p95=mean){
  row.cpuMethod='proc_pid_rusage';
  row.cpuIntervals=Array(30).fill(1);
  row.cpuDeltas=Array(30).fill((30*mean-2*p95)/28/100);
  row.cpuDeltas[28]=row.cpuDeltas[29]=p95/100;
  row.cpuWindowSeconds=30;row.cpuTimeSeconds=30*mean/100;
  row.cpuMean=mean;row.cpuP95=p95;
}
function check(edit){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'weather-perf-'));
  const data={};
  for(const quality of ['balanced','eco','classic'])data[quality]=states.flatMap(state=>['day','night'].map(phase=>({state,phase,renderer:quality==='classic'?'classic':'auto',quality:quality==='classic'?'balanced':quality,gpuMean:quality==='eco'?72:80,gpuSamples:30,gpuBaselineMean:60,gpuBaselineSamples:15,gpuMarginalMean:quality==='eco'?12:20,rssStart:100,rssEnd:100})));
  data.soak=Array.from({length:61},(_,i)=>({seconds:i*10,rss:100,renderer:'auto',quality:'balanced',state:'thunder',phase:'night'}));
  for(const tier of ['classic','balanced','eco'])for(const row of data[tier])cpuWindow(row,tier==='balanced'?7:tier==='eco'?3.5:2,10);
  edit(data);
  for(const key of Object.keys(data))fs.writeFileSync(path.join(dir,key+'.json'),JSON.stringify(data[key]));
  try{return spawnSync('bash',['scripts/check-weather-perf.sh','--evaluate',dir],{encoding:'utf8'});}
  finally{fs.rmSync(dir,{recursive:true,force:true});}
}
test('native CPU counter units agree with getrusage seconds',()=>{
  const source=fs.readFileSync('Tools/WeatherPerf/main.swift','utf8').split('// IOAccelerator reports')[0];
  const result=spawnSync('/usr/bin/swift',['-e',source+`
var beforeUsage = rusage()
var afterUsage = rusage()
let before = try sample(getpid())
guard getrusage(RUSAGE_SELF, &beforeUsage) == 0 else { exit(2) }
let deadline = ProcessInfo.processInfo.systemUptime + 0.25
var iterations: UInt64 = 0
while ProcessInfo.processInfo.systemUptime < deadline { iterations &+= 1 }
guard getrusage(RUSAGE_SELF, &afterUsage) == 0 else { exit(2) }
let after = try sample(getpid())
func seconds(_ usage: rusage) -> Double {
    Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
let expected = seconds(afterUsage) - seconds(beforeUsage)
let actual = after.cpuSeconds - before.cpuSeconds
print("getrusage seconds", expected, "sample seconds", actual, "iterations", iterations)
guard expected > 0.05, abs(actual - expected) < expected * 0.1 + 0.005 else { exit(1) }
`],{encoding:'utf8',timeout:30000});
  assert.equal(result.status,0,result.stderr+result.stdout);
});
test('absolute budgets accept equality regardless of Canvas CPU',()=>{
  const result=check(data=>{for(const row of data.classic)cpuWindow(row,100,100);data.soak.forEach((row,i)=>{row.rss=100+Math.max(0,i-6)*10/54;});});
  assert.equal(result.status,0,result.stderr+result.stdout);
});
test('each absolute CPU and GPU threshold rejects an excess',()=>{
  for(const [tier,key,limit] of [['balanced','cpuMean',7],['balanced','cpuP95',10],['balanced','gpuMarginalMean',20],['eco','cpuMean',3.5],['eco','gpuMarginalMean',12]]){
    const result=check(data=>{const row=data[tier][0];if(key==='cpuMean')cpuWindow(row,limit+0.01,10);else if(key==='cpuP95')cpuWindow(row,7,limit+0.01);else row[key]=limit+0.01;if(key==='gpuMarginalMean')row.gpuMean=row.gpuBaselineMean+limit+0.01;});
    assert.equal(result.status,1,tier+'/'+key+': '+result.stderr+result.stdout);
    assert.match(result.stdout,/clear.*day.*FAIL/);
  }
});
test('CPU mean weights actual wall intervals and p95 uses interval rates',()=>{
  const result=check(data=>{
    const row=data.balanced[0];row.cpuIntervals=Array(15).fill(0.8).concat(Array(15).fill(1.2));
    row.cpuDeltas=Array(15).fill(0.08).concat(Array(15).fill(0.06));
    row.cpuTimeSeconds=2.1;row.cpuWindowSeconds=30;row.cpuMean=7;row.cpuP95=10;
  });
  assert.equal(result.status,0,result.stderr+result.stdout);
  assert.match(result.stdout,/proc_pid_rusage/);
});
test('legacy CPU averages and inconsistent interval accounting fail closed',()=>{
  for(const edit of [row=>{delete row.cpuMethod;},row=>{row.cpuMethod='ps %cpu';},row=>{row.cpuDeltas.pop();},row=>{row.cpuIntervals[0]=0;},row=>{row.cpuDeltas[0]=-1;},row=>{row.cpuDeltas[0]=null;},row=>{row.cpuIntervals[0]=null;},row=>{row.cpuMean=6;},row=>{row.cpuP95=9;},row=>{row.cpuTimeSeconds=1;},row=>{row.cpuWindowSeconds=29;}]){
    const result=check(data=>edit(data.balanced[0]));
    assert.equal(result.status,2,result.stderr+result.stdout);assert.match(result.stderr,/Invalid measurement/);
  }
});
test('negative marginal GPU passes and baseline/raw/marginal appear in the ledger',()=>{
  const result=check(data=>{const row=data.eco[0];row.gpuMean=55;row.gpuMarginalMean=-5;});
  assert.equal(result.status,0,result.stderr+result.stdout);
  assert.match(result.stdout,/GPU baseline.*GPU raw.*GPU marginal/);
  assert.match(result.stdout,/60\.00.*55\.00.*-5\.00/);
});
test('baseline samples and marginal arithmetic must be valid',()=>{
  for(const edit of [data=>{delete data.eco[0].gpuBaselineMean;},data=>{data.eco[0].gpuBaselineSamples=14;},data=>{data.eco[0].gpuBaselineMean=101;},data=>{data.eco[0].gpuMarginalMean=null;},data=>{data.eco[0].gpuMarginalMean=0;}]){
    const result=check(edit);assert.equal(result.status,2);assert.match(result.stderr,/Invalid measurement/);
  }
});
test('RSS endpoint growth over 10% fails with or without intermediate dips',()=>{
  for(const dip of [false,true]){
    const result=check(data=>{data.soak.forEach((row,i)=>{row.rss=100+Math.max(0,i-6)*11/54;});if(dip)data.soak[30].rss=99;});
    assert.equal(result.status,1);assert.match(result.stdout,/soak.*FAIL/i);
  }
});
test('incomplete, duplicate, nonfinite, missing GPU and invalid measurements fail closed',()=>{
  for(const edit of [data=>data.eco.pop(),data=>{data.balanced[1]=data.balanced[0];},data=>{data.balanced[0].cpuMean=null;},data=>data.soak.pop(),data=>{data.classic[0].rssEnd=-1;},data=>{data.eco[0].gpuMean=null;},data=>{data.balanced[0].gpuSamples=0;}]){
    const result=check(edit);assert.notEqual(result.status,0);assert.match(result.stderr,/Invalid measurement/);
  }
});
