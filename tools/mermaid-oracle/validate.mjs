// Strict independent oracle loop. Reports every case; no missing fixture,
// browser error, unsupported accepted input, crash, or zero-coverage pass.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { FAMILY_DIRS, differences } from './contracts.mjs';
import { provenance, keyOf, openBrowser } from './oracle.mjs';
import { scoreCase } from './score.mjs';
import { openRaster, compare, viewBoxOf, writePng } from './raster.mjs';

export function geometryDifferences(expected, actual, tolerance = 1) {
 const errors = [];
 for (const kind of ['nodes','groups','labels']) {
  const want = new Map((expected?.[kind]??[]).map(x=>[x.id,x]));
  const got = new Map((actual?.[kind]??[]).map(x=>[x.id,x]));
  if(want.size !== (expected?.[kind]??[]).length || got.size !== (actual?.[kind]??[]).length) errors.push({kind,why:'duplicate stable id'});
  for(const id of new Set([...want.keys(),...got.keys()])) {
   const a=want.get(id)?.box,b=got.get(id)?.box;
   if(!a||!b) { errors.push({kind,id,why:'missing box',expected:a,actual:b}); continue; }
   for(const field of ['x','y','width','height']) {
    if(!Number.isFinite(a[field])||!Number.isFinite(b[field])||Math.abs(a[field]-b[field])>tolerance) errors.push({kind,id,field,expected:a[field],actual:b[field],delta:b[field]-a[field]});
   }
  }
 }
 for(const kind of ['edges']) {
  const want=new Map((expected?.[kind]??[]).map(x=>[x.id,x])),got=new Map((actual?.[kind]??[]).map(x=>[x.id,x]));
  for(const id of new Set([...want.keys(),...got.keys()])) {
   const a=want.get(id),b=got.get(id);
   if(!a||!b){errors.push({kind,id,why:'missing route'});continue;}
   for(const key of ['from','to'])if(a[key]!==b[key])errors.push({kind,id,field:key,expected:a[key],actual:b[key]});
   if(!Array.isArray(a.points)||!Array.isArray(b.points)||a.points.length!==b.points.length)errors.push({kind,id,why:'route point count differs',expected:a.points?.length,actual:b.points?.length});
  }
 }
 return errors;
}
export function invalidGeometry(geometry) {
 const failures=[];
 const number=(v,path,nonnegative=false)=>{if(!Number.isFinite(v)||(nonnegative&&v<0))failures.push(path);};
 const rect=(b,at)=>{for(const key of ['x','y','width','height'])number(b?.[key],`${at}.${key}`,key==='width'||key==='height');};
 rect(geometry?.view_box,'view_box');
 for(const kind of ['nodes','groups','labels','edges']) {
  if(!Array.isArray(geometry?.[kind])){failures.push(kind);continue;}
  const ids=new Set();
  for(const [i,item] of geometry[kind].entries()) {
   if(typeof item.id!=='string'||ids.has(item.id))failures.push(`${kind}[${i}].id`);ids.add(item.id);
   if(kind!=='edges')rect(item.box,`${kind}[${i}].box`);
   else if(!Array.isArray(item.points))failures.push(`${kind}[${i}].points`);
   else for(const [j,p]of item.points.entries()){number(p?.x,`${kind}[${i}].points[${j}].x`);number(p?.y,`${kind}[${i}].points[${j}].y`);}
  }
 }
 return failures;
}
export function nonFinite(value, at='$') {
 if(typeof value==='number')return Number.isFinite(value)?[]:[at];
 if(Array.isArray(value))return value.flatMap((v,i)=>nonFinite(v,`${at}[${i}]`));
 if(value&&typeof value==='object')return Object.entries(value).flatMap(([k,v])=>nonFinite(v,`${at}.${k}`));
 return [];
}
export function layoutMetrics(expected,actual) {
 const metrics={};
 for(const kind of ['nodes','groups','labels']) {
  const a=expected?.[kind]??[],b=new Map((actual?.[kind]??[]).map(x=>[x.id,x]));
  const sizeErrors=[],positionErrors=[];
  for(const n of a) {
   const m=b.get(n.id); if(!m)continue;
   sizeErrors.push(Math.max(Math.abs(n.box.width-m.box.width),Math.abs(n.box.height-m.box.height)));
   positionErrors.push(Math.hypot(n.box.x-m.box.x,n.box.y-m.box.y));
  }
  metrics[kind]={reference:a.length,actual:actual?.[kind]?.length??0,matched:sizeErrors.length,max_size_error:Math.max(0,...sizeErrors),mean_position_error:positionErrors.length?positionErrors.reduce((a,b)=>a+b,0)/positionErrors.length:null};
 }
 const edges=new Map((actual?.edges??[]).map(e=>[e.id,e]));
 const distance=(p,ps)=>Math.min(...ps.map(q=>Math.hypot(p.x-q.x,p.y-q.y)));
 const errors=[];
 for(const e of expected?.edges??[]) {
  const m=edges.get(e.id); if(!m?.points?.length||!e.points?.length)continue;
  errors.push(Math.max(...e.points.map(p=>distance(p,m.points)),...m.points.map(p=>distance(p,e.points))));
 }
 metrics.edges={reference:expected?.edges?.length??0,actual:actual?.edges?.length??0,matched:errors.length,max_control_point_hausdorff:Math.max(0,...errors)};
 return metrics;
}
export function tokenDifferences(expected,actual) {
 const counts=words=>{const m=new Map();for(const word of words.match(/[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/gu)??[])m.set(word,(m.get(word)??0)+1);return m;};
 const a=counts(expected),b=counts(actual),missing=[],extra=[];
 for(const token of new Set([...a.keys(),...b.keys()])) {
  const delta=(a.get(token)??0)-(b.get(token)??0);
  if(delta>0)missing.push({token,count:delta});else if(delta<0)extra.push({token,count:-delta});
 }
 return {missing,extra};
}
async function renderedTextDifferences(page) {
 const texts=await page.evaluate(()=>{
  const walk=node=>{
   if(node.nodeType===Node.TEXT_NODE)return node.textContent;
   const content=[...node.childNodes].map(walk).join('');
   return node.tagName?.toLowerCase()==='tspan'&&(node.hasAttribute('x')||node.hasAttribute('y')||node.hasAttribute('dy')||node.classList.contains('row'))?` ${content} `:content;
  };
  return ['a','b'].map(id=>[...document.getElementById(id).querySelectorAll('text')].filter(e=>!e.closest('defs')).map(walk).join(' '));
 });
 return tokenDifferences(texts[0],texts[1]);
}
export function parityProblems(family,score,actual,expected) {
 const problems=[];
 if(!Number.isFinite(score)||score<0||score>1)problems.push({why:'invalid pixel score',actual:score});
 else if(family!=='flowchart'&&score>0.05)problems.push({why:'rendered parity exceeds 5% unmatched ink',actual:score,maximum:0.05});
 if(family!=='flowchart'&&(Math.abs(actual.width-expected.width)>1||Math.abs(actual.height-expected.height)>1))problems.push({why:'view dimensions differ by more than one CSS pixel',expected,actual});
 return problems;
}
function run(binary,args) {
 const result=spawnSync(binary,args,{encoding:'utf8',maxBuffer:64<<20,timeout:120000});
 if(result.error || result.status!==0) throw new Error(`native probe failed: ${result.error??result.stderr??result.status}`);
}
const write=(file,value)=>fs.writeFile(file,JSON.stringify(value,null,'\t')+'\n');

async function main() {
 const [binary,outDir,...flags]=process.argv.slice(2);
 if(!binary||!outDir) throw new Error('usage: validate.mjs <native oracle_dump> <output> [--report-only] [--families=sequence,entity,class,state,flowchart]');
 const caseRoot=flags.find(x=>x.startsWith('--case-root='))?.slice(12)??'';
 const selected=flags.find(x=>x.startsWith('--families='))?.slice(11).split(',')??Object.keys(FAMILY_DIRS);
 for(const f of selected) if(!Object.hasOwn(FAMILY_DIRS,f)) throw new Error(`unknown family ${f}`);
 if(!selected.length)throw new Error('zero families selected');
 await fs.mkdir(outDir,{recursive:true});
 const prov=await provenance(), results=[], failures=[];
 const browser=await openBrowser(), raster=await openRaster();
 try {
  for(const family of selected) {
   const familyStart=results.length;
   const {normalizeReference}=await import(`./families/${family}.mjs`);
   let count=0;
   for(const relativeDir of FAMILY_DIRS[family]) {
    const dir=path.join(caseRoot,relativeDir);
    for(const file of (await fs.readdir(dir)).filter(x=>x.endsWith('.mmd')).sort()) {
     count++;
     const source=path.join(dir,file),id=`${family}-${path.basename(dir)}-${file.slice(0,-4)}`;
     const row={id,family,source,errors:[],profiles:{}}; results.push(row);
     try {
      const bytes=await fs.readFile(source), record=JSON.parse(await fs.readFile(source.replace(/\.mmd$/,'.oracle.json'),'utf8'));
      if(record.key!==keyOf(prov,bytes))throw new Error('stale oracle record');
      const ref=record.accepted?normalizeReference(record,file.slice(0,-4)): {accepted:false};
      row.reference_accepted=record.accepted;
      row.reference_geometry_counts=Object.fromEntries(['nodes','edges','groups','labels'].map(k=>[k,ref.geometry?.[k]?.length??0]));
      const empty=path.join(outDir,`${id}.empty.tsv`),sized=path.join(outDir,`${id}.sizes.tsv`);
      await fs.writeFile(empty,'');
      const sizes=[...(ref.geometry?.nodes??[]).map(x=>['node',x.id,x.box.width,x.box.height]),...(ref.geometry?.labels??[]).filter(x=>x.size_kind!=='output'&&x.measurement!==false).map(x=>[x.size_kind??'label',x.id,(x.input_box??x.box).width,(x.input_box??x.box).height]),...(ref.measurements??[]).map(x=>[x.kind,x.id,x.width,x.height])];
      for(const s of sizes)if(s.some(x=>String(x).includes('\t')||String(x).includes('\n')))throw new Error('unrepresentable reference size id');
      await fs.writeFile(sized,sizes.map(x=>x.join('\t')).join('\n'));
      if(typeof record.accepted!=='boolean')throw new Error(`oracle failure, not a parser rejection: ${record.error??record.accepted}`);
      const profileDefs=record.accepted?[['default',empty],['reference',empty],['sized',sized]]:[['default',empty]];
      let referenceSvg;
      if(record.accepted && !ref.unsupported) {
       const live=await browser.extract(record.source);
       if(!live.svg) {
        if(family==='flowchart' && record.flowchart?.nodes.some(n=>n.shape==='ellipse') && /No such shape: ellipse/.test(live.render_error??live.error??'')) row.reference_render_failure={reason:'Pinned Mermaid cannot render its parsed ellipse shape; documented supported extension.',error:live.render_error??live.error};
        else throw new Error(`reference did not render: ${live.render_error??live.error??'missing SVG'}`);
       } else {referenceSvg=live.svg;await fs.writeFile(path.join(outDir,`${id}.mermaid.svg`),referenceSvg);}
      }
      for(const [profile,sizefile] of profileDefs) {
       const base=path.join(outDir,`${id}.${profile}`),jsonfile=`${base}.json`,svgfile=`${base}.svg`;
       await fs.rm(jsonfile,{force:true}); await fs.rm(svgfile,{force:true});
       run(binary,[family,profile==='default'?'default':'reference',source,sizefile,jsonfile,svgfile]);
       const actual=JSON.parse(await fs.readFile(jsonfile,'utf8'));
       let publicAccepted;
       try {publicAccepted=(await fs.stat(svgfile)).isFile();} catch(error){if(error.code==='ENOENT')publicAccepted=false;else throw error;}
       const outcome={accepted:actual.accepted,public_accepted:publicAccepted};row.profiles[profile]=outcome;
       if(actual.accepted!==publicAccepted)row.errors.push({profile,why:'inspector and public SVG acceptance differ',inspector:actual.accepted,public:publicAccepted});
       if(actual.size_problems?.length)row.errors.push({profile,why:'invalid or unconsumed size overrides',problems:actual.size_problems});
       if(actual.accepted!==record.accepted && !ref.unsupported)row.errors.push({profile,why:'acceptance mismatch',expected:record.accepted,actual:actual.accepted});
       if(ref.unsupported && (actual.accepted || actual.unsupported!==true))row.errors.push({profile,why:'explicitly unsupported scope must report Unsupported'});
       if(!record.accepted || ref.unsupported)continue;
       if(!actual.accepted)continue;
       const publicSvg=await fs.readFile(svgfile,'utf8');
       if(!viewBoxOf(publicSvg))throw new Error(`public SVG missing finite viewbox for ${profile}`);
       outcome.semantic_differences=differences(ref.semantic,actual.semantic);
       if(outcome.semantic_differences.length)row.errors.push({profile,why:'semantic mismatch',count:outcome.semantic_differences.length});
       outcome.geometry_differences=geometryDifferences(ref.geometry,actual.geometry);
       const alignment=outcome.geometry_differences.filter(d=>d.why==='missing box'&&d.kind!=='labels'||d.why==='missing route'||d.field==='from'||d.field==='to');
       if(ref.geometry && alignment.length)row.errors.push({profile,why:'geometry output alignment mismatch',differences:alignment});
       if(profile==='sized'&&ref.geometry){const errors=outcome.geometry_differences.filter(d=>d.kind==='nodes'||d.kind==='groups');if(errors.length)row.errors.push({profile,why:'isolated layout exceeds one CSS pixel',differences:errors});}
       outcome.layout=layoutMetrics(ref.geometry,actual.geometry);
       if(family==='flowchart' && record.layout?.nodes)outcome.flow_quality=scoreCase(record,{...actual.geometry,bounds:actual.geometry.view_box});
       if(profile==='sized'&&outcome.flow_quality){const q=outcome.flow_quality;if(q.layer!==1||q.rank!==1||q.order!==1||q.cross_ours>q.cross_theirs)row.errors.push({profile,why:'flow layout structural quality differs from oracle',quality:q});}
       const nonfinite=[...nonFinite(actual),...invalidGeometry(actual.geometry)];
       if(nonfinite.length)row.errors.push({profile,why:'nonfinite or missing numeric geometry',paths:nonfinite});
       if(profile==='default' && referenceSvg) {
        const svg=await fs.readFile(svgfile,'utf8'),box=viewBoxOf(svg),refbox=viewBoxOf(referenceSvg);
        if(!box||!refbox)throw new Error('missing or nonfinite viewbox');
        const pixel=await compare(raster.page,referenceSvg,refbox,svg,box,{maxShift:4});
        await writePng(`${base}.png`,pixel.png);
        const {png,...metrics}=pixel;
        outcome.pixels=metrics;
        outcome.rendered_text=await renderedTextDifferences(raster.page);
        if(family!=='flowchart'&&(outcome.rendered_text.missing.length||outcome.rendered_text.extra.length))row.errors.push({profile,why:'rendered text differs from reference',differences:outcome.rendered_text});
        row.errors.push(...parityProblems(family,metrics.score,box,refbox).map(problem=>({profile,...problem})));
        outcome.view_box={expected:refbox,actual:box,width_ratio:box.width/refbox.width,height_ratio:box.height/refbox.height};
       }
      }
      row.unsupported=ref.unsupported??false;
     } catch(error) {row.errors.push({why:String(error.stack??error)});}
     if(row.errors.length)failures.push(id);
     console.log(`${id}: ${row.errors.length?'FAIL':row.unsupported?'UNSUPPORTED':'compared'}${row.profiles.default?.pixels?` pixels ${(row.profiles.default.pixels.score*100).toFixed(2)}%`:''}`);
    }
   }
   if(!count)failures.push(`${family}: zero coverage`);
   if(!results.slice(familyStart).some(r=>r.reference_accepted && !r.unsupported && r.profiles.default?.accepted && r.profiles.default?.pixels))failures.push(`${family}: zero rendered comparisons`);
  }
 } finally {await browser.close();await raster.close();}
 const native={binary:path.basename(binary),sha256:createHash('sha256').update(await fs.readFile(binary)).digest('hex')};
 const comparison_tools={};
 for(const file of ['validate.mjs','raster.mjs','contracts.mjs','model.mjs',...selected.map(f=>`families/${f}.mjs`)])comparison_tools[file]=createHash('sha256').update(await fs.readFile(new URL(file,import.meta.url))).digest('hex');
 const report={schema:1,provenance:prov,native,comparison_tools,criteria:{semantics:'exact',raster:{css_pixels_per_svg_unit:1,device_scale:2,spatial_tolerance_css_px:1,color_tolerance_per_channel:40},rendered_text:'exact token multiset for new families',geometry_tolerance_css_px:1,isolated_geometry_gate:'node and group boxes within one CSS pixel',flow_quality_gate:'same layers/ranks/order; no additional crossings',pixels:{sequence:0.05,entity:0.05,class:0.05,state:0.05,flowchart:'reported with isolated layout quality; deliberate text rendering extensions retained'},view_dimension_tolerance_css_px:1},summary:{cases:results.length,failed:failures.length,failures},results};
 await write(path.join(outDir,'report.json'),report);
 if(!results.length)throw new Error('zero cases compared');
 if(failures.length&&!flags.includes('--report-only'))process.exitCode=1;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await main();
