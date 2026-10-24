app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	layout: "../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import Flowchart
import FlowGeometry
import FlowLayout

## Prints one JSON line of layout geometry for each case file given, for
## `tools/mermaid-oracle/score.mjs`. A case file holds Mermaid source, a NUL
## byte, then one size per line, tab separated, in thousandths of a pixel:
##
##     node <id> <width> <height>
##     edge <index> <width> <height>
##     group <id> <width> <height>
##
## Parts without a line get size zero; edges without a line have no label.
main! = |args| {
	for arg in args {
		name = OsStr.display(arg)
		bytes = Path.read_bytes!(Path.utf8(name))?
		Stdout.line!("{\"file\":${json(name)},${case_json(bytes)}}")?
	}
	Ok({})
}

case_json : List(U8) -> Str
case_json = |bytes| {
	split = bytes.find_first_index(|b| b == 0) ?? bytes.len()
	source = Str.from_utf8_lossy(bytes.take_first(split))
	table = Str.from_utf8_lossy(bytes.drop_first(split + 1))
	match Flowchart.parse(source) {
		Err(_) => "\"accepted\":false"
		Ok(diagram) => {
			sizes = read_sizes(diagram, table)
			geometry = FlowLayout.layout(diagram, sizes)
			"\"accepted\":true,\"geometry\":${geometry_json(diagram, geometry)}"
		}
	}
}

read_sizes : Flowchart.Diagram, Str -> FlowGeometry.Sizes
read_sizes = |diagram, table| {
	lines = table.split_on("\n").map(|line| line.split_on("\t"))
	find = |kind, key| lines.find_first(|parts| parts.get(0) == Ok(kind) and parts.get(1) == Ok(key))
	size_of = |parts| { width: thousandths(parts.get(2) ?? "0"), height: thousandths(parts.get(3) ?? "0") }
	block = |parts| {
		size = size_of(parts)
		{ lines: [], width: size.width, height: size.height }
	}
	{
		nodes: diagram.nodes.map(
			|node| {
				size = match find("node", node.id) {
					Ok(parts) => size_of(parts)
					Err(_) => { width: 0, height: 0 }
				}
				{ width: size.width, height: size.height, label: { lines: [], width: 0, height: 0 } }
			},
		),
		edge_labels: diagram.edges.map_with_index(
			|_, i|
				match find("edge", i.to_str()) {
					Ok(parts) => Some(block(parts))
					Err(_) => None
				},
		),
		group_titles: diagram.groups.map(
			|group|
				match find("group", group.id) {
					Ok(parts) => block(parts)
					Err(_) => { lines: [], width: 0, height: 0 }
				},
		),
	}
}

thousandths : Str -> F64
thousandths = |text| {
	var $value = 0
	for b in text.to_utf8() {
		if b >= '0' and b <= '9' {
			$value = $value * 10 + (b - '0').to_u64()
		}
	}
	$value.to_f64() / 1000
}

geometry_json : Flowchart.Diagram, FlowGeometry.Geometry -> Str
geometry_json = |diagram, g| {
	nodes = g.nodes.map_with_index(|r, i| "{\"id\":${json((diagram.nodes.get(i) ?? { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).id)},\"box\":${rect(r)}}")
	groups = g.groups.map_with_index(|r, i| "{\"id\":${json((diagram.groups.get(i) ?? { id: "", title: "", container: Root, direction: Inherit, classes: [] }).id)},\"box\":${rect(r)}}")
	edges = g.edges.map_with_index(
		|e, i| {
			label = match e.label {
				Some(p) => point(p)
				None => "null"
			}
			id = (diagram.edges.get(i) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }).id
			"{\"id\":${json(id)},\"points\":[${Str.join_with(e.points.map(point), ",")}],\"label\":${label}}"
		},
	)
	"{\"bounds\":${rect(g.bounds)},\"nodes\":[${Str.join_with(nodes, ",")}],\"groups\":[${Str.join_with(groups, ",")}],\"edges\":[${Str.join_with(edges, ",")}]}"
}

num : F64 -> Str
num = |x| if (F64.is_finite(x)) x.to_str() else "\"non-finite\""

point : FlowGeometry.Point -> Str
point = |p| "{\"x\":${num(p.x)},\"y\":${num(p.y)}}"

rect : FlowGeometry.Rect -> Str
rect = |r| "{\"x\":${num(r.x)},\"y\":${num(r.y)},\"width\":${num(r.width)},\"height\":${num(r.height)}}"

json : Str -> Str
json = |text| {
	var $out = ['"']
	for b in text.to_utf8() {
		$out = if b == '"' or b == '\\' {
			$out.append('\\').append(b)
		} else if b < 32 {
			$out.append(' ')
		} else {
			$out.append(b)
		}
	}
	Str.from_utf8_lossy($out.append('"'))
}
