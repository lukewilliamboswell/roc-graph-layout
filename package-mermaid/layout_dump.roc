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
import FlowLayoutElk
import FlowLayoutGraph
import FlowLayoutImport
import FlowLayoutLayers
import FlowLayoutPlace

## Prints one JSON line of layout geometry for each case file given, for
## `tools/mermaid-oracle/score.mjs`. A case file holds Mermaid source, a NUL
## byte, then one size per line, tab separated, in thousandths of a pixel:
##
##     node <id> <width> <height>
##     edge <index> <width> <height>
##     group <id> <width> <height>
##
## Parts without a line get size zero; edges without a line have no label.
##
## With `--layers` first, prints instead each graph's layers after ordering,
## as text, for comparison with the layout engine's own. With `--raw` first,
## prints the engine's result before Mermaid's adjustments, in the same JSON.
## With `--stop=parse`, `--stop=import`, `--stop=layers` or `--stop=order`
## first, runs only that far and prints a count, for timing phases.
## With `--synthetic` first, each further argument is `<kind>-<nodes>` (kind
## `mixed`, `chain` or `wide`) naming a diagram built directly, past the
## parser's edge limit, laid out in full for timing; it prints a count.
main! = |args| {
	names = args.map(OsStr.display)
	layers_only = names.first() == Ok("--layers")
	raw = names.first() == Ok("--raw")
	stop = match names.first() {
		Ok(first) => if (first.starts_with("--stop=")) Some(first.drop_prefix("--stop=")) else None
		Err(_) => None
	}
	synthetic_stop = match names.first() {
		Ok(first) => if (first.starts_with("--synthetic")) Some(first.drop_prefix("--synthetic").drop_prefix("=")) else None
		Err(_) => None
	}
	if synthetic_stop != None {
		for name in names.drop_first(1) {
			diagram = synthetic(name)
			box = { width: 152, height: 41, label: { lines: [], width: 0, height: 0 } }
			sizes = {
				nodes: List.repeat(box, diagram.nodes.len()),
				edge_labels: diagram.edges.map(|e| if (e.label.is_empty()) None else Some({ lines: [], width: 30, height: 17 })),
				group_titles: List.repeat({ lines: [], width: 60, height: 17 }, diagram.groups.len()),
			}
			phase = match synthetic_stop {
				Some(p) => p
				None => ""
			}
			if phase == "" {
				g = FlowLayout.layout(diagram, sizes)
				Stdout.line!("${name} ${g.edges.fold(0, |acc, e| acc + e.points.len()).to_str()} points")?
			} else {
				Stdout.line!("${name} ${run_phase(diagram, sizes, phase)}")?
			}
		}
		return Ok({})
	}
	for name in if (layers_only or raw or stop != None) names.drop_first(1) else names {
		bytes = Path.read_bytes!(Path.utf8(name))?
		phase = match stop {
			Some(p) => p
			None => ""
		}
		if stop != None {
			Stdout.line!("${name} ${phase_count(bytes, phase)}")?
		} else if layers_only {
			Stdout.line!("### ${name}\n${layers_text(bytes)}")?
		} else {
			Stdout.line!("{\"file\":${json(name)},${case_json(bytes, raw)}}")?
		}
	}
	Ok({})
}

## A diagram for timing: `mixed` is a random tree of edges with a fifth
## more edges, a few edges back and a subgraph of 20 nodes in every 40;
## `chain` is one long path with some labels; `wide` is one node with an
## edge to every other.
synthetic : Str -> Flowchart.Diagram
synthetic = |name| {
	parts = name.split_on("-")
	kind = parts.first() ?? "mixed"
	n = (thousandths(parts.get(1) ?? "0") * 1000).floor_to_u64_try() ?? 0
	node = |i, container| { id: "n${i.to_str()}", label: "Node ${i.to_str()}", shape: Rectangle, container, classes: [], styles: [] }
	edge = |a, b, label| { id: "L_${a.to_str()}_${b.to_str()}", from: Node(a), to: Node(b), label, line: Solid, start: None, end: Arrow, length: 1, classes: [], styles: [] }
	group_of = |i| if (kind == "mixed" and i >= 10 and (i - 10) % 40 < 20 and (i - 10) / 40 < (n - 10) / 40) Group((i - 10) / 40) else Root
	group_count = if (kind == "mixed" and n >= 30) (n - 10) / 40 else 0
	var $edges = []
	var $seed = 12345 + n
	next = |seed| (seed * 1103515245 + 12345) % 2147483648
	if kind == "chain" {
		for i in 1..<n {
			$edges = $edges.append(edge(i - 1, i, if ((i - 1) % 7 == 0) "go" else ""))
		}
	} else if kind == "wide" {
		for i in 1..<n {
			$edges = $edges.append(edge(0, i, ""))
		}
	} else {
		for i in 1..<n {
			$seed = next($seed)
			$edges = $edges.append(edge($seed % i, i, if ($seed % 10 == 0) "go" else ""))
			$seed = next($seed)
			if $seed % 5 == 0 {
				$seed = next($seed)
				$edges = $edges.append(edge($seed % i, i, ""))
			}
			$seed = next($seed)
			if $seed % 20 == 0 {
				$seed = next($seed)
				$edges = $edges.append(edge(i, $seed % i, ""))
			}
		}
	}
	{
		direction: Down,
		nodes: List.repeat(0, n).map_with_index(|_, i| node(i, group_of(i))),
		edges: $edges,
		groups: List.repeat(0, group_count).map_with_index(|_, g| { id: "g${g.to_str()}", title: "Group", container: Root, direction: Inherit, classes: [] }),
		classes: [],
	}
}

phase_count : List(U8), Str -> Str
phase_count = |bytes, stop| {
	split = bytes.find_first_index(|b| b == 0) ?? bytes.len()
	source = Str.from_utf8_lossy(bytes.take_first(split))
	table = Str.from_utf8_lossy(bytes.drop_first(split + 1))
	match Flowchart.parse(source) {
		Err(_) => "not accepted"
		Ok(diagram) => run_phase(diagram, read_sizes(diagram, table), stop)
	}
}

## Run layout as far as `stop` and count something, so it is not skipped.
run_phase : Flowchart.Diagram, FlowGeometry.Sizes, Str -> Str
run_phase = |diagram, sizes, stop| {
	{
		{
			if stop == "parse" {
				diagram.nodes.len().to_str()
			} else if stop == "import" {
				FlowLayoutImport.build(diagram, sizes).model.nodes.len().to_str()
			} else if stop == "layers" {
				setup = FlowLayoutImport.build(diagram, sizes)
				var $m = setup.model
				for g in FlowLayoutElk.bottom_up($m) {
					features = FlowLayoutLayers.features($m, g, FlowLayoutElk.vertical(FlowLayoutGraph.graph($m, g).direction))
					$m = FlowLayoutLayers.prepare($m, g, features)
				}
				$m.nodes.len().to_str()
			} else if stop.starts_with("step") {
				# The first steps of preparing each graph, for timing them.
				steps = thousandths(stop.drop_prefix("step")) * 1000
				setup = FlowLayoutImport.build(diagram, sizes)
				var $m = setup.model
				for g in FlowLayoutElk.bottom_up($m) {
					f = FlowLayoutLayers.features($m, g, FlowLayoutElk.vertical(FlowLayoutGraph.graph($m, g).direction))
					if steps >= 1 {
						$m = FlowLayoutLayers.constraint_reverser($m, g)
					}
					if steps >= 2 {
						$m = FlowLayoutLayers.break_cycles($m, g)
					}
					if steps >= 3 and f.center_labels {
						$m = FlowLayoutLayers.insert_label_dummies($m, g, f.vertical)
					}
					if steps >= 4 {
						$m = FlowLayoutLayers.hide_separate($m, g)
					}
					if steps >= 5 {
						$m = FlowLayoutLayers.layer($m, g)
					}
					if steps >= 6 {
						$m = FlowLayoutLayers.restore_constraints($m, g)
					}
					if steps >= 7 {
						$m = FlowLayoutLayers.split_long_edges($m, g)
					}
					if steps >= 8 {
						$m = FlowLayoutLayers.port_sides($m, g)
					}
					if steps >= 9 {
						$m = FlowLayoutLayers.sort_port_lists($m, g)
					}
					if steps >= 10 and f.model_order {
						$m = FlowLayoutLayers.sort_by_model_order($m, g)
					}
				}
				$m.nodes.len().to_str()
			} else if stop == "place" or stop == "bk" {
				r = FlowLayoutElk.ordered_traced(diagram, sizes, False)
				var $m = r.model
				for g in FlowLayoutElk.bottom_up($m) {
					vertical = FlowLayoutElk.vertical(FlowLayoutGraph.graph($m, g).direction)
					$m = FlowLayoutPlace.prepare($m, g, vertical)
					if stop == "bk" {
						$m = FlowLayoutPlace.brandes_koepf($m, g)
					}
				}
				$m.nodes.len().to_str()
			} else if stop == "raw" {
				FlowLayoutElk.layout_raw(diagram, sizes).edges.len().to_str()
			} else {
				FlowLayoutElk.ordered(diagram, sizes).model.nodes.len().to_str()
			}
		}
	}
}

layers_text : List(U8) -> Str
layers_text = |bytes| {
	split = bytes.find_first_index(|b| b == 0) ?? bytes.len()
	source = Str.from_utf8_lossy(bytes.take_first(split))
	table = Str.from_utf8_lossy(bytes.drop_first(split + 1))
	match Flowchart.parse(source) {
		Err(_) => "not accepted"
		Ok(diagram) => {
			sizes = read_sizes(diagram, table)
			result = FlowLayoutElk.ordered_traced(diagram, sizes, True)
			Str.join_with(result.trace, "\n").concat("\n### layers\n").concat(FlowLayoutElk.describe(diagram, result.model))
		}
	}
}

case_json : List(U8), Bool -> Str
case_json = |bytes, raw| {
	split = bytes.find_first_index(|b| b == 0) ?? bytes.len()
	source = Str.from_utf8_lossy(bytes.take_first(split))
	table = Str.from_utf8_lossy(bytes.drop_first(split + 1))
	match Flowchart.parse(source) {
		Err(_) => "\"accepted\":false"
		Ok(diagram) => {
			sizes = read_sizes(diagram, table)
			geometry = if raw {
				r = FlowLayoutElk.layout_raw(diagram, sizes)
				{ bounds: { x: 0, y: 0, width: 0, height: 0 }, nodes: r.nodes, groups: r.groups, edges: r.edges }
			} else {
				FlowLayout.layout(diagram, sizes)
			}
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
