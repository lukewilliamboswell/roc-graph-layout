// Fault injection against the actual CLI, never an acceptance baseline.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { openBrowser } from './oracle.mjs';
import { openRaster, compare } from './raster.mjs';
import { normalizeReference } from './families/sequence.mjs';

const binary = process.env.ORACLE_DUMP;
test('strict CLI rejects missing/stale/empty references and dishonest native observations', { skip: !binary }, async () => {
 const work=await fs.mkdtemp(path.join(os.tmpdir(),'mermaid-oracle-guard-'));
 const source=await fs.readFile('tests/mermaid/sequence/basic.mmd');
 const record=JSON.parse(await fs.readFile('tests/mermaid/sequence/basic.oracle.json','utf8'));
 const reference=normalizeReference(record);
 const browser=await openBrowser();
 let svg;
 try {const first=await browser.extract(source.toString());svg=first.svg;assert.ok(svg);assert.deepEqual(await browser.extract(source.toString()),first,'reference observations depend on earlier case caches');}finally{await browser.close();}
 async function fixture(name,{withRecord=true,stale=false,empty=false}={}) {
  const root=path.join(work,name),dir=path.join(root,'tests/mermaid/sequence');
  await fs.mkdir(dir,{recursive:true});
  if(!empty){await fs.writeFile(path.join(dir,'basic.mmd'),source);if(withRecord)await fs.writeFile(path.join(dir,'basic.oracle.json'),JSON.stringify(stale?{...record,key:'intentionally-stale'}:record));}
  return root;
 }
 async function run(name,root,tool=binary) {
  const output=path.join(work,`${name}-results`);
  const result=spawnSync(process.execPath,['tools/mermaid-oracle/validate.mjs',tool,output,'--families=sequence',`--case-root=${root}`],{encoding:'utf8',timeout:120000,maxBuffer:8<<20});
  assert.ifError(result.error);
  assert.notEqual(result.status,0,`${name} falsely passed: ${result.stdout}`);
  const report=JSON.parse(await fs.readFile(path.join(output,'report.json'),'utf8'));
  assert.ok(report.summary.failed>0);
  return report;
 }
 try {
  const readable=await fixture('cli-readable');
  const emptySizes=path.join(work,'empty.tsv');await fs.writeFile(emptySizes,'');
  for(const [profile,input,sizes,status]of [
   ['unknown',path.join(readable,'tests/mermaid/sequence/basic.mmd'),emptySizes,2],
   ['default',path.join(work,'missing-source.mmd'),emptySizes,1],
   ['default',path.join(readable,'tests/mermaid/sequence/basic.mmd'),path.join(work,'missing-sizes.tsv'),1],
  ]) {
   const native=spawnSync(binary,['sequence',profile,input,sizes,path.join(work,'unused.json'),path.join(work,'unused.svg')],{encoding:'utf8',timeout:120000});
   assert.ifError(native.error);assert.equal(native.status,status,native.stderr);
  }
  const missing=await run('missing',await fixture('missing',{withRecord:false}));
  assert.match(JSON.stringify(missing.results[0].errors),/ENOENT/);
  const stale=await run('stale',await fixture('stale',{stale:true}));
  assert.match(JSON.stringify(stale.results[0].errors),/stale oracle record/);
  const empty=await run('empty',await fixture('empty',{empty:true}));
  assert.ok(empty.summary.failures.some(x=>x.includes('zero coverage')));
  for(const fault of ['null-geometry','unused-input','missing-text']) {
   const observation={accepted:true,family:'sequence',semantic:reference.semantic,geometry:structuredClone(reference.geometry),size_problems:[]};
   if(fault==='null-geometry')observation.geometry.nodes[0].box.x=null;
   else if(fault==='unused-input')observation.size_problems=['unconsumed label:fake-role'];
   const observedSvg=fault==='missing-text'?svg.replaceAll('Hello',''):svg;
   const fake=path.join(work,`${fault}.mjs`);
   // The fake supplies the exact oracle SVG: a picture comparison alone
   // cannot catch either fault. Independent model/geometry gates must.
   await fs.writeFile(fake,`#!/usr/bin/env node\nimport fs from 'node:fs';\nconst args=process.argv.slice(2);fs.writeFileSync(args[4],${JSON.stringify(JSON.stringify(observation))});fs.writeFileSync(args[5],${JSON.stringify(observedSvg)});\n`,{mode:0o755});
   const report=await run(fault,await fixture(fault),fake);
   const reason=fault==='null-geometry'?'nonfinite or missing numeric geometry':fault==='unused-input'?'invalid or unconsumed size overrides':'rendered text differs from reference';
   assert.ok(report.results[0].errors.some(error=>error.why===reason),`${fault} lost its independent gate`);
  }
 } finally {await fs.rm(work,{recursive:true,force:true});}
});

test('fractional SVG view boxes retain exactly one CSS pixel per unit',async()=>{
 const raster=await openRaster();
 try {
  const box={x:0,y:0,width:10.25,height:10.75};
  const svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10.25 10.75"><rect x="1" y="2" width="3" height="4" fill="black"/></svg>';
  const result=await compare(raster.page,svg,box,svg,box);
  assert.equal(result.score,0);
  const transforms=await raster.page.evaluate(()=>['a','b'].map(id=>{const m=document.getElementById(id).querySelector('svg').getScreenCTM();return [m.a,m.b,m.c,m.d];}));
  assert.deepEqual(transforms,[[1,0,0,1],[1,0,0,1]]);
 }finally{await raster.close();}
});
