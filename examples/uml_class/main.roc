#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Layered
import layout.Route
import svg.Svg

## Acceptance example for authored layers, stable sibling order, an elliptical
## boundary, several labels on one association, and a shared inheritance
## trunk. Layered supplies authored rows and order; Route adds the UML-specific
## shared end without changing those positions.
names = ["Payment", "CardPayment", "BankTransfer", "CashPayment", "Customer"]

nodes = [{ width: 120, height: 48 }, { width: 120, height: 48 }, { width: 120, height: 48 }, { width: 120, height: 48 }, { width: 112, height: 64 }]

edges = [{ from: 1, to: 0 }, { from: 2, to: 0 }, { from: 3, to: 0 }, { from: 4, to: 1 }]

label_specs = [
	{ edge: 3, width: 54, height: 18, placement: Center },
	{ edge: 3, width: 18, height: 18, placement: Near(From) },
	{ edge: 3, width: 26, height: 18, placement: Near(To) },
]

label_text = ["uses", "1", "0..*"]

input : Layered.Input
input = {
	..Layered.default_input,
	graph: { nodes, edges },
	boundaries: [{ node: 4, outline: Ellipse }],
	edge_labels: label_specs,
	layer_constraints: [SameLayer({ first: 4, second: 1 }), SameLayer({ first: 1, second: 2 }), SameLayer({ first: 2, second: 3 })],
	order_constraints: [{ before: 4, after: 1 }, { before: 1, after: 2 }, { before: 2, after: 3 }],
	non_ranking_edges: [3],
}

padding = 28

route_svg = |route, marker| {
	style = { ..Svg.default_line_style, marker_end: marker }
	match route {
		Line(a, b) => Svg.line(a.x + padding, a.y + padding, b.x + padding, b.y + padding, style)
		Polyline(points) => Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), style)
		Curves(parts) => Svg.curves(parts.map(|s| { from: { x: s.from.x + padding, y: s.from.y + padding }, ctl_a: { x: s.ctl_a.x + padding, y: s.ctl_a.y + padding }, ctl_b: { x: s.ctl_b.x + padding, y: s.ctl_b.y + padding }, to: { x: s.to.x + padding, y: s.to.y + padding } }), style)
	}
}

main! = |args| match Layered.layout(input, { ..Layered.default_settings, direction: Up, node_gap: 96 + args.len().to_f64(), layer_gap: 90 }, Layered.default_run) {
	Err(problems) => Err(LayoutProblems(problems))
	Ok(placed) => {
		route_input = { ..Route.default_input, graph: { nodes, edges }, positions: placed.layout.positions, boundaries: [{ node: 4, outline: Ellipse }], edge_labels: label_specs, shared_ends: [{ edges: [0, 1, 2], endpoint: To, attachment: On(Bottom) }] }
		match Route.layout(route_input, Route.default_settings) {
			Err(problems) => Err(RouteProblems(problems))
			Ok(result) => {
				# Shared branches meet without arrowheads; the one trunk carries the
				# relationship's arrow to Payment. The association keeps its own.
				routes = Str.join_with(
					result.layout.routes.map_with_index(
						|route, i| route_svg(
							route,
							if i < 3 {
								""
							} else {
								"arrow"
							},
						),
					),
					"\n",
				)
				trunks = Str.join_with(result.shared_routes.map(|shared| route_svg(shared.trunk, "arrow")), "\n")
				shapes = Str.join_with(
					result.layout.positions.map_with_index(
						|p, i| {
							cx = p.x + padding
							cy = p.y + padding
							shape = if i == 4 {
								"<ellipse cx=\"${cx.to_str()}\" cy=\"${cy.to_str()}\" rx=\"56\" ry=\"32\" fill=\"#eef2ff\" stroke=\"#4338ca\" stroke-width=\"2\" />"
							} else {
								Svg.rect_centered(cx, cy, 120, 48, Svg.default_rect_style)
							}
							"${shape}\n${Svg.text_centered(cx, cy, names.get(i) ?? "", Svg.default_text_style)}"
						},
					),
					"\n",
				)
				labels = Str.join_with(result.label_anchors.map_with_index(|p, i| "<text x=\"${(p.x + padding).to_str()}\" y=\"${(p.y + padding).to_str()}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"sans-serif\" font-size=\"11\" fill=\"#334155\">${label_text.get(i) ?? ""}</text>"), "\n")
				doc = Svg.square_document(result.layout.bounds.width + padding * 2, result.layout.bounds.height + padding * 2, Svg.arrow_marker_defs("arrow", "#64748b"), Str.join_with([routes, trunks, shapes, labels], "\n"))
				output = Path.utf8("examples/uml_class/output.svg")
				match output.write_utf8!(doc) {
					Err(problem) => Err(WriteFailed(problem))
					Ok({}) => Stdout.line!("Generated UML class acceptance diagram -> ${Path.display(output)}")
				}
			}
		}
	}
}
