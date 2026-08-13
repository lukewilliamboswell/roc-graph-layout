#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Geom
import layout.Graph
import svg.Svg

## An incident blast-radius view for a payments outage. `Payments` is the
## explicit root; each ring is another dependency hop away. Unlike a radial
## tree, shared downstream systems may have several parents, so the input is
## an arbitrary graph rather than a hierarchy.
labels = [
	"Payments",
	"Checkout",
	"Orders",
	"Subscriptions",
	"Web Store",
	"Mobile App",
	"Merchant Portal",
	"Fulfillment",
	"Support Console",
	"Finance Export",
	"Notifications",
	"Analytics",
]

node_size = { width: 112, height: 34 }

spec : Graph.Spec
spec = {
	nodes: List.repeat(node_size, labels.len()),
	edges: [
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 0, to: 3 },
		{ from: 1, to: 4 },
		{ from: 1, to: 5 },
		{ from: 1, to: 6 },
		{ from: 2, to: 7 },
		{ from: 2, to: 8 },
		{ from: 2, to: 9 },
		{ from: 3, to: 8 },
		{ from: 3, to: 10 },
		{ from: 7, to: 10 },
		{ from: 9, to: 11 },
		{ from: 10, to: 11 },
	],
}

padding = 24

render_node = |center, label| {
	cx = center.x + padding
	cy = center.y + padding
	rect = Svg.rect_centered(cx, cy, node_size.width, node_size.height, Svg.default_rect_style)
	text = Svg.text_centered(cx, cy, label, Svg.default_text_style)
	"${rect}\n${text}"
}

render_route = |route|
	match route {
		Line(from, to) => Svg.line(from.x + padding, from.y + padding, to.x + padding, to.y + padding, Svg.default_line_style)
		Polyline(points) => Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), Svg.default_line_style)
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
				Svg.default_line_style,
			)
		}

render_svg = |result| {
	total_width = result.bounds.width + padding * 2
	total_height = result.bounds.height + padding * 2
	nodes = Str.join_with(result.positions.map_with_index(|p, i| render_node(p, labels.get(i) ?? "")), "\n")
	routes = Str.join_with(result.routes.map(render_route), "\n")
	Svg.square_document(total_width, total_height, "", Str.join_with([routes, nodes], "\n"))
}

main! : List(_) => Try({}, _)
main! = |args| {
	runtime_zero = args.len().to_f64() * 0
	settings = { ..Graph.default_radial_settings, root: Node(0), ring_gap: 72 + runtime_zero, node_gap: 28 }
	match Graph.layout_radial(spec, settings) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(result) => {
			svg = render_svg(result.layout)
			output = Path.utf8("examples/incident_blast_radius/output.svg")
			match output.write_utf8!(svg) {
				Err(problem) => Err(WriteFailed(problem))
				Ok({}) => Stdout.line!("Mapped ${result.rings.len().to_str()} services by incident distance -> ${Path.display(output)}")
			}
		}
	}
}
