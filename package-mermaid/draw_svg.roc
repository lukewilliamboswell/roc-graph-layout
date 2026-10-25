app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import Drawing
import Flowchart
import FlowDraw
import FlowGeometry
import Svg

## Draws flowcharts as SVG from given geometry, so the drawing stage can be
## compared with Mermaid on Mermaid's own layout (see
## `tools/mermaid-oracle/visual.mjs`, which writes the geometry files).
##
##     draw_svg <font family> <case.mmd> <case.geometry> <out.svg> ...
##
## A geometry file has one item per line, numbers in thousandths of a pixel
## and ids as hex-encoded UTF-8:
##
##     bounds X Y W H
##     node ID X Y W H LABEL_W LABEL_H ROWS
##     group ID X Y W H TITLE_W TITLE_H ROWS
##     edge ID LABEL_X LABEL_Y LABEL_W LABEL_H ROWS N X1 Y1 ... XN YN
##
## An edge without a label has `-` for its four label numbers. `ROWS` is the
## label's lines joined by line breaks, hex-encoded, or `-` for the
## diagram's label split at line breaks.
main! = |args| {
	strings = args.map(OsStr.display)
	family = strings.get(0) ?? "sans-serif"
	rest = strings.drop_first(1)
	var $i = 0
	while $i + 2 < rest.len() {
		source_path = rest.get($i) ?? ""
		geometry_path = rest.get($i + 1) ?? ""
		out_path = rest.get($i + 2) ?? ""
		source = Str.from_utf8_lossy(Path.read_bytes!(Path.utf8(source_path))?)
		geometry_text = Str.from_utf8_lossy(Path.read_bytes!(Path.utf8(geometry_path))?)
		match Flowchart.parse(source) {
			Err(problems) => Stderr.line!("${source_path}: not drawn: ${Str.inspect(problems)}")?
			Ok(diagram) => {
				input = read_geometry(diagram, geometry_text)
				picture = FlowDraw.draw(diagram, input.sizes, input.geometry)
				Path.write_bytes!(Path.utf8(out_path), Svg.document(picture, family).to_utf8())?
			}
		}
		$i = $i + 3
	}
	Ok({})
}

Entry : { box : FlowGeometry.Rect, text : { width : F64, height : F64 }, rows : [Diagram, Given(Str)], label : [None, Some(FlowGeometry.Point)], points : List(FlowGeometry.Point) }

read_geometry : Flowchart.Diagram, Str -> { sizes : FlowGeometry.Sizes, geometry : FlowGeometry.Geometry }
read_geometry = |diagram, text| {
	var $bounds = { x: 0, y: 0, width: 0, height: 0 }
	var $nodes = []
	var $groups = []
	var $edges = []
	for line in text.split_on("\n") {
		words = line.split_on(" ")
		kind = words.get(0) ?? ""
		id = unhex(words.get(1) ?? "")
		num = |k| number(words.get(k) ?? "-")
		rows_at = |k| if ((words.get(k) ?? "-") == "-") Diagram else Given(unhex(words.get(k) ?? ""))
		if kind == "bounds" {
			$bounds = { x: number(words.get(1) ?? "0"), y: number(words.get(2) ?? "0"), width: number(words.get(3) ?? "0"), height: number(words.get(4) ?? "0") }
		} else if kind == "node" or kind == "group" {
			entry = { id, value: { box: { x: num(2), y: num(3), width: num(4), height: num(5) }, text: { width: num(6), height: num(7) }, rows: rows_at(8), label: None, points: [] } }
			if kind == "node" {
				$nodes = $nodes.append(entry)
			} else {
				$groups = $groups.append(entry)
			}
		} else if kind == "edge" {
			label = if ((words.get(2) ?? "-") == "-") None else Some({ x: num(2), y: num(3) })
			count = (I64.from_str(words.get(7) ?? "0") ?? 0).to_u64_wrap()
			var $points = []
			for k in 0..<count {
				$points = $points.append({ x: num(8 + 2 * k), y: num(9 + 2 * k) })
			}
			$edges = $edges.append({ id, value: { box: { x: 0, y: 0, width: 0, height: 0 }, text: { width: num(4), height: num(5) }, rows: rows_at(6), label, points: $points } })
		}
	}
	find = |list, key| list.find_first(|e| e.id == key)
	empty = { box: { x: 0, y: 0, width: 0, height: 0 }, text: { width: 0, height: 0 }, rows: Diagram, label: None, points: [] }
	node_entries = diagram.nodes.map(|n| (find($nodes, n.id) ?? { id: n.id, value: empty }).value)
	group_entries = diagram.groups.map(|g| (find($groups, g.id) ?? { id: g.id, value: empty }).value)
	edge_entries = diagram.edges.map(|e| (find($edges, e.id) ?? { id: e.id, value: empty }).value)
	block = |label, e|
		match e.rows {
			Diagram => { lines: label.split_on("\n"), width: e.text.width, height: e.text.height }
			Given(given) => { lines: given.split_on("\n"), width: e.text.width, height: e.text.height }
		}
	{
		sizes: {
			nodes: diagram.nodes.map_with_index(
				|n, k| {
					e = node_entries.get(k) ?? empty
					{ width: e.box.width, height: e.box.height, label: block(n.label, e) }
				},
			),
			edge_labels: diagram.edges.map_with_index(
				|edge, k| {
					e = edge_entries.get(k) ?? empty
					match e.label {
						None => None
						Some(_) => Some(block(edge.label, e))
					}
				},
			),
			group_titles: diagram.groups.map_with_index(|g, k| block(g.title, group_entries.get(k) ?? empty)),
		},
		geometry: {
			nodes: node_entries.map(|e| e.box),
			edges: edge_entries.map(|e| { points: e.points, label: e.label }),
			groups: group_entries.map(|e| e.box),
			bounds: $bounds,
		},
	}
}

## A number written in thousandths, or zero.
number : Str -> F64
number = |word|
	match I64.from_str(word) {
		Ok(v) => v.to_f64() / 1000
		Err(_) => 0
	}

## Hex-encoded UTF-8 back to text.
unhex : Str -> Str
unhex = |word| {
	digits = word.to_utf8()
	value = |c| if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else 0
	var $out = []
	var $k = 0
	while $k + 1 < digits.len() {
		$out = $out.append(value(digits.get($k) ?? '0') * 16 + value(digits.get($k + 1) ?? '0'))
		$k = $k + 2
	}
	Str.from_utf8_lossy($out)
}

expect unhex("41e282ac") == "A€"
expect number("-1500") == -1.5
expect Drawing.black == { red: 0, green: 0, blue: 0 }
