#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Constrained
import layout.Route
import svg.Svg

## A release workflow split into responsibility lanes. Fixed y bands keep
## work with Product, Engineering, Security, or Operations; x alignments put
## concurrent work in the same stage; separations preserve left-to-right
## progress while stress keeps connected tasks close within those rules. A
## separate orthogonal routing pass turns that placement into square lane
## crossings without making routing a Constrained setting.
labels = [
	"Release brief",
	"Plan approved",
	"Build",
	"Test",
	"Threat model",
	"Security review",
	"Release approval",
	"Deploy",
	"Monitor",
]

node_size = { width: 116, height: 34 }

nodes = List.repeat(node_size, labels.len())

edges = [
	{ from: 0, to: 1 },
	{ from: 1, to: 2 },
	{ from: 1, to: 4 },
	{ from: 2, to: 3 },
	{ from: 3, to: 5 },
	{ from: 4, to: 5 },
	{ from: 5, to: 6 },
	{ from: 6, to: 7 },
	{ from: 7, to: 8 },
]

lane_y = { product: 60, engineering: 160, security: 260, operations: 360 }

constraints : List(Constrained.Constraint)
constraints = [
	Inside({ axis: Y, nodes: [0, 1, 6], low: lane_y.product, high: lane_y.product }),
	Inside({ axis: Y, nodes: [2, 3], low: lane_y.engineering, high: lane_y.engineering }),
	Inside({ axis: Y, nodes: [4, 5], low: lane_y.security, high: lane_y.security }),
	Inside({ axis: Y, nodes: [7, 8], low: lane_y.operations, high: lane_y.operations }),
	Align({ axis: X, nodes: [2, 4] }),
	Align({ axis: X, nodes: [3, 5] }),
	Separate({ axis: X, first: 0, second: 1, gap: 150 }),
	Separate({ axis: X, first: 1, second: 2, gap: 150 }),
	Separate({ axis: X, first: 2, second: 3, gap: 150 }),
	Separate({ axis: X, first: 3, second: 6, gap: 150 }),
	Separate({ axis: X, first: 6, second: 7, gap: 150 }),
	Separate({ axis: X, first: 7, second: 8, gap: 150 }),
]

padding : F64
padding = 24

lane_left : F64
lane_left = 8

lane_height : F64
lane_height = 72

render_lanes = |width, centers| {
	lane = |name, y, fill| {
		top = y - lane_height / 2
		\\<rect x="${lane_left.to_str()}" y="${top.to_str()}" width="${(width - lane_left * 2).to_str()}" height="${lane_height.to_str()}" rx="6" fill="${fill}" />
		\\<text x="${(lane_left + 10).to_str()}" y="${(top + 18).to_str()}" font-family="sans-serif" font-size="12" font-weight="600" fill="#475569">${name}</text>
	}
	Str.join_with(
		[
			lane("PRODUCT", centers.product, "#f8fafc"),
			lane("ENGINEERING", centers.engineering, "#f1f5f9"),
			lane("SECURITY", centers.security, "#f8fafc"),
			lane("OPERATIONS", centers.operations, "#f1f5f9"),
		],
		"\n",
	)
}

render_node = |center, label, offset| {
	cx = center.x + offset.x
	cy = center.y + offset.y
	"${Svg.rect_centered(cx, cy, node_size.width, node_size.height, Svg.default_rect_style)}\n${Svg.text_centered(cx, cy, label, Svg.default_text_style)}"
}

arrow_id = "arrow"

route_style = { ..Svg.default_line_style, marker_end: arrow_id }

render_route = |route, offset|
	match route {
		Line(from, to) => Svg.line(from.x + offset.x, from.y + offset.y, to.x + offset.x, to.y + offset.y, route_style)
		Polyline(points) => Svg.polyline(points.map(|p| { x: p.x + offset.x, y: p.y + offset.y }), route_style)
		Curves(segments) =>
			Svg.curves(
				segments.map(
					|seg| {
						from: { x: seg.from.x + offset.x, y: seg.from.y + offset.y },
						ctl_a: { x: seg.ctl_a.x + offset.x, y: seg.ctl_a.y + offset.y },
						ctl_b: { x: seg.ctl_b.x + offset.x, y: seg.ctl_b.y + offset.y },
						to: { x: seg.to.x + offset.x, y: seg.to.y + offset.y },
					},
				),
				route_style,
			)
		}

render_svg = |result| {
	total_width = result.bounds.width + padding * 2
	total_height = result.bounds.height + padding * 2
	offset = { x: padding - result.bounds.x, y: padding - result.bounds.y }
	centers = {
		product: (result.positions.get(0) ?? { x: 0, y: 0 }).y + offset.y,
		engineering: (result.positions.get(2) ?? { x: 0, y: 0 }).y + offset.y,
		security: (result.positions.get(4) ?? { x: 0, y: 0 }).y + offset.y,
		operations: (result.positions.get(7) ?? { x: 0, y: 0 }).y + offset.y,
	}
	lanes = render_lanes(total_width, centers)
	routes = Str.join_with(result.routes.map(|route| render_route(route, offset)), "\n")
	node_shapes = Str.join_with(result.positions.map_with_index(|p, i| render_node(p, labels.get(i) ?? "", offset)), "\n")
	Svg.square_document(total_width, total_height, Svg.arrow_marker_defs(arrow_id, "#64748b"), Str.join_with([lanes, routes, node_shapes], "\n"))
}

main! : List(_) => Try({}, _)
main! = |args| {
	runtime_zero = args.len().to_f64() * 0
	input = { graph: { nodes, edges }, constraints }
	settings = { ..Constrained.default_settings, node_gap: 36 + runtime_zero }
	match Constrained.layout(input, settings, { ..Constrained.default_run, seed: 11 }) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(result) => match Route.layout({ ..Route.default_input, graph: { nodes, edges }, positions: result.layout.positions }, Route.default_settings) {
			Err(problems) => Err(RouteProblems(problems))
			Ok(routed) => {
				svg = render_svg(routed.layout)
				output = Path.utf8("examples/release_workflow/output.svg")
				match output.write_utf8!(svg) {
					Err(problem) => Err(WriteFailed(problem))
					Ok({}) => Stdout.line!("Laid out a ${labels.len().to_str()}-step release across four responsibility lanes -> ${Path.display(output)}")
				}
			}
		}
	}
}
