// The diagram Mermaid hands to layout, in the Roc `Flowchart` model's terms,
// derived from an oracle record. Tags are spelled as Roc's `Str.inspect`
// prints them, so the same values serve as Roc literals and as comparison
// keys against the Roc inspector's output.
const directions = { TB: 'Down', TD: 'Down', BT: 'Up', LR: 'Right', RL: 'Left' };
const shapes = {
	square: 'Rectangle',
	round: 'Rounded',
	stadium: 'Stadium',
	subroutine: 'Subroutine',
	cylinder: 'Cylinder',
	circle: 'Circle',
	doublecircle: 'DoubleCircle',
	ellipse: 'Ellipse',
	odd: 'Asymmetric',
	diamond: 'Diamond',
	hexagon: 'Hexagon',
	lean_right: 'LeanRight',
	lean_left: 'LeanLeft',
	trapezoid: 'Trapezoid',
	inv_trapezoid: 'InverseTrapezoid',
};
const heads = { none: 'None', arrow_point: 'Arrow', arrow_circle: 'Circle', arrow_cross: 'Cross' };
const lines = { normal: 'Solid', thick: 'Thick', dotted: 'Dotted', invisible: 'Invisible' };

// { outcome: 'Rejected' } | { outcome: 'Unsupported', reason } | { outcome: 'Accepted', diagram }
export function expectedOutcome(record, name) {
	if (!record.accepted || !record.flowchart) return { outcome: 'Rejected' };
	if (name.startsWith('unsupported-')) return { outcome: 'Unsupported', reason: 'named unsupported' };
	const fc = record.flowchart;
	const input = record.layout_input;
	if (!directions[fc.direction]) return { outcome: 'Unsupported', reason: `direction ${fc.direction}` };
	const layoutNode = new Map(input.nodes.map(n => [n.id, n]));
	const groupIds = new Set(fc.subgraphs.map(s => s.id));
	if (fc.subgraphs.some(g => layoutNode.get(g.id)?.declaration_index == null)) return { outcome: 'Unsupported', reason: 'cyclic groups' };
	const groups = [...fc.subgraphs].sort((a, b) => layoutNode.get(a.id).declaration_index - layoutNode.get(b.id).declaration_index);
	const groupSlot = new Map(groups.map((g, i) => [g.id, i]));
	const container = id => {
		const parent = layoutNode.get(id)?.parent;
		return parent == null ? 'Root' : `Group(${groupSlot.get(parent)})`;
	};
	const nodes = fc.nodes.filter(n => !groupIds.has(n.id));
	const nodeSlot = new Map(nodes.map((n, i) => [n.id, i]));
	const endpoint = id => (groupIds.has(id) ? `Group(${groupSlot.get(id)})` : nodeSlot.has(id) ? `Node(${nodeSlot.get(id)})` : null);
	const edges = [];
	for (const [i, e] of fc.edges.entries()) {
		const data = input.edges[i];
		if (e.type === 'INVALID') return { outcome: 'Unsupported', reason: 'mismatched link ends' };
		const from = endpoint(e.from);
		const to = endpoint(e.to);
		if (from === null || to === null) return { outcome: 'Unsupported', reason: 'edge to a missing node' };
		edges.push({
			id: data.id,
			from,
			to,
			label: e.label,
			line: lines[e.stroke],
			start: heads[data.arrow_start],
			end: heads[data.arrow_end],
			length: e.length,
			classes: e.classes,
			styles: data.styles,
		});
	}
	return {
		outcome: 'Accepted',
		diagram: {
			direction: directions[fc.direction],
			nodes: nodes.map(n => ({
				id: n.id,
				label: n.label,
				shape: shapes[n.shape] ?? 'Rectangle',
				container: container(n.id),
				classes: n.classes,
				styles: n.styles,
			})),
			edges,
			groups: groups.map(g => ({
				id: g.id,
				title: g.label,
				container: container(g.id),
				direction: g.dir ? `Set(${directions[g.dir]})` : 'Inherit',
				classes: g.classes,
			})),
			classes: fc.classes.map(c => ({ name: c.id, styles: c.styles })),
		},
	};
}

// The first path at which two JSON-like values differ, or null.
export function firstDifference(a, b, at = '') {
	if (Array.isArray(a) && Array.isArray(b)) {
		for (let i = 0; i < Math.max(a.length, b.length); i++) {
			const found = firstDifference(a[i], b[i], `${at}[${i}]`);
			if (found) return found;
		}
		return null;
	}
	if (a && b && typeof a === 'object' && typeof b === 'object') {
		for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
			const found = firstDifference(a[key], b[key], `${at}.${key}`);
			if (found) return found;
		}
		return null;
	}
	return a === b ? null : { at, mermaid: a, roc: b };
}
