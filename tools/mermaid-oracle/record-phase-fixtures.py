#!/usr/bin/env python3
"""Record structural inputs for core phase tests, without a core parser dependency.

Usage: python3 tools/mermaid-oracle/record-phase-fixtures.py /path/to/oracle_dump
Only parser semantics are read. Oracle positions/routes never enter these fixtures.
The expected phase results remain hand-authored regressions in the core modules.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def parent(value):
    return None if value == 'Root' else int(re.fullmatch(r'Group\((\d+)\)', value)[1])


def endpoint(value):
    kind, index = re.fullmatch(r'(Node|Group)\((\d+)\)', value).groups()
    return kind, int(index)


def separate_groups(diagram):
    groups, nodes = diagram['groups'], diagram['nodes']
    def chain(end):
        kind, index = end
        result = [index] if kind == 'Group' else []
        current = parent((groups if kind == 'Group' else nodes)[index]['container'])
        while current is not None:
            result.append(current)
            current = parent(groups[current]['container'])
        return result
    def owner(end):
        kind, index = end
        return parent((groups if kind == 'Group' else nodes)[index]['container'])
    included = set()
    for edge in diagram['edges']:
        start, end = endpoint(edge['from']), endpoint(edge['to'])
        if owner(start) == owner(end):
            continue
        first, second = chain(start), chain(end)
        if start[0] == 'Group' and start[1] in second:
            common = start[1]
        elif end[0] == 'Group' and end[1] in first:
            common = end[1]
        else:
            common = next((g for g in first if g in second), None)
        for ancestors in [first, second]:
            for group in ancestors:
                included.add(group)
                if group == common:
                    break
    separate = [False] * len(groups)
    done = set()
    for _ in range(len(groups) + 1):
        for index, group in enumerate(groups):
            owner_index = parent(group['container'])
            if index not in done and (owner_index is None or owner_index in done):
                inherited = owner_index is not None and separate[owner_index]
                separate[index] = index not in included and (group['direction'] != 'Inherit' or inherited)
                done.add(index)
    return separate


def record(source, diagram, measurement=None):
    groups, nodes = diagram['groups'], diagram['nodes']
    separate = separate_groups(diagram)
    directions = [None] * len(groups)
    def direction(index):
        if directions[index] is None:
            group = groups[index]
            owner = parent(group['container'])
            directions[index] = (group['direction'][4:-1] if group['direction'].startswith('Set(') else 'Right') if separate[index] else (direction(owner) if owner is not None else diagram['direction'])
        return directions[index]
    def children(owner):
        return ([('GroupItem', g) for g in reversed(range(len(groups))) if parent(groups[g]['container']) == owner]
                + [('NodeItem', n) for n in range(len(nodes)) if parent(nodes[n]['container']) == owner])
    registration = children(None)
    cursor = 0
    while cursor < len(registration):
        kind, index = registration[cursor]
        if kind == 'GroupItem':
            registration.extend(children(index))
        cursor += 1
    def byte(index):
        values = measurement['bytes']
        return values[index % len(values)] if values else 0
    copies = measurement['copies'] if measurement else 1
    def block(index):
        return (byte(index) % 128, byte(index + 1) % 32)
    def measured_block(index, count, step, offset):
        return block((index % max(count // copies, 1)) * step + offset)
    node_sizes = [
        (byte((i % max(len(nodes) // copies, 1)) * 3), byte((i % max(len(nodes) // copies, 1)) * 3 + 1) % 128) if measurement else (152, 41)
        for i in range(len(nodes))
    ]
    edge_sizes = [
        measured_block(i, len(diagram['edges']), 5, 2) if measurement else (31.26953125, 17)
        for i in range(len(diagram['edges']))
    ]
    group_sizes = [measured_block(i, len(groups), 7, 1) if measurement else (10, 17) for i in range(len(groups))]
    output_groups = []
    titles = []
    for index, group in enumerate(groups):
        vertical = direction(index) in ['Down', 'Up']
        empty = not children(index)
        width, height = group_sizes[index]
        height = max(0, height - 2)
        padding_top = 24 + (height + 5 if height > 0 else 0)
        minimum = width + (10 if width > 0 else 8)
        output_groups.append('{' + f'container: {group["container"]}, direction: {group["direction"]}, separate: {str(separate[index])}, spacing: LayeredFlowFixtures.group_spacing, padding: {{ top: {padding_top}, right: 24, bottom: 24, left: 24 }}, min_width: {0 if vertical or empty else minimum}, min_height: {minimum if vertical and not empty else 0}' + '}')
        titles.append('{ width: 0, height: 0 }' if empty else '{'+f' width: {width}, height: {height} '+'}')
    text = lambda value: json.dumps(value, ensure_ascii=False)
    return f'''{text(source)} => {{
        diagram: {{ direction: {diagram['direction']}, nodes: [{', '.join('{ container: '+n['container']+' }' for n in nodes)}], groups: [{', '.join(output_groups)}], edges: [{', '.join('{ from: '+e['from']+', to: '+e['to']+' }' for e in diagram['edges'])}], spacing: LayeredFlowFixtures.root_spacing, padding: {{ top: 12, right: 12, bottom: 12, left: 12 }} }},
        sizes: {{ nodes: [{', '.join('{'+f' width: {w}, height: {h} '+'}' for w,h in node_sizes)}], edge_labels: [{', '.join('Some({'+f' width: {edge_sizes[i][0]+4}, height: {edge_sizes[i][1]+4} '+'})' if e['label'] else 'None' for i,e in enumerate(diagram['edges']))}], group_titles: [{', '.join(titles)}] }},
        registration: [{', '.join(f'{kind}({index})' for kind,index in registration)}],
    }}'''


def main():
    sources = json.loads(Path('tests/mermaid/phases/sources.json').read_text())
    entries = []
    with tempfile.TemporaryDirectory(prefix='layout-phase-fixtures-') as directory:
        work = Path(directory)
        (work / 'empty.tsv').write_text('')
        for index, entry in enumerate(sources):
            source = entry if isinstance(entry, str) else entry['source']
            key = source if isinstance(entry, str) else entry['key']
            source_path = work / f'{index}.mmd'
            source_path.write_text(source)
            result_path = work / f'{index}.json'
            subprocess.run([sys.argv[1], 'flowchart', 'default', str(source_path), str(work / 'empty.tsv'), str(result_path), str(work / f'{index}.svg')], check=True)
            result = json.loads(result_path.read_text())
            assert result['accepted'], source
            entries.append(record(key, result['semantic'], None if isinstance(entry, str) else entry))
    header = '''import LayeredFlowInput
import LayeredFlowGraph

## Generated structural phase inputs. Regenerate with
## tools/mermaid-oracle/record-phase-fixtures.py and a native oracle_dump.
## All dimensions are authored test measurements; no oracle geometry is read.
LayeredFlowFixtures :: {}.{
    Fixture : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes, registration : List([GroupItem(U64), NodeItem(U64)]) }
    root_spacing : LayeredFlowGraph.Spacing
    root_spacing = { node_node: 40, node_node_between_layers: 40, edge_node: 20, edge_node_between_layers: 20, edge_edge: 20, edge_edge_between_layers: 20, edge_label: 4, label_label: 0, label_node: 10, port_port: 20, node_self_loop: 20, ports_surrounding: 12 }
    group_spacing : LayeredFlowGraph.Spacing
    group_spacing = { node_node: 50, node_node_between_layers: 24, edge_node: 12, edge_node_between_layers: 30, edge_edge: 20, edge_edge_between_layers: 12, edge_label: 2.4, label_label: 0, label_node: 6, port_port: 12, node_self_loop: 12, ports_surrounding: 12 }
    get : Str -> Fixture
    get = |source| match source {
'''
    Path('package/LayeredFlowFixtures.roc').write_text(header + '\n'.join(entries) + '\n_ => crash "missing structural phase fixture"\n}\n}\n')
    print(f'Recorded {len(entries)} structural phase fixtures')


if __name__ == '__main__':
    main()
