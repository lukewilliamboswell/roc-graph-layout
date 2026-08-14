#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Compound
import layout.Layered
import svg.Svg

## A production deployment diagram. The browser sits outside three nested
## infrastructure boundaries; each boundary lays out its own contents before
## the root arranges those completed groups as a directed flow. Cross-group
## traffic is routed through the group boundaries with orthogonal segments.
labels = ["Customer", "CDN", "Gateway", "API", "Worker", "Postgres", "Redis", "Queue"]

node_size = { width: 104, height: 36 }

nodes = List.repeat(node_size, labels.len())

edges = [
	{ from: 0, to: 1 },
	{ from: 1, to: 2 },
	{ from: 2, to: 3 },
	{ from: 3, to: 4 },
	{ from: 3, to: 5 },
	{ from: 3, to: 6 },
	{ from: 3, to: 7 },
	{ from: 7, to: 4 },
	{ from: 4, to: 5 },
]

group_defaults = match Compound.default_group {
	Group(spec) => spec
}

edge_group = Group({
	..group_defaults,
	children: [Node(1), Node(2)],
	algorithm: Columns({ gap: 22 }),
	insets: { top: 12, right: 28, bottom: 28, left: 28 },
	header: Reserve({ height: 28 }),
})

application_group = Group({
	..group_defaults,
	children: [Node(3), Node(4), Node(7)],
	algorithm: GraphForce({
		settings: {
			node_gap: 28,
			repulsion: 1,
			gravity: 0.12,
			opening_angle: 0.8,
			max_iterations: 200,
			tolerance: 0.0001,
		},
		pins: [],
	}),
	insets: { top: 14, right: 30, bottom: 30, left: 30 },
	header: Reserve({ height: 28 }),
})

data_group = Group({
	..group_defaults,
	children: [Node(5), Node(6)],
	algorithm: Columns({ gap: 22 }),
	insets: { top: 12, right: 28, bottom: 28, left: 28 },
	header: Reserve({ height: 28 }),
})

root = Group({
	..group_defaults,
	children: [Node(0), Nested(edge_group), Nested(application_group), Nested(data_group)],
	algorithm: LayeredSweep({ settings: { ..Layered.default_settings, node_gap: 34, layer_gap: 72 }, edge_weights: [], min_spans: [] }),
	insets: { top: 14, right: 34, bottom: 34, left: 34 },
	header: Reserve({ height: 30 }),
})

input : Compound.Input
input = {
	graph: { nodes, edges },
	attachments: [],
	group_attachments: [],
	edge_labels: [],
	root,
	routing: Compound.default_routing,
}

padding = 20

group_names = ["PRODUCTION", "EDGE", "APPLICATION", "DATA"]

render_group = |geometry, index| {
	rect = geometry.rect
	x = rect.x + padding
	y = rect.y + padding
	name = group_names.get(index) ?? ""
	fill = if index == 0 {
		"#ffffff"
	} else {
		"#f8fafc"
	}
	stroke = if index == 0 {
		"#cbd5e1"
	} else {
		"#94a3b8"
	}
	header = match geometry.header {
		None => ""
		Some(header_rect) => {
			header_y = header_rect.y + padding
			\\<line x1="${x.to_str()}" y1="${(header_y + header_rect.height).to_str()}" x2="${(x + rect.width).to_str()}" y2="${(header_y + header_rect.height).to_str()}" stroke="${stroke}" stroke-width="1" />
			\\<text x="${(x + 12).to_str()}" y="${(header_y + header_rect.height / 2).to_str()}" dominant-baseline="middle" font-family="sans-serif" font-size="11" font-weight="600" fill="#64748b">${name}</text>
		}
	}
	"<rect x=\"${x.to_str()}\" y=\"${y.to_str()}\" width=\"${rect.width.to_str()}\" height=\"${rect.height.to_str()}\" rx=\"10\" fill=\"${fill}\" stroke=\"${stroke}\" stroke-width=\"1.5\" stroke-dasharray=\"6 4\" />\n${header}"
}

render_node = |center, label| {
	cx = center.x + padding
	cy = center.y + padding
	"${Svg.rect_centered(cx, cy, node_size.width, node_size.height, Svg.default_rect_style)}\n${Svg.text_centered(cx, cy, label, Svg.default_text_style)}"
}

arrow_id = "arrow"

route_style = { ..Svg.default_line_style, marker_end: arrow_id }

render_route = |route|
	match route {
		Line(from, to) => Svg.line(from.x + padding, from.y + padding, to.x + padding, to.y + padding, route_style)
		Polyline(points) => Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), route_style)
		Curves(segments) =>
			Svg.curves(
				segments.map(
					|seg| {
						from: { x: seg.from.x + padding, y: seg.from.y + padding },
						ctl_a: { x: seg.ctl_a.x + padding, y: seg.ctl_a.y + padding },
						ctl_b: { x: seg.ctl_b.x + padding, y: seg.ctl_b.y + padding },
						to: { x: seg.to.x + padding, y: seg.to.y + padding },
					},
				),
				route_style,
			)
		}

render_svg = |result| {
	content_width = result.layout.bounds.width + padding * 2
	content_height = result.layout.bounds.height + padding * 2
	groups = Str.join_with(result.groups.map_with_index(render_group), "\n")
	routes = Str.join_with(result.layout.routes.map(render_route), "\n")
	node_shapes = Str.join_with(result.layout.positions.map_with_index(|p, i| render_node(p, labels.get(i) ?? "")), "\n")
	body = Str.join_with([groups, routes, node_shapes], "\n")
	Svg.square_document(content_width, content_height, Svg.arrow_marker_defs(arrow_id, "#64748b"), body)
}

main! : List(_) => Try({}, _)
main! = |args| {
	seed = if args.is_empty() {
		23
	} else {
		24
	}
	run = { ..Compound.default_run, seed }
	match Compound.layout(input, run) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(result) => {
			svg = render_svg(result)
			output = Path.utf8("examples/cloud_deployment/output.svg")
			match output.write_utf8!(svg) {
				Err(problem) => Err(WriteFailed(problem))
				Ok({}) => Stdout.line!("Laid out ${nodes.len().to_str()} services across ${result.groups.len().to_str()} deployment groups -> ${Path.display(output)}")
			}
		}
	}
}
