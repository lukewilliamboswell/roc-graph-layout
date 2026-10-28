// Canonical state meaning from the pinned Mermaid DB, independently of Roc.
// Effective shapes come from the renderer input; declared kinds come from
// the source AST so a renderer losing a late choice declaration stays visible.
const pairs = value => Array.isArray(value) ? value : Object.entries(value ?? {});
const cleanId = id => String(id ?? '').replace(/----note-\d+$/, '----note');
const kindOf = value => ({ stateStart: 'initial', start: 'initial', stateEnd: 'final', end: 'final', choice: 'choice', fork: 'fork', join: 'join' })[value] ?? 'normal';
const direction = value => ({ TD: 'TB', Down: 'TB', Up: 'BT', Right: 'LR', Left: 'RL' })[value] ?? value ?? 'TB';
const display = value => String(value ?? '').replace(/<br\s*\/?>/gi, '\n');

export function normalizeReference(record) {
    const model = record.model ?? {};
    const root = model.getRootDocV2 ?? model.getRootDoc;
    if (!root?.doc) throw new Error('state reference record lacks the raw source document; refresh with schema8');
    const states = new Map(), groups = new Map(), transitions = [], notes = [];
    const firstKinds = new Map();
    const ensure = (node, parent) => {
        if (!node?.id || node.id === 'root') return null;
        const id = cleanId(node.id);
        const declared = node.start === true ? 'initial' : node.start === false ? 'final' : kindOf(node.type);
        if (!firstKinds.has(id)) firstKinds.set(id, declared);
        let value = states.get(id) ?? groups.get(id);
        if (!value) {
            value = { id, parent, declared_kind: declared, effective_kind: firstKinds.get(id), descriptions: [], classes: [], styles: [] };
            states.set(id, value);
        }
        if (declared !== 'normal') value.declared_kind = declared;
        if (node.description) value.descriptions.push(display(node.description).trim());
        if (node.doc) {
            states.delete(id);
            const directives = node.doc.filter(item => item.stmt === 'dir');
            const group = groups.get(id) ?? { id, parent, direction: direction(directives.at(-1)?.value ?? 'TB'), direction_set: directives.length > 0, descriptions: value.descriptions, classes: value.classes, styles: value.styles };
            groups.set(id, group);
            for (const item of node.doc) visit(item, id);
            return group;
        }
        if (node.note) notes.push({ state: id, side: node.note.position === 'left of' ? 'left' : 'right', text: display(node.note.text).trim(), after_transition: transitions.length });
        return value;
    };
    const visit = (item, parent) => {
        if (item.stmt === 'relation') {
            const from = ensure(item.state1, parent), to = ensure(item.state2, parent);
            transitions.push({ id: `transition-${transitions.length}`, from: from.id, to: to.id, label: display(item.description).trim() });
        } else if (item.stmt === 'state' || item.stmt === 'default') {
            ensure(item, parent);
        } else if (item.stmt === 'applyClass' || item.stmt === 'style') {
            for (const id of String(item.id).split(',').map(id => id.trim())) ensure({ id }, parent);
        }
    };
    for (const item of root.doc) visit(item, null);
    // The DB resolves classes/styles globally, including declarations naming
    // a state within a composite, so copy their actual final values.
    for (const [id, state] of pairs(model.getStates)) {
        const target = states.get(id) ?? groups.get(id);
        if (target) { target.classes = state.classes ?? []; target.styles = state.styles ?? []; }
    }
    const data = model.getData ?? record.layout_input ?? {};
    for (const node of data.nodes ?? []) {
        const target = states.get(cleanId(node.id));
        if (target) target.effective_kind = kindOf(node.shape);
        const group = groups.get(cleanId(node.id));
        if (group) group.palette_index = node.colorIndex ?? null;
    }
    const semantic = {
        direction: direction(model.getDirection), states: [...states.values()], groups: [...groups.values()], transitions, notes,
        classes: pairs(model.getClasses).map(([name, value]) => ({ name, styles: value.styles ?? [], text_styles: value.textStyles ?? [] })),
    };
    const elements = record.rendering?.elements ?? [];
    const nodeIds = new Set([...states.keys(), ...groups.keys(), ...notes.map(note => `${note.state}----note`), ...notes.map(note => `${note.state}----parent`)]);
    const domId = value => String(value ?? '').replace(/^.*?-state-/, '').replace(/-\d+$/, '');
    const nodes = elements.filter(element => element.tag === 'g' && element.class.split(/\s+/).includes('node')).map(element => ({ id: cleanId(domId(element.id)), box: element.box })).filter(node => nodeIds.has(node.id));
    const groupGeometry = [];
    let frameGroup;
    const framed = new Set();
    for (const element of elements) {
        if (element.tag === 'g' && element.class.split(/\s+/).includes('statediagram-cluster')) frameGroup = cleanId(domId(element.id));
        if (element.tag === 'rect' && element.class === 'outer' && groups.has(frameGroup) && !framed.has(frameGroup)) {
            groupGeometry.push({id:frameGroup,box:element.box}); framed.add(frameGroup);
        }
    }
    const edgeModels = data.edges ?? [];
    const edges = [];
    let transitionIndex = 0, noteIndex = 0;
    for (const element of elements.filter(element => element.tag === 'path' && element.class.split(/\s+/).includes('transition'))) {
        const isNote = element.class.split(/\s+/).includes('note-edge');
        const id = isNote ? `note-${noteIndex++}` : `transition-${transitionIndex++}`;
        const authored = isNote ? notes[noteIndex - 1] : transitions[transitionIndex - 1];
        const nativeId = element.id.replace(/^oracle-/, '');
        const edge = edgeModels.find(candidate => candidate.id === nativeId);
        const from = cleanId(edge?.start ?? (isNote ? authored.side === 'left' ? `${authored.state}----note` : authored.state : authored.from));
        const to = cleanId(edge?.end ?? (isNote ? authored.side === 'left' ? authored.state : `${authored.state}----note` : authored.to));
        if (!element.attributes?.['data-points']) throw new Error(`state edge ${element.id} lacks original layout points`);
        const points = JSON.parse(Buffer.from(element.attributes['data-points'], 'base64').toString('utf8'));
        edges.push({ id, from, to, points });
    }
    const textRuns = elements.filter(element => element.tag === 'tspan' && element.class.split(/\s+/).includes('row')).map((element, i) => ({ id: `label-${i}`, text: element.text, box: element.box }));
    const labelled = transitions.filter(edge => edge.label !== '');
    const labels = elements.filter(element => element.tag === 'g' && element.class === 'edgeLabel').map((element, i) => {
        const edge = labelled[i];
        if (!edge) throw new Error(`unexpected state edge label ${i}`);
        // Mermaid's label backing extends2px beyond the measured input
        // text box. Keep the input size, not that post-layout decoration.
        return { id: edge.id, size_kind: 'label', text: edge.label, box: { x: element.box.x + 2, y: element.box.y + 2, width: element.box.width - 4, height: element.box.height - 4 } };
    });
    let currentGroup;
    for (const element of elements) {
        if (element.tag === 'g' && element.class.split(/\s+/).includes('statediagram-cluster')) currentGroup = groups.get(cleanId(domId(element.id)));
        if (element.tag === 'g' && element.class === 'cluster-label' && currentGroup) {
            const measured = (record.measured_input?.nodes ?? []).find(node => cleanId(node.id) === currentGroup.id)?.labelData;
            if (!Number.isFinite(measured?.width) || !Number.isFinite(measured?.height)) throw new Error(`missing actual composite title input ${currentGroup.id}; refresh reference`);
            labels.push({ id: `group-${currentGroup.id}`, size_kind: 'group', text: currentGroup.descriptions[0] ?? currentGroup.id, box: element.box, input_box:{width:measured.width,height:measured.height+2} });
        }
    }
    // The recorder captures the actual label measurement handed to ELK.
    // FlowLayoutImport subtracts two pixels from the glyph box height;
    // retain the original glyph box here, never a final container frame.
    const measurements = (record.measured_input?.nodes ?? []).filter(node => node.shape === 'noteGroup').map(node => {
        const box = node.labelBBox;
        if (!Number.isFinite(box?.width) || !Number.isFinite(box?.height)) throw new Error(`missing measured note-group label ${node.id}`);
        return { kind: 'group', id: 'note-group-' + cleanId(node.id).replace(/----parent$/, ''), text: display(node.label), width: box.width, height: box.height };
    });
    return { semantic, measurements, geometry: { view_box: record.layout?.view_box ?? record.rendering?.view_box, nodes, groups: groupGeometry, edges, labels, text_runs: textRuns } };
}
