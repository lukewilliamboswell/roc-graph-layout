// Canonical facts from the pinned Mermaid SequenceDB and rendered DOM.
// No source parsing and no filtering based on our renderer's output.
import fs from 'node:fs';
const entitySource = fs.readFileSync(new URL('../../../package-mermaid/HtmlEntities.roc', import.meta.url), 'utf8');
const names = new Map([...entitySource.matchAll(/name: "([^"]+)", codepoints: \[([^\]]+)\]/g)].map(([,name,points]) => [name, String.fromCodePoint(...points.split(',').map(p=>Number(p.trim())))]));
export function display(value) {
 const text = String(value ?? '').replace(/ﬂ°°/g,'&#').replace(/ﬂ°/g,'&').replace(/¶ß/g,';').replace(/<br\s*\/?>/gi,'\n');
 return text.replace(/&(?:#(x[\da-f]+|\d+);?|([A-Za-z][A-Za-z0-9]*;?))/gi,(all,numeric,named)=>{
  if(numeric){let n=numeric[0].toLowerCase()==='x'?parseInt(numeric.slice(1),16):Number(numeric);return n>0&&n<=0x10ffff&&!(n>=0xd800&&n<=0xdfff)?String.fromCodePoint(n):'\ufffd';}
  return names.get(named)??all;
 });
}
const startTypes = new Map([[10,'loop'],[12,'alt'],[15,'opt'],[19,'par'],[27,'critical'],[30,'break']]);
const endTypes = new Map([[11,'loop'],[14,'alt'],[16,'opt'],[21,'par'],[29,'critical'],[31,'break']]);
const branches = new Map([[13,'else'],[20,'and'],[28,'option']]);
const arrows = new Map([[0,['arrow',false,false]],[1,['arrow',true,false]],[3,['cross',false,false]],[4,['cross',true,false]],[5,['none',false,false]],[6,['none',true,false]],[24,['open',false,false]],[25,['open',true,false]],[33,['arrow',false,true]],[34,['arrow',true,true]]]);
const union = boxes => {if(!boxes.length)return null;const x=Math.min(...boxes.map(b=>b.x)),y=Math.min(...boxes.map(b=>b.y));return{x,y,width:Math.max(...boxes.map(b=>b.x+b.width))-x,height:Math.max(...boxes.map(b=>b.y+b.height))-y}};
const numeric = value => Number.isFinite(Number(value))?Number(value):null;
export function normalizeReference(record) {
 const model=record.model??{}, rawActors=model.getActors??[], rawMessages=model.getMessages??[];
 const participants=rawActors.map(([id,a])=>({id,label:display(a.description??id),actor:a.type==='actor',wrap:!!a.wrap}));
 let autonumber=false;const events=[], messages=[],notes=[],controls=[];
 for(const m of rawMessages){
  const type=Number(m.type),text=display(m.message),wrap=!!m.wrap;
  if(arrows.has(type)){const[head,dotted,both]=arrows.get(type);events.push({kind:'message',from:m.from,to:m.to,text,head,dotted,both,activate:!!m.activate,wrap});messages.push(m);}
  else if(type===2){events.push({kind:'note',from:m.from,to:m.to,side:['left','right','over'][m.placement]??`unknown-${m.placement}`,text,wrap});notes.push(m);}
  else if(type===17||type===18)events.push({kind:type===17?'activate':'deactivate',participant:m.from});
  else if(startTypes.has(type)){events.push({kind:'start',block:startTypes.get(type),text,wrap});controls.push(m);}
  else if(branches.has(type)){events.push({kind:'branch',branch:branches.get(type),text,wrap});controls.push(m);}
  else if(endTypes.has(type)){events.push({kind:'end',block:endTypes.get(type)});}
  else if(type===26){autonumber=!!m.message.visible;events.push({kind:'numbering',visible:autonumber,start:m.message.start??null,step:m.message.step??null});}
  else events.push({kind:'unsupported',type,record:m});
 }
 const elements=record.rendering?.elements??[], attrs=e=>e.attributes??{}, hasClass=(e,c)=>String(e.class??'').split(/\s+/).includes(c);
 const participantElements=elements.filter(e=>attrs(e)['data-et']==='participant'&&(e.tag==='g'));
 const nodes=participants.map(p=>{
  const e=participantElements.find(e=>attrs(e)['data-id']===p.id);
  if(!p.actor)return{id:p.id,box:e?.box??null};
  // Neo actor glyphs carry the allocated header width/height on their
  // circle. These are genuine renderer inputs, distinct from glyph ink.
  const circle=elements.find(c=>c.tag==='circle'&&String(c.parent_class).includes('actor-top')&&c.box.y>=e.box.y-.01&&c.box.y+c.box.height<=e.box.y+e.box.height+.01&&Math.abs(Number(attrs(c).cx)-(e.box.x+e.box.width/2))<2);
  const life=elements.find(c=>attrs(c)['data-et']==='life-line'&&attrs(c)['data-id']===p.id);
  if(!circle||!life)return{id:p.id,box:null};
  const a=attrs(circle),width=Number(a.width),height=Number(a.height);
  return{id:p.id,box:{x:Number(a.cx)-width/2,y:Number(attrs(life).y1)-height,width,height}};
 });
 const messageElements=messages.map(m=>elements.find(e=>attrs(e)['data-et']==='message'&&attrs(e)['data-id']===`i${m.id}`));
 const edges=messages.map((m,index)=>{
  const e=messageElements[index],a=attrs(e??{});let points=[];
  if(e?.tag==='line')points=[{x:numeric(a.x1),y:numeric(a.y1)},{x:numeric(a.x2),y:numeric(a.y2)}];
  else if(e?.tag==='path'){const values=String(a.d??'').match(/[-+]?(?:\d*\.)?\d+(?:e[-+]?\d+)?/gi)?.map(Number)??[];for(let j=0;j+1<values.length;j+=2)points.push({x:values[j],y:values[j+1]});}
  return{id:`message-${index}`,from:m.from,to:m.to,points};
 });
 const labels=[];
 const texts=elements.filter(e=>e.tag==='text');
 const pushRows=(id,rows)=>rows.forEach((e,i)=>labels.push({id:rows.length===1?id:`${id}-row-${i}`,text:display(e.text).replace(/\u200b/g,''),box:e.box,measurement:!id.startsWith('participant-footer-')&&!id.startsWith('number-')&&!id.startsWith('block-kind-')&&id!=='title'}));
 // Header/footer rows are assigned by the actual participant column.
 for(const [index,p]of participants.entries()){
  const node=nodes[index].box;if(!node)continue;
  const own=texts.filter(e=>hasClass(e,'actor')&&Math.abs(e.box.x+e.box.width/2-(node.x+node.width/2))<2);
  pushRows(`participant-header-${p.id}`,own.filter(e=>e.box.y<node.y+node.height).sort((a,b)=>a.box.y-b.box.y));
  pushRows(`participant-footer-${p.id}`,own.filter(e=>e.box.y>=node.y+node.height).sort((a,b)=>a.box.y-b.box.y));
 }
 const compact=text=>display(text).replace(/\s|\u200b/g,'');
 const assignSourceRows=(prefix,source,rows,wrapped=false)=>{
  let cursor=0;
  for(let i=0;i<source.length;i++){
   const raw=display(source[i].message);if(!raw)continue;
   const expected=compact(wrapped?`[${raw}]`:raw);let actual='',picked=[];
   while(cursor<rows.length&&actual!==expected){const row=rows[cursor++];picked.push(row);actual+=compact(row.text);if(!expected.startsWith(actual))break;}
   pushRows(`${prefix}-${i}`,picked);
  }
  rows.slice(cursor).forEach((row,i)=>pushRows(`unassigned-${prefix}-${i}`,[row]));
 };
 assignSourceRows('message',messages,texts.filter(e=>hasClass(e,'messageText')));
 assignSourceRows('note',notes,texts.filter(e=>hasClass(e,'noteText')));
 const captions=texts.filter(e=>hasClass(e,'loopText')||hasClass(e,'sectionTitle')).sort((a,b)=>a.box.y-b.box.y);
 assignSourceRows('block',controls,captions,true);
 const starts=controls.map((m,index)=>({m,index})).filter(({m})=>startTypes.has(Number(m.type)));
 texts.filter(e=>hasClass(e,'labelText')).sort((a,b)=>a.box.y-b.box.y).forEach((e,i)=>pushRows(`block-kind-${starts[i]?.index??`unassigned-${i}`}`,[e]));
 texts.filter(e=>hasClass(e,'sequenceNumber')).forEach((e,i)=>pushRows(`number-${i}`,[e]));
 const title=display(model.getDiagramTitle??'');
 const titleElement=texts.find(e=>!e.class&&display(e.text)===title&&title);if(titleElement)pushRows('title',[titleElement]);
 // Four outer lines describe each frame; branch separators have inline
 // dash styles and are not input measurements or separate frames.
 const outline=elements.filter(e=>e.tag==='line'&&hasClass(e,'loopLine')&&!attrs(e).style);
 const frames=[];for(let i=0;i<outline.length;i+=4)frames.push(union(outline.slice(i,i+4).map(e=>e.box)));
 frames.sort((a,b)=>a.y-b.y);
 const groups=starts.map(({index},i)=>({id:`block-${index}`,box:frames[i]??null}));
 // Mermaid measures encoded placeholders before decoding painted text.
 // A decoded ink box is not the actual layout input for these labels.
 const encoded=[];
 participants.forEach((p,i)=>{if(String(rawActors[i][1].description??'').includes('ﬂ°'))encoded.push(`participant-header-${p.id}`)});
 messages.forEach((m,i)=>{if(String(m.message).includes('ﬂ°'))encoded.push(`message-${i}`)});
 notes.forEach((m,i)=>{if(String(m.message).includes('ﬂ°'))encoded.push(`note-${i}`)});
 controls.forEach((m,i)=>{if(String(m.message).includes('ﬂ°'))encoded.push(`block-${i}`)});
 labels.forEach(label=>{
  if(!encoded.some(id=>label.id===id||label.id.startsWith(`${id}-row-`)))return;
  const index=Number(/^message-(\d+)$/.exec(label.id)?.[1]),message=messages[index];
  const measured=message&&!message.wrap&&(record.measurements??[]).find(m=>m.kind==='sequence-message'&&m.id===String(message.id));
  if(measured)label.input_box={width:measured.width,height:Math.round(measured.height)};
  else label.measurement=false;
 });
 return {semantic:{participants,events,autonumber,title},geometry:{view_box:record.layout?.view_box??record.rendering?.view_box??null,nodes,edges,labels,groups}};
}
