import { expectedOutcome } from '../model.mjs';

// Source semantics come from the pinned parser. Measurement controls use
// Mermaid's actual production layout object, never final group dimensions.
export function normalizeReference(record, name = '') {
 const expected = expectedOutcome(record, name);
 if (expected.outcome !== 'Accepted') return { accepted: false, unsupported: expected.outcome === 'Unsupported' };
 const g = record.layout;
 const inputNodes = new Map((record.measured_input?.nodes??[]).map(n=>[n.id,n]));
 const inputEdges = new Map((record.measured_input?.edges??[]).map(e=>[e.id,e]));
 const measurements = (record.measured_input?.nodes??[]).filter(n=>n.isGroup && n.labelBBox).map(n=>({kind:'group',id:n.id,width:n.labelBBox.width,height:n.labelBBox.height}));
 return { semantic: expected.diagram, measurements, geometry: g ? {
  view_box:g.view_box,
  nodes:g.nodes.map(n=>{
   const measured=inputNodes.get(n.id);
   const width=measured?.width??n.box.width,height=measured?.height??n.box.height;
   return {id:n.id,box:{x:n.center.x-width/2,y:n.center.y-height/2,width,height}};
  }),
  groups:g.clusters.map(n=>({id:n.id,box:n.box})),
  edges:g.edges.map((e,i)=>({id:e.id,from:record.flowchart.edges[i].from,to:record.flowchart.edges[i].to,points:e.points})),
  labels:g.edges.filter(e=>e.label).map(e=>{
   const measured=inputEdges.get(e.id);
   const box={x:e.label.x+2,y:e.label.y+2,width:e.label.width-4,height:e.label.height-4};
   return {id:e.id,text:record.flowchart.edges[g.edges.indexOf(e)]?.label??'',box,input_box:{width:measured?measured.width-4:box.width,height:measured?measured.height-4:box.height}};
  }),
 } : null };
}
