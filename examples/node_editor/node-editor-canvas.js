const Geometry = globalThis.NodeEditorGeometry;
const EMPTY_PAYLOAD = Object.freeze({
  node:0, edge:0, from:0, to:0, source_port:'', target_port:'',
  port_id:'', role:'', side:'', color:'#7895dd', placement:'center',
  x:0, y:0, width:0, height:0, label_width:0, label_height:0,
  label:'', algorithm:'', direction:'', document:'',
});

export class NodeEditorCanvas extends HTMLElement {
  constructor() {
    super();
    this.selected = new Set();
    this.selectedEdges = new Set();
    this.drag = null;
    this.connection = null;
    this.history = [];
    this.future = [];
    this.routeStyle = localStorage.getItem('node-editor-route-style') ?? 'rounded';
    this.theme = localStorage.getItem('node-editor-theme') ?? 'system';
    this.diagnosticsVisible = localStorage.getItem('node-editor-diagnostics') === 'true';
    this.viewport = { x:0, y:0, scale:1 };
    this.events = [];
    this.session = crypto.randomUUID?.() ?? String(Date.now());
    this.observer = new MutationObserver(mutations => {
      const external = mutations.some(mutation => !mutation.target.closest?.('#layers,#diagnostics'));
      if (external) this.refresh();
    });
    this.onKeyDown = event => this.keyDown(event);
    this.onInspectorChange = event => this.inspectorChanged(event);
    this.onInspectorClick = event => this.inspectorClicked(event);
    this.onBrowserOffline = () => this.setServerAvailable(false);
    this.serverAvailable = true;
  }

  connectedCallback() {
    if (this.initialized) return;
    this.initialized = true;
    this.addEventListener('pointerdown', event => this.pointerDown(event));
    this.addEventListener('pointermove', event => this.pointerMove(event));
    this.addEventListener('pointerup', event => this.pointerUp(event));
    this.addEventListener('pointercancel', event => this.pointerCancel(event));
    this.addEventListener('wheel', event => this.wheel(event), { passive:false });
    document.addEventListener('keydown', this.onKeyDown);
    document.addEventListener('change', this.onInspectorChange);
    document.addEventListener('click', this.onInspectorClick);
    globalThis.addEventListener('offline', this.onBrowserOffline);
    this.observer.observe(this, {
      childList:true, subtree:true, attributes:true,
      attributeFilter:['class','data-points','data-layers','data-arrangement','data-direction','data-x','data-y','data-width','data-height'],
    });
    this.viewportObserver = new ResizeObserver(() => this.resizeSurface());
    this.viewportObserver.observe(this.closest('#viewport'));
    const routeSelect=document.querySelector('#route-style');if(routeSelect)routeSelect.value=this.routeStyle;
    this.setTheme(this.theme);
    this.setDiagnostics(this.diagnosticsVisible);
    this.refresh();
    this.checkServer();
    this.healthTimer = globalThis.setInterval(() => this.checkServer(), 2000);
    this.debug('session-start', { routeStyle:this.routeStyle });
    globalThis.nodeEditorDebug = {
      reproduction: () => ({
        version:2, capturedAt:new Date().toISOString(), session:this.session,
        revision:this.workspace()?.dataset.revision, document:this.document(),
        selection:{nodes:[...this.selected],edges:[...this.selectedEdges]}, viewport:{...this.viewport}, events:[...this.events],
      }),
      dump: () => JSON.stringify(globalThis.nodeEditorDebug.reproduction(), null, 2),
      copy: async () => {
        const value = globalThis.nodeEditorDebug.dump();
        await navigator.clipboard.writeText(value);
        return value;
      },
      clear: () => { this.events.length = 0; },
    };
  }

  disconnectedCallback() {
    document.removeEventListener('keydown', this.onKeyDown);
    document.removeEventListener('change', this.onInspectorChange);
    document.removeEventListener('click', this.onInspectorClick);
    globalThis.removeEventListener('offline', this.onBrowserOffline);
    globalThis.clearInterval(this.healthTimer);
    this.viewportObserver?.disconnect();
    this.observer.disconnect();
    this.initialized = false;
  }

  workspace() { return this.closest('#workspace'); }
  document() {
    try { return JSON.parse(this.workspace()?.dataset.document ?? '{}'); }
    catch { return {}; }
  }
  nodes() {
    return [...this.querySelectorAll('.node')].map(element => ({
      id:Number(element.dataset.nodeId), x:Number(element.style.left.replace('px','')),
      y:Number(element.style.top.replace('px','')), width:Number(element.style.width.replace('px','')),
      height:Number(element.style.height.replace('px','')),
      ports:[...element.querySelectorAll('.port')].map(port => ({
        id:port.dataset.portId, role:port.dataset.role, side:port.dataset.side,
        offset:Number(port.dataset.offset),
      })),
    }));
  }
  nodeElement(id) { return this.querySelector(`.node[data-node-id="${id}"]`); }

  debug(type, details={}) {
    const entry = { time:new Date().toISOString(), session:this.session, type, ...details };
    this.events.push(entry);
    if (this.events.length > 300) this.events.shift();
    console.info('[node-editor]', entry);
  }

  async checkServer() {
    try {
      const response = await fetch('/health', { cache:'no-store', signal:AbortSignal.timeout(1500) });
      this.setServerAvailable(response.ok);
    } catch { this.setServerAvailable(false); }
  }
  setServerAvailable(available) {
    if (this.serverAvailable === available && document.body.dataset.serverState) return;
    this.serverAvailable = available;
    document.body.dataset.serverState = available ? 'online' : 'offline';
    document.body.classList.toggle('server-offline', !available);
    const status = document.querySelector('#status');
    const revision = this.workspace()?.dataset.revision;
    if (status) status.textContent = available && revision ? `Revision ${revision} synchronized.` : available ? 'Connected · synchronizing…' : 'Server unavailable · changes are paused; reconnecting…';
    this.debug(available ? 'server-connected' : 'server-disconnected');
  }

  payload(extra={}) { return { ...EMPTY_PAYLOAD, ...extra }; }
  requestCommand(kind, extra={}, options={}) {
    if (!this.serverAvailable) {
      this.setServerAvailable(false);
      this.debug('command-paused', { kind });
      return false;
    }
    const document = this.document();
    if (!options.history && kind !== 'replace-document' && Object.keys(document).length) {
      this.history.push(JSON.stringify(document));
      if (this.history.length > 100) this.history.shift();
      this.future.length = 0;
    }
    const operationId = `${this.session}:${crypto.randomUUID?.() ?? Date.now()}`;
    const payload = this.payload(extra);
    this.debug('command', { kind, operationId, revision:this.workspace()?.dataset.revision, payload });
    this.dispatchEvent(new CustomEvent('node-editor-command', {
      bubbles:true, detail:{ kind, operationId, payload },
    }));
    return true;
  }
  undo() {
    const previous = this.history.pop();
    if (!previous) return;
    this.future.push(JSON.stringify(this.document()));
    this.requestCommand('replace-document', { document:previous }, { history:true });
    this.debug('undo');
  }
  redo() {
    const next = this.future.pop();
    if (!next) return;
    this.history.push(JSON.stringify(this.document()));
    this.requestCommand('replace-document', { document:next }, { history:true });
    this.debug('redo');
  }

  setRouteStyle(style) {
    this.routeStyle = style === 'angular' ? 'angular' : 'rounded';
    localStorage.setItem('node-editor-route-style', this.routeStyle);
    this.refreshRoutes();
  }
  setTheme(theme) {
    this.theme = ['light','dark'].includes(theme) ? theme : 'system';
    localStorage.setItem('node-editor-theme', this.theme);
    document.documentElement.dataset.theme = this.theme;
    const select=document.querySelector('#theme');if(select)select.value=this.theme;
    this.debug('theme-changed', { theme:this.theme });
  }
  setDiagnostics(visible) {
    this.diagnosticsVisible = Boolean(visible);
    localStorage.setItem('node-editor-diagnostics', String(this.diagnosticsVisible));
    document.body.classList.toggle('diagnostics-visible', this.diagnosticsVisible);
    const button=document.querySelector('#diagnostics-toggle');
    if(button){button.textContent=this.diagnosticsVisible?'Hide diagnostics':'Show diagnostics';button.setAttribute('aria-pressed',String(this.diagnosticsVisible));}
    this.refreshDiagnostics();
  }

  refresh() {
    for (const node of this.querySelectorAll('.node')) {
      node.classList.toggle('selected', this.selected.has(Number(node.dataset.nodeId)));
    }
    for (const edge of this.querySelectorAll('.edge')) {
      edge.classList.toggle('selected', this.selectedEdges.has(Number(edge.dataset.edgeId)));
    }
    this.refreshRoutes();
    this.refreshDiagnostics();
    this.resizeSurface();
  }
  refreshRoutes() {
    for (const path of this.querySelectorAll('.route[data-points]')) {
      try { path.setAttribute('d', Geometry.routePath(Geometry.shortenTarget(JSON.parse(path.dataset.points)), this.routeStyle)); }
      catch { path.setAttribute('d', ''); }
      path.classList.toggle('rounded', this.routeStyle === 'rounded');
      path.classList.toggle('angular', this.routeStyle === 'angular');
    }
  }
  refreshLayers() {
    const layerRoot = this.querySelector('#layers');
    if (!layerRoot) return;
    if (!this.diagnosticsVisible || this.dataset.arrangement !== 'layered') {
      layerRoot.replaceChildren();
      return;
    }
    let layers = [];
    try { layers = JSON.parse(this.dataset.layers ?? '[]'); } catch {}
    const nodes = this.nodes();
    const horizontal = ['down','up'].includes(this.dataset.direction);
    const groups = new Map();
    nodes.forEach((node,index) => {
      const layer = layers[index];
      if (layer === undefined) return;
      const group = groups.get(layer) ?? [];
      group.push(node); groups.set(layer, group);
    });
    const bands = [...groups].map(([layer,items]) => ({
      layer, coordinate:items.reduce((sum,node)=>sum+(horizontal?node.y:node.x),0)/items.length,
    })).sort((a,b)=>a.coordinate-b.coordinate);
    layerRoot.replaceChildren(...bands.map((band,index) => {
      const before=bands[index-1], after=bands[index+1];
      const start=before?(before.coordinate+band.coordinate)/2:band.coordinate-70;
      const end=after?(band.coordinate+after.coordinate)/2:band.coordinate+70;
      const element=document.createElement('div');
      element.className=`layer-band ${horizontal?'horizontal':'vertical'}`;
      element.textContent=`Layer ${band.layer+1}`;
      if(horizontal){element.style.top=`${start}px`;element.style.height=`${end-start}px`;}
      else{element.style.left=`${start}px`;element.style.width=`${end-start}px`;}
      return element;
    }));
  }
  refreshDiagnostics() {
    this.refreshLayers();
    let root=this.querySelector('#diagnostics');
    if(!root){root=document.createElementNS('http://www.w3.org/2000/svg','svg');root.id='diagnostics';this.querySelector('#routes')?.before(root);}
    if(!this.diagnosticsVisible){root.replaceChildren();return;}
    const svg=(name,attributes={})=>{const element=document.createElementNS('http://www.w3.org/2000/svg',name);for(const [key,value] of Object.entries(attributes))element.setAttribute(key,String(value));return element;};
    const items=[];
    for(const node of this.nodes()){
      items.push(svg('rect',{class:'diagnostic-clearance',x:node.x-node.width/2-24,y:node.y-node.height/2-24,width:node.width+48,height:node.height+48,rx:18}));
      items.push(svg('rect',{class:'diagnostic-node',x:node.x-node.width/2,y:node.y-node.height/2,width:node.width,height:node.height,rx:12}));
      const label=svg('text',{class:'diagnostic-label',x:node.x-node.width/2+6,y:node.y-node.height/2-28});label.textContent=`Node ${node.id}`;items.push(label);
    }
    for(const route of this.querySelectorAll('.route[data-points]')){
      let points=[];try{points=JSON.parse(route.dataset.points);}catch{}
      if(points.length>1){
        items.push(svg('line',{class:'diagnostic-terminal',x1:points[0].x,y1:points[0].y,x2:points[1].x,y2:points[1].y}));
        items.push(svg('line',{class:'diagnostic-terminal',x1:points.at(-2).x,y1:points.at(-2).y,x2:points.at(-1).x,y2:points.at(-1).y}));
      }
      points.forEach((point,index)=>items.push(svg('circle',{class:index===0||index===points.length-1?'diagnostic-attachment':'diagnostic-bend',cx:point.x,cy:point.y,r:index===0||index===points.length-1?4:3})));
    }
    root.replaceChildren(...items);
  }
  resizeSurface() {
    const nodes=this.nodes();
    const viewport=this.closest('#viewport');
    const maxX=nodes.length?Math.max(...nodes.map(n=>n.x+n.width/2))+240:0;
    const maxY=nodes.length?Math.max(...nodes.map(n=>n.y+n.height/2))+180:0;
    const visibleWidth=(viewport?.clientWidth??0)/this.viewport.scale+Math.max(0,-this.viewport.x)/this.viewport.scale;
    const visibleHeight=(viewport?.clientHeight??0)/this.viewport.scale+Math.max(0,-this.viewport.y)/this.viewport.scale;
    const width=`${Math.max(1100,maxX,visibleWidth)}px`,height=`${Math.max(720,maxY,visibleHeight)}px`;
    if(this.style.width!==width)this.style.width=width;
    if(this.style.height!==height)this.style.height=height;
    this.applyViewport();
  }
  applyViewport() {
    this.style.transformOrigin='0 0';
    this.style.transform=`translate(${this.viewport.x}px,${this.viewport.y}px) scale(${this.viewport.scale})`;
  }
  canvasPoint(event) {
    const viewport=this.closest('#viewport').getBoundingClientRect();
    return {
      x:(event.clientX-viewport.left-this.viewport.x)/this.viewport.scale,
      y:(event.clientY-viewport.top-this.viewport.y)/this.viewport.scale,
    };
  }

  select(ids, edges=[]) {
    this.selected = new Set(ids);
    this.selectedEdges = new Set(edges);
    this.refresh();
    this.dispatchEvent(new CustomEvent('node-editor-selection',{bubbles:true,detail:{ids:[...this.selected],edges:[...this.selectedEdges]}}));
  }

  pointerDown(event) {
    const resize=event.target.closest('[data-resize-node]');
    if(resize){ this.startResize(event,resize.closest('.node')); return; }
    const port=event.target.closest('.port');
    if(port){ this.startConnection(event,port); return; }
    const node=event.target.closest('.node');
    if(node){ this.startNodeDrag(event,node); return; }
    const edge=event.target.closest('.edge[data-edge-id]');
    if(edge){event.preventDefault();event.stopPropagation();this.select([],[Number(edge.dataset.edgeId)]);return;}
    const point=this.canvasPoint(event);
    this.select([]);
    this.setPointerCapture(event.pointerId);
    if(event.shiftKey){
      this.drag={kind:'select',pointerId:event.pointerId,start:point,current:point};
      this.selectionBox(point,point);
    }else{
      this.drag={kind:'pan',pointerId:event.pointerId,startClient:{x:event.clientX,y:event.clientY},origin:{...this.viewport}};
      this.classList.add('panning');
    }
  }
  startNodeDrag(event,node) {
    event.preventDefault();
    const id=Number(node.dataset.nodeId);
    if(event.shiftKey){
      const next=new Set(this.selected); next.has(id)?next.delete(id):next.add(id); this.select(next); return;
    }
    if(!this.selected.has(id))this.select([id]);
    const point=this.canvasPoint(event);
    const originals=new Map([...this.selected].map(nodeId=>{
      const element=this.nodeElement(nodeId);
      return [nodeId,{x:Number(element.dataset.x),y:Number(element.dataset.y)}];
    }));
    node.setPointerCapture(event.pointerId);
    this.drag={kind:'nodes',pointerId:event.pointerId,start:point,originals,before:JSON.stringify(this.document())};
    this.classList.add('dragging');
    this.debug('drag-start',{nodes:[...this.selected],from:Object.fromEntries(originals)});
  }
  startResize(event,node) {
    event.preventDefault(); event.stopPropagation();
    node.setPointerCapture(event.pointerId);
    this.drag={kind:'resize',pointerId:event.pointerId,node:Number(node.dataset.nodeId),start:this.canvasPoint(event),width:Number(node.dataset.width),height:Number(node.dataset.height),before:JSON.stringify(this.document())};
    this.classList.add('resizing');
  }
  startConnection(event,port) {
    event.preventDefault(); event.stopPropagation();
    if(port.dataset.role!=='output'){
      this.debug('connect-invalid',{reason:'input-cannot-start',port:port.dataset.portId});
      return;
    }
    port.setPointerCapture(event.pointerId);
    const node=port.closest('.node');
    this.connection={pointerId:event.pointerId,from:Number(node.dataset.nodeId),source_port:port.dataset.portId};
    this.classList.add('connecting');
    this.drawConnection(this.canvasPoint(event),event);
  }

  pointerMove(event) {
    if(this.connection?.pointerId===event.pointerId){this.drawConnection(this.canvasPoint(event),event);return;}
    if(!this.drag||this.drag.pointerId!==event.pointerId)return;
    if(this.drag.kind==='pan'){
      this.viewport.x=this.drag.origin.x+event.clientX-this.drag.startClient.x;
      this.viewport.y=this.drag.origin.y+event.clientY-this.drag.startClient.y;
      this.applyViewport(); return;
    }
    const point=this.canvasPoint(event);
    if(this.drag.kind==='select'){this.drag.current=point;this.selectionBox(this.drag.start,point);return;}
    if(this.drag.kind==='nodes'){
      const dx=point.x-this.drag.start.x,dy=point.y-this.drag.start.y;
      for(const [id,origin] of this.drag.originals){
        const node=this.nodeElement(id);node.style.left=`${origin.x+dx}px`;node.style.top=`${origin.y+dy}px`;
      }
      this.previewIncidentRoutes(); return;
    }
    if(this.drag.kind==='resize'){
      const node=this.nodeElement(this.drag.node);
      node.style.width=`${Math.max(96,Math.min(480,this.drag.width+point.x-this.drag.start.x))}px`;
      node.style.height=`${Math.max(52,Math.min(320,this.drag.height+point.y-this.drag.start.y))}px`;
      this.previewIncidentRoutes();
    }
  }
  pointerUp(event) {
    if(this.connection?.pointerId===event.pointerId){this.finishConnection(event);return;}
    if(!this.drag||this.drag.pointerId!==event.pointerId)return;
    const drag=this.drag;this.drag=null;this.classList.remove('dragging','resizing','panning');
    if(drag.kind==='pan')return;
    if(drag.kind==='select'){
      const a=drag.start,b=drag.current;
      const left=Math.min(a.x,b.x),right=Math.max(a.x,b.x),top=Math.min(a.y,b.y),bottom=Math.max(a.y,b.y);
      this.select(this.nodes().filter(n=>n.x+n.width/2>=left&&n.x-n.width/2<=right&&n.y+n.height/2>=top&&n.y-n.height/2<=bottom).map(n=>n.id));
      this.hideSelectionBox();return;
    }
    if(drag.kind==='resize'){
      const node=this.nodeElement(drag.node);
      this.history.push(drag.before);this.future.length=0;
      this.requestCommand('resize-node',{node:drag.node,width:parseFloat(node.style.width),height:parseFloat(node.style.height)},{history:true});
      return;
    }
    const current=this.document();
    const moved=[...drag.originals].map(([id,from])=>{
      const node=this.nodeElement(id);return{id,from,to:{x:parseFloat(node.style.left),y:parseFloat(node.style.top)}};
    });
    this.history.push(drag.before);this.future.length=0;
    if(moved.length===1){
      const move=moved[0];this.requestCommand('move-node',{node:move.id,x:move.to.x,y:move.to.y},{history:true});
    }else{
      current.nodes=current.nodes.map(node=>{const move=moved.find(item=>item.id===node.id);return move?{...node,...move.to}:node;});
      current.arrangement='free';current.layers=[];current.guides=[];
      this.requestCommand('replace-document',{document:JSON.stringify(current)},{history:true});
    }
    this.debug('drag-end',{moved});
  }
  pointerCancel() {
    this.drag=null;this.connection=null;this.classList.remove('dragging','resizing','panning','connecting');
    this.hideSelectionBox();this.removeConnectionPreview();this.refresh();
  }

  previewIncidentRoutes() {
    const nodes=this.nodes();
    for(const path of this.querySelectorAll('.route')){
      const edge={from:Number(path.dataset.from),to:Number(path.dataset.to),source_port:path.dataset.sourcePort??'out',target_port:path.dataset.targetPort??'in'};
      if(!this.selected.has(edge.from)&&!this.selected.has(edge.to)&&this.drag?.node!==edge.from&&this.drag?.node!==edge.to)continue;
      const points=Geometry.previewRoute(edge,nodes);
      path.setAttribute('d',Geometry.routePath(Geometry.shortenTarget(points),this.routeStyle));
    }
    this.refreshDiagnostics();
  }
  drawConnection(point,event) {
    const nodes=this.nodes(),source=nodes.find(node=>node.id===this.connection.from);
    if(!source)return;
    const target={id:-1,x:point.x,y:point.y,width:0,height:0,ports:[{id:'in',role:'input',side:'left',offset:.5}]};
    let preview=this.querySelector('.connection-preview');
    if(!preview){preview=document.createElementNS('http://www.w3.org/2000/svg','path');preview.classList.add('route','connection-preview');this.querySelector('#routes')?.append(preview);}
    preview.setAttribute('d',Geometry.routePath(Geometry.previewRoute({from:source.id,to:-1,source_port:this.connection.source_port,target_port:'in'},[...nodes,target]),'rounded'));
    const candidate=document.elementFromPoint(event.clientX,event.clientY)?.closest?.('.port.input');
    const hovered=candidate&&this.inputAvailable(candidate)?candidate:null;
    for(const port of this.querySelectorAll('.port.input')){
      const available=this.inputAvailable(port);
      port.classList.toggle('unavailable',!available);
      port.classList.toggle('valid-target',port===hovered);
    }
  }
  finishConnection(event) {
    const connection=this.connection;this.connection=null;this.classList.remove('connecting');this.removeConnectionPreview();
    const candidate=document.elementFromPoint(event.clientX,event.clientY)?.closest?.('.port.input');
    const target=candidate&&this.inputAvailable(candidate)?candidate:null;
    if(!target){this.debug('connect-cancel',{from:connection.from});return;}
    this.requestCommand('add-edge',{from:connection.from,to:Number(target.closest('.node').dataset.nodeId),source_port:connection.source_port,target_port:target.dataset.portId});
  }
  removeConnectionPreview(){this.querySelector('.connection-preview')?.remove();for(const port of this.querySelectorAll('.valid-target'))port.classList.remove('valid-target');}
  inputAvailable(port){
    const node=Number(port.closest('.node')?.dataset.nodeId),id=port.dataset.portId;
    return !(this.document().edges??[]).some(edge=>edge.to===node&&edge.target_port===id);
  }

  selectionBox(a,b){
    const box=this.querySelector('.selection-box');if(!box)return;
    box.hidden=false;box.style.left=`${Math.min(a.x,b.x)}px`;box.style.top=`${Math.min(a.y,b.y)}px`;box.style.width=`${Math.abs(a.x-b.x)}px`;box.style.height=`${Math.abs(a.y-b.y)}px`;
  }
  hideSelectionBox(){const box=this.querySelector('.selection-box');if(box)box.hidden=true;}
  wheel(event){
    event.preventDefault();
    const old=this.viewport.scale,next=Math.max(.35,Math.min(2.2,old*Math.exp(-event.deltaY*.001)));
    const rect=this.closest('#viewport').getBoundingClientRect(),cx=event.clientX-rect.left,cy=event.clientY-rect.top;
    this.viewport.x=cx-(cx-this.viewport.x)*next/old;this.viewport.y=cy-(cy-this.viewport.y)*next/old;this.viewport.scale=next;this.applyViewport();
  }
  keyDown(event){
    if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='z'){event.preventDefault();event.shiftKey?this.redo():this.undo();return;}
    if(event.key==='Delete'&&this.selectedEdges.size){
      const edge=[...this.selectedEdges][0];this.requestCommand('delete-edge',{edge});this.select([]);return;
    }
    if(event.key==='Delete'&&this.selected.size){
      const document=this.document(),ids=new Set(this.selected);
      document.nodes=document.nodes.filter(node=>!ids.has(node.id));document.edges=document.edges.filter(edge=>!ids.has(edge.from)&&!ids.has(edge.to));document.arrangement='free';document.layers=[];document.guides=[];
      this.requestCommand('replace-document',{document:JSON.stringify(document)});this.select([]);
    }
  }
  inspectorChanged(event){
    const input=event.target.closest?.('[data-node-label]');
    if(input){this.requestCommand('rename-node',{node:Number(input.dataset.nodeLabel),label:input.value});return;}
    const portEditor=event.target.closest?.('.port-editor');
    if(portEditor){
      this.requestCommand('update-port',{node:Number(portEditor.dataset.node),port_id:portEditor.dataset.port,label:portEditor.querySelector('[data-port-label]').value,role:portEditor.querySelector('[data-port-role]').value,side:portEditor.querySelector('[data-port-side]').value});return;
    }
    const edgeEditor=event.target.closest?.('.edge-editor');
    if(edgeEditor){
      const label=edgeEditor.querySelector('[data-edge-label]').value,metrics=this.labelMetrics(label);
      this.requestCommand('update-edge',{edge:Number(edgeEditor.dataset.edge),label,color:edgeEditor.querySelector('[data-edge-color]').value,placement:edgeEditor.querySelector('[data-edge-placement]').value,label_width:metrics.width,label_height:metrics.height});
    }
  }
  inspectorClicked(event){
    const deleteNode=event.target.closest?.('[data-delete-node]');
    if(deleteNode&&confirm('Delete this node and all of its connections?')){this.requestCommand('delete-node',{node:Number(deleteNode.dataset.node)});this.select([]);return;}
    const add=event.target.closest?.('[data-add-port]');
    if(add){this.requestCommand('add-port',{node:Number(add.dataset.node),role:add.dataset.addPort});return;}
    const move=event.target.closest?.('[data-move-port]');
    if(move){const editor=move.closest('.port-editor');this.requestCommand('move-port',{node:Number(editor.dataset.node),port_id:editor.dataset.port,direction:move.dataset.movePort});return;}
    const remove=event.target.closest?.('[data-delete-port]');
    if(remove){const editor=remove.closest('.port-editor');if(confirm('Delete this port and all of its connections?'))this.requestCommand('delete-port',{node:Number(editor.dataset.node),port_id:editor.dataset.port});return;}
    const reevaluate=event.target.closest?.('[data-reevaluate-port]');
    if(reevaluate){this.requestCommand('reevaluate-port',{node:Number(reevaluate.dataset.node),port_id:reevaluate.dataset.port});return;}
    const deleteEdge=event.target.closest?.('[data-delete-edge]');
    if(deleteEdge&&confirm('Delete this connection?')){this.requestCommand('delete-edge',{edge:Number(deleteEdge.dataset.edge)});this.select([]);}
  }
  labelMetrics(label){
    if(!label)return{width:0,height:0};
    const canvas=this.measureCanvas??=(document.createElement('canvas'));
    const context=canvas.getContext('2d');context.font='12px ui-sans-serif, system-ui, sans-serif';
    return{width:Math.min(1200,Math.ceil(context.measureText(label).width)+18),height:22};
  }
}

customElements.define('node-editor-canvas',NodeEditorCanvas);
