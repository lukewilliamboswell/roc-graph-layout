// Class semantics come from the pinned DB's parsed members, not from our
// source parser or a hand-written approximation of Mermaid's grammar.
const direction = value => ({TB:'Down',TD:'Down',BT:'Up',LR:'Right',RL:'Left'}[value] ?? value);
const hasClass = (element, name) => element.class.split(/\s+/).includes(name);
const member = m => ({visibility:m.visibility,classifier:m.classifier,id:m.id,parameters:m.parameters??'',return_type:m.returnType??'',text:m.text.replace(/^\\/, '').replaceAll('&lt;','<').replaceAll('&gt;','>')});
const end = value => ({0:'Aggregation',1:'Inheritance',2:'Composition',3:'Association',4:'Link',none:'None'}[value] ?? value);
export function normalizeReference(record) {
    if (!record.accepted) return {semantic:null,geometry:null};
    const db = record.model;
    const relationships = db.getRelations.map(r => {
        const a=end(r.relation.type1),b=end(r.relation.type2);
        const marker=a==='None'?b:a;
        const dashed=r.relation.lineType===1;
        const kind=marker==='Inheritance'?(dashed?'Realization':'Inheritance'):marker==='Association'?(dashed?'Dependency':'Association'):marker==='None'||marker==='Link'?(dashed?'DottedLink':'Link'):marker;
        return {from:r.id1,to:r.id2,kind,reversed:a!=='None',bidirectional:a!=='None'&&b!=='None',label:r.title??'',from_multiplicity:r.relationTitle1==='none'?'':r.relationTitle1,to_multiplicity:r.relationTitle2==='none'?'':r.relationTitle2};
    });
    const semantic={direction:direction(db.getDirection||'TB'),classes:db.getClasses.map(([id,c])=>({id,label:c.label,generic_type:c.type,fields:c.members.map(member),methods:c.methods.map(member),annotations:c.annotations})),relationships};
    if(!record.rendering) return {semantic,geometry:null};
    const elements=record.rendering.elements;
    const nodes=db.getClasses.map(([id,c])=>{
        const group=elements.find(n=>n.tag==='g'&&hasClass(n,'node')&&(n.id===`oracle-${c.domId}`||new RegExp(`^oracle-classId-${id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-[0-9]+$`).test(n.id)));
        if(!group) throw new Error(`missing class node ${id}`);
        const outer=elements.find(n=>n.parent_id===group.id&&hasClass(n,'outer-path'));
        if(!outer) throw new Error(`missing class outline ${id}`);
        const measured = record.measured_input?.nodes.find(n => n.id === id);
        const width = measured?.width ?? group.box.width;
        const height = measured?.height ?? group.box.height;
        return {id,box:{x:group.origin.x-width/2,y:group.origin.y-height/2,width,height}};
    });
    const paths=elements.filter(e=>e.tag==='path'&&e.attributes['data-edge']==='true');
    if(paths.length!==relationships.length) throw new Error('class source-edge/path count differs');
    const edges=relationships.map((r,index)=>({id:String(index),from:r.from,to:r.to,points:JSON.parse(Buffer.from(paths[index].attributes['data-points'],'base64').toString('utf8'))}));
    const labels = referenceLabels(record, semantic, nodes);
    return {semantic,geometry:{view_box:record.rendering.view_box,nodes,edges,labels}};
}

function referenceLabels(record, semantic, nodes) {
    const wanted=[];
    const central=[],terminals=[];
    semantic.relationships.forEach((r,i)=>{
        if(r.label){central.push(`${i}-label`);wanted.push(`${i}-label`);}
        if(r.from_multiplicity){terminals.push(`${i}-from-label`);wanted.push(`${i}-from-label`);}
        if(r.to_multiplicity){terminals.push(`${i}-to-label`);wanted.push(`${i}-to-label`);}
    });
    for(const c of semantic.classes){
        c.annotations.slice(0,1).forEach((_,i)=>wanted.push(`${c.id}-annotation-${i}`));
        wanted.push(`${c.id}-header`);
        c.fields.forEach((_,i)=>wanted.push(`${c.id}-field-${i}`));
        c.methods.forEach((_,i)=>wanted.push(`${c.id}-method-${i}`));
    }
    const observed=new Map();let node=null,role=null,centralIndex=0,terminalIndex=0,field=0,method=0;
    for(const e of record.rendering.elements){
        if(e.tag==='g'&&hasClass(e,'node')){
            node=semantic.classes.find(c=>new RegExp(`^oracle-classId-${c.id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-[0-9]+$`).test(e.id))?.id;
            field=0;method=0;role=null;
        }
        if(e.tag==='g'&&hasClass(e,'edgeLabel')){role=central[centralIndex++];node=null;}
        if(e.tag==='g'&&hasClass(e,'edgeTerminals')){role=terminals[terminalIndex++];node=null;}
        if(node&&e.tag==='g'){
            if(hasClass(e,'annotation-group'))role=`${node}-annotation-0`;
            if(hasClass(e,'label-group'))role=`${node}-header`;
            if(hasClass(e,'members-group'))role='field';
            if(hasClass(e,'methods-group'))role='method';
        }
        if(e.tag==='text'&&e.text!==''&&role){
            const id=role==='field'?`${node}-field-${field++}`:role==='method'?`${node}-method-${method++}`:role;
            if(observed.has(id))throw new Error(`duplicate class label role ${id}`);
            observed.set(id,{id,text:e.text.replace(/\s+/g,' ').trim(),box:e.box});
        }
    }
    const unknown=[...observed.keys()].filter(id=>!wanted.includes(id));
    if(unknown.length)throw new Error(`unassigned class label roles: ${unknown}`);
    return wanted.flatMap(id=>observed.has(id)?[observed.get(id)]:[]);
}
