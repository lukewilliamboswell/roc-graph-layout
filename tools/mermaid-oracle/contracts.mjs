// Shared protocol between the pinned browser recorder and native family
// probes. All model comparisons are exact JSON comparisons, never pictures
// compared with themselves or baselines inferred from the implementation.
export const FAMILY_DIRS = {
	flowchart: ['tests/mermaid/flowchart', 'tests/mermaid/layout', 'tests/mermaid/measure', 'tests/mermaid/themed'],
	sequence: ['tests/mermaid/sequence'],
	entity: ['tests/mermaid/entity'],
	class: ['tests/mermaid/class'],
	state: ['tests/mermaid/state'],
};

export function familyOf(type) {
	if (type === 'flowchart' || type === 'flowchart-v2') return 'flowchart';
	if (type === 'sequence' || type === 'sequenceDiagram') return 'sequence';
	if (type === 'er' || type === 'erDiagram') return 'entity';
	if (type === 'classDiagram' || type === 'class') return 'class';
	if (type === 'stateDiagram' || type === 'stateDiagram-v2') return 'state';
	return null;
}

export function differences(expected, actual, at = '$') {
	if (Object.is(expected, actual)) return [];
	if (expected === null || actual === null || typeof expected !== 'object' || typeof actual !== 'object') {
		return [{ path: at, expected, actual }];
	}
	if (Array.isArray(expected) !== Array.isArray(actual)) return [{ path: at, expected, actual }];
	const keys = [...new Set([...Object.keys(expected), ...Object.keys(actual)])].sort();
	return keys.flatMap(key => differences(expected[key], actual[key], `${at}.${key}`));
}
