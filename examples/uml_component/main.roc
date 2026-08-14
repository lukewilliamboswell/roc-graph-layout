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

## Acceptance example for package headers, nested components, labelled
## relationships, and authored boundary portals. A good result keeps every
## route out of the reserved headers and makes the two package crossings
## visually distinct.
names = ["Web application", "Orders API", "Inventory API", "Orders DB"]

nodes = List.repeat({ width: 126, height: 44 }, names.len())

edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 1, to: 3 }]

defaults = match Compound.default_group {
	Group(spec) => spec
}

client = Group({ ..defaults, children: [Node(0)], insets: { top: 16, right: 60, bottom: 24, left: 28 }, header: Reserve({ height: 32 }) })

services = Group({ ..defaults, children: [Node(1), Node(2)], algorithm: Rows({ gap: 34 }), insets: { top: 16, right: 30, bottom: 28, left: 30 }, header: Reserve({ height: 32 }) })

data = Group({ ..defaults, children: [Node(3)], insets: { top: 16, right: 28, bottom: 24, left: 28 }, header: Reserve({ height: 32 }) })

root = Group({ ..defaults, children: [Nested(client), Nested(services), Nested(data)], algorithm: LayeredSweep({ ..Compound.default_layered, settings: { ..Layered.default_settings, direction: Right, node_gap: 46, layer_gap: 86 } }), insets: { top: 18, right: 34, bottom: 34, left: 34 }, header: Reserve({ height: 36 }) })

label_specs = [
	{ edge: 0, width: 72, height: 18, placement: Center },
	{ edge: 0, width: 42, height: 18, placement: Near(From) },
]

label_text = ["HTTPS", "client"]

input : Compound.Input
input = {
	graph: { nodes, edges },
	attachments: [],
	boundaries: [],
	edge_labels: label_specs,
	# Group indices are root-first: CLIENT=1, SERVICES=2, DATA=3.
	group_attachments: [
		{ edge: 0, group: 1, attachment: On(Right) },
		{ edge: 0, group: 2, attachment: On(Left) },
		{ edge: 2, group: 2, attachment: On(Right) },
		{ edge: 2, group: 3, attachment: On(Left) },
	],
	root,
	routing: Compound.default_routing,
}

padding = 24

group_names = ["ORDERING SYSTEM", "CLIENT", "SERVICES", "DATA"]

route_svg = |route| {
	style = { ..Svg.default_line_style, marker_end: "arrow" }
	match route {
		Line(a, b) => Svg.line(a.x + padding, a.y + padding, b.x + padding, b.y + padding, style)
		Polyline(points) => Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), style)
		Curves(parts) => Svg.curves(parts.map(|s| { from: { x: s.from.x + padding, y: s.from.y + padding }, ctl_a: { x: s.ctl_a.x + padding, y: s.ctl_a.y + padding }, ctl_b: { x: s.ctl_b.x + padding, y: s.ctl_b.y + padding }, to: { x: s.to.x + padding, y: s.to.y + padding } }), style)
	}
}

group_svg = |geometry, index| {
	r = geometry.rect
	x = r.x + padding
	y = r.y + padding
	title = group_names.get(index) ?? ""
	separator = match geometry.header {
		None => ""
		Some(h) => "<line x1=\"${x.to_str()}\" y1=\"${(h.y + h.height + padding).to_str()}\" x2=\"${(x + r.width).to_str()}\" y2=\"${(h.y + h.height + padding).to_str()}\" stroke=\"#94a3b8\" />"
	}
	"<rect x=\"${x.to_str()}\" y=\"${y.to_str()}\" width=\"${r.width.to_str()}\" height=\"${r.height.to_str()}\" rx=\"8\" fill=\"#f8fafc\" stroke=\"#64748b\" stroke-width=\"1.5\" />\n${separator}\n<text x=\"${(x + 12).to_str()}\" y=\"${(y + 18).to_str()}\" font-family=\"sans-serif\" font-size=\"11\" font-weight=\"600\" fill=\"#475569\">${title}</text>"
}

main! = |args| match Compound.layout(input, { ..Compound.default_run, seed: args.len().to_u32_wrap() }) {
	Err(problems) => Err(LayoutProblems(problems))
	Ok(result) => {
		groups = Str.join_with(result.groups.map_with_index(group_svg), "\n")
		routes = Str.join_with(result.layout.routes.map(route_svg), "\n")
		shapes = Str.join_with(result.layout.positions.map_with_index(|p, i| "${Svg.rect_centered(p.x + padding, p.y + padding, 126, 44, Svg.default_rect_style)}\n${Svg.text_centered(p.x + padding, p.y + padding, names.get(i) ?? "", Svg.default_text_style)}"), "\n")
		labels = Str.join_with(
			result.label_anchors.map_with_index(
				|p, i| {
					spec = label_specs.get(i) ?? { edge: 0, width: 0, height: 0, placement: Center }
					Svg.edge_label_centered(p.x + padding, p.y + padding, spec.width, spec.height, label_text.get(i) ?? "", { ..Svg.default_text_style, font_size: 11, fill: "#334155" })
				},
			),
			"\n",
		)
		doc = Svg.square_document(result.layout.bounds.width + padding * 2, result.layout.bounds.height + padding * 2, Svg.arrow_marker_defs("arrow", "#64748b"), Str.join_with([groups, routes, shapes, labels], "\n"))
		output = Path.utf8("examples/uml_component/output.svg")
		match output.write_utf8!(doc) {
			Err(problem) => Err(WriteFailed(problem))
			Ok({}) => Stdout.line!("Generated UML component acceptance diagram -> ${Path.display(output)}")
		}
	}
}
