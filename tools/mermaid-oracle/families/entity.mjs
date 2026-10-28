// Pinned Mermaid ER DB facts, translated without dropping attribute columns,
// cardinalities, relationship identity or source order.
const direction = value => ({TB:'Down',TD:'Down',BT:'Up',LR:'Right',RL:'Left'}[value] ?? value);
const cardinality = value => ({ONLY_ONE:'ExactlyOne',ZERO_OR_ONE:'ZeroOne',ONE_OR_MORE:'OneMany',ZERO_OR_MORE:'ZeroMany'}[value] ?? value);
const hasClass = (element, name) => element.class.split(/\s+/).includes(name);

export function normalizeReference(record) {
    if (!record.accepted) return {semantic:null, geometry:null};
    const db = record.model;
    const entities = db.getEntities;
    const ids = new Map(entities.map(([id, entity]) => [entity.id, id]));
    const relationships = db.getRelationships.map(r => ({
        from: ids.get(r.entityA), to: ids.get(r.entityB),
        // Mermaid stores the opposite endpoint's cardinality in cardA.
        from_cardinality: cardinality(r.relSpec.cardB),
        to_cardinality: cardinality(r.relSpec.cardA),
        identifying: r.relSpec.relType === 'IDENTIFYING', label: r.roleA,
    }));
    const semantic = {
        direction: direction(db.getDirection || 'TB'),
        entities: entities.map(([id, e]) => ({id, label:e.alias || e.label, attributes:e.attributes.map(a => ({type:a.type,name:a.name,keys:a.keys,comment:a.comment}))})),
        relationships,
    };
    if (!record.rendering) return {semantic,geometry:null};
    const elements = record.rendering.elements;
    const nodes = entities.map(([id, e]) => {
        const group = elements.find(n => n.tag === 'g' && hasClass(n,'node') && (n.id === `oracle-${e.id}` || n.id.endsWith(`-${e.id}`)));
        if (!group) throw new Error(`missing ER node ${id}`);
        const outer = elements.find(n => n.parent_id === group.id && (hasClass(n,'outer-path') || hasClass(n,'label-container')));
        if (!outer) throw new Error(`missing ER node outline ${id}`);
        return {id,box:outer.box};
    });
    const paths = elements.filter(e => e.tag === 'path' && e.attributes['data-edge'] === 'true');
    if (paths.length !== relationships.length) throw new Error('ER source-edge/path count differs');
    const edges = relationships.map((r,index) => ({id:String(index),from:r.from,to:r.to,points:JSON.parse(Buffer.from(paths[index].attributes['data-points'],'base64').toString('utf8'))}));
    const labels = referenceLabels(record, semantic, nodes);
    return {semantic,geometry:{view_box:record.rendering.view_box,nodes,edges,labels}};
}

function referenceLabels(record, semantic, nodes) {
    const wanted=[],central=[];
    semantic.relationships.forEach((r,i)=>{if(r.label){wanted.push(`${i}-label`);central.push(`${i}-label`);}});
    for(const e of semantic.entities){
        wanted.push(`${e.id}-header`);
        e.attributes.forEach((a,i)=>{for(const key of ['type','name','keys','comment'])if(Array.isArray(a[key])?a[key].length:a[key])wanted.push(`${e.id}-attribute-${i}-${key}`);});
    }
    const observed=new Map();let node=null,role=null,row=-1,centralIndex=0;
    for(const e of record.rendering.elements){
        if(e.tag==='g'&&hasClass(e,'node')){
            const db=record.model.getEntities.find(([id,v])=>e.id===`oracle-${v.id}`);
            node=db?.[0];row=-1;role=node?`${node}-header`:null;
        }
        if(e.tag==='g'&&hasClass(e,'edgeLabel')){role=central[centralIndex++];node=null;}
        if(node&&e.tag==='g'){
            if(hasClass(e,'name'))role=`${node}-header`;
            if(hasClass(e,'attribute-type')){row++;role=`${node}-attribute-${row}-type`;}
            for(const key of ['name','keys','comment'])if(hasClass(e,`attribute-${key}`))role=`${node}-attribute-${row}-${key}`;
        }
        if(e.tag==='text'&&e.text!==''&&role){
            if(observed.has(role))throw new Error(`duplicate ER label role ${role}`);
            observed.set(role,{id:role,text:e.text.replace(/\s+/g,' ').trim(),box:e.box});
        }
    }
    const unknown=[...observed.keys()].filter(id=>!wanted.includes(id));
    if(unknown.length)throw new Error(`unassigned ER label roles: ${unknown}`);
    return wanted.flatMap(id=>observed.has(id)?[observed.get(id)]:[]);
}
