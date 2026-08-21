(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.NodeEditorGeometry=api;
})(globalThis,()=>{
  const cleanPoints=points=>points.filter((point,index)=>index===0||point.x!==points[index-1].x||point.y!==points[index-1].y);
  function routePath(points,style='angular'){
    const clean=cleanPoints(points);
    if(clean.length===0)return '';
    if(style==='angular'||clean.length<3)return `M ${clean.map(point=>`${point.x} ${point.y}`).join(' L ')}`;
    const commands=[`M ${clean[0].x} ${clean[0].y}`];
    for(let index=1;index<clean.length-1;index++){
      const previous=clean[index-1],corner=clean[index],next=clean[index+1];
      const before=Math.hypot(corner.x-previous.x,corner.y-previous.y),after=Math.hypot(next.x-corner.x,next.y-corner.y);
      const radius=Math.min(14,before/2,after/2);
      if(radius===0){commands.push(`L ${corner.x} ${corner.y}`);continue;}
      const entry={x:corner.x+(previous.x-corner.x)*radius/before,y:corner.y+(previous.y-corner.y)*radius/before};
      const exit={x:corner.x+(next.x-corner.x)*radius/after,y:corner.y+(next.y-corner.y)*radius/after};
      commands.push(`L ${entry.x} ${entry.y}`,`Q ${corner.x} ${corner.y} ${exit.x} ${exit.y}`);
    }
    const last=clean[clean.length-1];commands.push(`L ${last.x} ${last.y}`);
    return commands.join(' ');
  }
  function segmentCrossesNode(a,b,node,gap=0){
    const width=node.width??160,height=node.height??56;
    const left=node.x-width/2-gap,right=node.x+width/2+gap,top=node.y-height/2-gap,bottom=node.y+height/2+gap;
    const horizontal=a.y===b.y&&a.y>top&&a.y<bottom&&Math.max(Math.min(a.x,b.x),left)<Math.min(Math.max(a.x,b.x),right);
    const vertical=a.x===b.x&&a.x>left&&a.x<right&&Math.max(Math.min(a.y,b.y),top)<Math.min(Math.max(a.y,b.y),bottom);
    return horizontal||vertical;
  }
  const clearPreview=(points,edge,nodes)=>nodes.filter(node=>node.id!==edge.from&&node.id!==edge.to).every(node=>points.slice(0,-1).every((point,index)=>!segmentCrossesNode(point,points[index+1],node)));
  const portFor=(node,id,role)=>node?.ports?.find(port=>port.id===id)??node?.ports?.find(port=>port.role===role)??{side:role==='output'?'bottom':'top',offset:.5};
  function portPoint(node,port){
    const offset=Math.max(0,Math.min(1,port.offset??.5)),width=node.width??160,height=node.height??56;
    if(port.side==='left')return{x:node.x-width/2,y:node.y-height/2+height*offset};
    if(port.side==='right')return{x:node.x+width/2,y:node.y-height/2+height*offset};
    if(port.side==='bottom')return{x:node.x-width/2+width*offset,y:node.y+height/2};
    return{x:node.x-width/2+width*offset,y:node.y-height/2};
  }
  const outward=side=>side==='left'?{x:-1,y:0}:side==='right'?{x:1,y:0}:side==='bottom'?{x:0,y:1}:{x:0,y:-1};
  function previewRoute(edge,nodes){
    const source=nodes.find(node=>node.id===edge.from),target=nodes.find(node=>node.id===edge.to);
    if(!source||!target)return [];
    if(edge.from===edge.to)return [];
    const sourcePort=portFor(source,edge.source_port,'output'),targetPort=portFor(target,edge.target_port,'input');
    const start=portPoint(source,sourcePort),end=portPoint(target,targetPort),a=outward(sourcePort.side),b=outward(targetPort.side),escape=22;
    const ap={x:start.x+a.x*escape,y:start.y+a.y*escape},bp={x:end.x+b.x*escape,y:end.y+b.y*escape};
    const horizontalA=a.x!==0,horizontalB=b.x!==0;
    const candidates=[];
    if(horizontalA&&horizontalB){
      const middle=(ap.x+bp.x)/2;candidates.push([start,ap,{x:middle,y:ap.y},{x:middle,y:bp.y},bp,end]);
    }else if(!horizontalA&&!horizontalB){
      const middle=(ap.y+bp.y)/2;candidates.push([start,ap,{x:ap.x,y:middle},{x:bp.x,y:middle},bp,end]);
    }else if(horizontalA){
      candidates.push([start,ap,{x:bp.x,y:ap.y},bp,end]);
    }else{
      candidates.push([start,ap,{x:ap.x,y:bp.y},bp,end]);
    }
    const left=Math.min(...nodes.map(node=>node.x-(node.width??160)/2))-32;
    const right=Math.max(...nodes.map(node=>node.x+(node.width??160)/2))+32;
    const top=Math.min(...nodes.map(node=>node.y-(node.height??56)/2))-32;
    const bottom=Math.max(...nodes.map(node=>node.y+(node.height??56)/2))+32;
    candidates.push([start,ap,{x:left,y:ap.y},{x:left,y:bp.y},bp,end],[start,ap,{x:right,y:ap.y},{x:right,y:bp.y},bp,end],[start,ap,{x:ap.x,y:top},{x:bp.x,y:top},bp,end],[start,ap,{x:ap.x,y:bottom},{x:bp.x,y:bottom},bp,end]);
    return cleanPoints(candidates.find(points=>clearPreview(points,edge,nodes))??candidates[0]);
  }
  const displayedNodes=(nodes,drafts)=>nodes.map(node=>({...node,...(drafts.get(node.id)??{})}));
  const responseMatches=(latestOperation,responseOperation)=>latestOperation!==''&&latestOperation===responseOperation;
  return {cleanPoints,routePath,segmentCrossesNode,clearPreview,previewRoute,portPoint,displayedNodes,responseMatches};
});
