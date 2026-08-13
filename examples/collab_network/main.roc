#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Graph
import svg.Svg

## A collaboration network: two tight teams bridged by one shared member,
## plus a contractor pair off to the side — the organic reading
## `Graph.layout_force` serves, where clusters emerge from connectivity and
## the disconnected pair packs beside the main component. Labels are listed
## in node order, so `labels.get(i)` names `positions.get(i)`.
node_size = { width: 86, height: 30 }

labels = [
	"Ada",
	"Grace",
	"Alan",
	"Edsger",
	"Barbara",
	"Donald",
	"John",
	"Leslie",
	"Contractor A",
	"Contractor B",
]

spec : Graph.Spec
spec = {
	nodes: List.repeat(node_size, labels.len()),
	edges: [
		# team one: Ada, Grace, Alan, Edsger — fully meshed around Ada
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 0, to: 3 },
		{ from: 1, to: 2 },
		{ from: 2, to: 3 },
		# Barbara bridges the teams
		{ from: 0, to: 4 },
		{ from: 4, to: 5 },
		# team two: Donald, John, Leslie
		{ from: 5, to: 6 },
		{ from: 5, to: 7 },
		{ from: 6, to: 7 },
		# the contractors pair off on their own
		{ from: 8, to: 9 },
	],
}

padding = 24

render_node : { x : F64, y : F64 }, Str -> Str
render_node = |center, label| {
	cx = center.x + padding
	cy = center.y + padding

	rect = Svg.rect_centered(cx, cy, node_size.width, node_size.height, Svg.default_rect_style)
	text = Svg.text_centered(cx, cy, label, Svg.default_text_style)

	\\${rect}
	\\${text}
}

render_route : [Line({ x : F64, y : F64 }, { x : F64, y : F64 }), Polyline(List({ x : F64, y : F64 })), Curves(List({ from : { x : F64, y : F64 }, ctl_a : { x : F64, y : F64 }, ctl_b : { x : F64, y : F64 }, to : { x : F64, y : F64 } }))] -> Str
render_route = |route|
	match route {
		Line(from, to) =>
			Svg.line(from.x + padding, from.y + padding, to.x + padding, to.y + padding, Svg.default_line_style)

		Polyline(points) =>
			Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), Svg.default_line_style)

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

render_svg : {
	positions : List({ x : F64, y : F64 }),
	bounds : { x : F64, y : F64, width : F64, height : F64 },
	routes : List([Line({ x : F64, y : F64 }, { x : F64, y : F64 }), Polyline(List({ x : F64, y : F64 })), Curves(List({ from : { x : F64, y : F64 }, ctl_a : { x : F64, y : F64 }, ctl_b : { x : F64, y : F64 }, to : { x : F64, y : F64 } }))]),
} -> Str
render_svg = |result| {
	total_width = result.bounds.width + padding * 2
	total_height = result.bounds.height + padding * 2

	rects = Str.join_with(
		result.positions.map_with_index(|p, i| render_node(p, labels.get(i) ?? "")),
		"\n",
	)

	routes = Str.join_with(result.routes.map(render_route), "\n")
	body = Str.join_with([routes, rects], "\n")

	Svg.document(total_width, total_height, "", body)
}

main! : List(_) => Try({}, _)
main! = |_args| {
	settings = { ..Graph.default_force_settings, node_gap: 40, gravity: 0.15 }
	match Graph.layout_force(spec, settings, { ..Graph.default_force_run, seed: 7 }) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(result) => {
			svg = render_svg(result.layout)

			output = Path.utf8("examples/collab_network/output.svg")
			match output.write_utf8!(svg) {
				Err(problem) => Err(WriteFailed(problem))
				Ok({}) =>
					Stdout.line!(
						"Laid out ${result.layout.positions.len().to_str()} nodes in ${result.convergence.iterations.to_str()} iterations -> ${Path.display(output)}",
					)
				}
		}
	}
}
