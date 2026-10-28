import Drawing
import Flowchart
import FlowGeometry
import FlowLayout
import FlowTheme
import OracleJson
import Theme

# Internal native probe: JSON facts from the production parser and layout.
FlowchartOracle :: {}.{
	reference_theme : Theme.Options
	reference_theme = Theme.Options.{}
	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| FlowchartOracle.inspect_sized(source, theme, [])
	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, reference| match Flowchart.parse(source) {
		Err(problems) => OracleJson.object([
			("accepted", "false"),
			("family", OracleJson.string("flowchart")),
			(
				"unsupported",
				OracleJson.boolean(
					problems.any(
						|problem| match problem {
							Unsupported(_) => True
							_ => False
						},
					),
				),
			),
		])
		Ok(d) => {
			native = FlowTheme.sizes(d, theme)
			sizes = {
				nodes: native.nodes.map_with_index(
					|n, i| {
						id = (d.nodes.get(i) ?? crash "aligned node").id
						match reference.find_first(|s| s.kind == "node" and s.id == id) {
							Ok(s) => { ..n, width: s.width, height: s.height }
							Err(_) => n
						}
					},
				),
				edge_labels: native.edge_labels.map_with_index(
					|label, i| match label {
						None => None
						Some(block) => {
							id = (d.edges.get(i) ?? crash "aligned edge").id
							match reference.find_first(|s| s.kind == "label" and s.id == id) {
								Ok(s) => Some({ ..block, width: s.width, height: s.height })
								Err(_) => label
							}
						}
					},
				),
				group_titles: native.group_titles.map_with_index(
					|block, i| {
						id = (d.groups.get(i) ?? crash "aligned group").id
						match reference.find_first(|s| s.kind == "group" and s.id == id) {
							Ok(s) => { ..block, width: s.width, height: s.height }
							Err(_) => block
						}
					},
				),
			}
			g = FlowTheme.clip_routes(d, FlowLayout.layout(d, sizes), FlowTheme.radius(theme))
			size_problems = reference.keep_if(
				|size| {
					known = match size.kind {
						"node" => d.nodes.any(|n| n.id == size.id)
						"group" => d.groups.any(|g| g.id == size.id)
						"label" => d.edges.any(|e| e.id == size.id and !e.label.is_empty())
						_ => False
					}
					!known
				},
			).map(|size| "unconsumed ${size.kind}:${size.id}")

			semantic = FlowchartOracle.semantic(d)
			nodes = d.nodes.map_with_index(|n, i| OracleJson.object([("id", OracleJson.string(n.id)), ("box", OracleJson.rect(g.nodes.get(i) ?? crash "aligned node"))]))
			groups = d.groups.map_with_index(|n, i| OracleJson.object([("id", OracleJson.string(n.id)), ("box", OracleJson.rect(g.groups.get(i) ?? crash "aligned group"))]))
			edges = d.edges.map_with_index(
				|e, i| {
					edge = g.edges.get(i) ?? crash "aligned edge"
					OracleJson.object([("id", OracleJson.string(e.id)), ("from", OracleJson.string(FlowchartOracle.endpoint(d, e.from))), ("to", OracleJson.string(FlowchartOracle.endpoint(d, e.to))), ("points", OracleJson.array(edge.points.map(OracleJson.point)))])
				},
			)
			labels = d.edges.map_with_index(
				|e, i| match (sizes.edge_labels.get(i) ?? None, (g.edges.get(i) ?? crash "aligned edge").label) {
					(Some(block), Some(at)) => [OracleJson.object([("id", OracleJson.string(e.id)), ("text", OracleJson.string(e.label)), ("box", OracleJson.rect({ x: at.x - block.width / 2, y: at.y - block.height / 2, width: block.width, height: block.height }))])]
					_ => []
				},
			).fold([], |all, part| all.concat(part))
			OracleJson.object([("accepted", "true"), ("family", OracleJson.string("flowchart")), ("semantic", semantic), ("size_problems", OracleJson.strings(size_problems)), ("geometry", OracleJson.object([("view_box", OracleJson.rect(g.bounds)), ("nodes", OracleJson.array(nodes)), ("groups", OracleJson.array(groups)), ("edges", OracleJson.array(edges)), ("labels", OracleJson.array(labels))]))])
		}
	}
	endpoint : Flowchart.Diagram, Flowchart.Endpoint -> Str
	endpoint = |d, e| match e {
		Node(i) => (d.nodes.get(i) ?? crash "valid endpoint").id
		Group(i) => (d.groups.get(i) ?? crash "valid group").id
	}
	semantic : Flowchart.Diagram -> Str
	semantic = |d| OracleJson.object([
		("direction", OracleJson.string(Str.inspect(d.direction))),
		(
			"nodes",
			OracleJson.array(
				d.nodes.map(
					|v| OracleJson.object([
						("id", OracleJson.string(v.id)),
						("label", OracleJson.string(v.label)),
						("shape", OracleJson.string(Str.inspect(v.shape))),
						("container", OracleJson.string(Str.inspect(v.container))),
						("classes", OracleJson.strings(v.classes)),
						("styles", OracleJson.strings(v.styles)),
					]),
				),
			),
		),
		(
			"edges",
			OracleJson.array(
				d.edges.map(
					|v| OracleJson.object([
						("id", OracleJson.string(v.id)),
						("from", OracleJson.string(Str.inspect(v.from))),
						("to", OracleJson.string(Str.inspect(v.to))),
						("label", OracleJson.string(v.label)),
						("line", OracleJson.string(Str.inspect(v.line))),
						("start", OracleJson.string(Str.inspect(v.start))),
						("end", OracleJson.string(Str.inspect(v.end))),
						("length", OracleJson.number(v.length.to_f64())),
						("classes", OracleJson.strings(v.classes)),
						("styles", OracleJson.strings(v.styles)),
					]),
				),
			),
		),
		(
			"groups",
			OracleJson.array(
				d.groups.map(
					|v| OracleJson.object([
						("id", OracleJson.string(v.id)),
						("title", OracleJson.string(v.title)),
						("container", OracleJson.string(Str.inspect(v.container))),
						("direction", OracleJson.string(Str.inspect(v.direction))),
						("classes", OracleJson.strings(v.classes)),
					]),
				),
			),
		),
		(
			"classes",
			OracleJson.array(
				d.classes.map(
					|v| OracleJson.object([
						("name", OracleJson.string(v.name)),
						("styles", OracleJson.strings(v.styles)),
					]),
				),
			),
		),
	])
}
