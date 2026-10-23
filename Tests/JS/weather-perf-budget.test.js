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
function check(edit){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'weather-perf-'));
  const data={};
  for(const renderer of ['auto','classic'])data[renderer]=states.flatMap(state=>['day','night'].map(phase=>({state,phase,renderer,cpuMean:renderer==='auto'?15:10,cpuP95:20,rssStart:100,rssEnd:100})));
  data.soak=Array.from({length:61},(_,i)=>({seconds:i*10,rss:100,renderer:'auto',state:'thunder',phase:'night'}));
  edit(data);
  for(const key of Object.keys(data))fs.writeFileSync(path.join(dir,key+'.json'),JSON.stringify(data[key]));
  try{return spawnSync('bash',['scripts/check-weather-perf.sh','--evaluate',dir],{encoding:'utf8'});}
  finally{fs.rmSync(dir,{recursive:true,force:true});}
}
test('performance budgets accept equality and a 10% monotonic RSS rise',()=>{
  const result=check(data=>data.soak.forEach((row,i)=>{row.rss=100+Math.max(0,i-6)*10/54;}));
  assert.equal(result.status,0,result.stderr+result.stdout);
});
test('one over-budget state fails and is named in the ledger',()=>{
  const result=check(data=>{data.auto[17].cpuMean=15.01;});
  assert.equal(result.status,1);assert.match(result.stdout,/hail.*night.*FAIL/);
});
test('monotonic RSS rise over 10% from minute 1 fails',()=>{
  const result=check(data=>data.soak.forEach((row,i)=>{row.rss=100+Math.max(0,i-6)*11/54;}));
  assert.equal(result.status,1);assert.match(result.stdout,/soak.*FAIL/i);
});
test('nonmonotonic RSS growth does not meet the specified leak threshold',()=>{
  const result=check(data=>{data.soak[30].rss=99;data.soak[60].rss=120;});
  assert.equal(result.status,0,result.stderr+result.stdout);
});
test('incomplete, duplicate, nonfinite, and invalid measurements fail closed',()=>{
  for(const edit of [data=>data.auto.pop(),data=>{data.auto[1]=data.auto[0];},data=>{data.auto[0].cpuMean=null;},data=>data.soak.pop(),data=>{data.classic[0].rssEnd=-1;}]){
    const result=check(edit);assert.notEqual(result.status,0);assert.match(result.stderr,/Invalid measurement/);
  }
});
