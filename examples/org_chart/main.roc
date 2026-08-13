#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Geom
import layout.Tree
import svg.Svg

## A small company org chart: a CEO over three functional leads, each with
## their own reports — the shape a real caller building an org-structure
## diagram would actually have. Labels are listed in the same depth-first
## order `Tree.Tidy` numbers nodes in, so `labels.get(i)` names `positions.get(i)`.
node_size = { width: 100, height: 36 }

leaf = |children| { width: node_size.width, height: node_size.height, children }

spec : Tree.Spec
spec = {
	width: node_size.width,
	height: node_size.height,
	children: [
		{
			width: node_size.width,
			height: node_size.height,
			children: [
				leaf([leaf([]), leaf([]), leaf([])]),
				leaf([leaf([])]),
			],
		},
		{
			width: node_size.width,
			height: node_size.height,
			children: [
				leaf([leaf([]), leaf([])]),
			],
		},
		{
			width: node_size.width,
			height: node_size.height,
			children: [
				leaf([]),
			],
		},
	],
}

labels = [
	"CEO",
	"CTO",
	"Eng Manager",
	"Dev 1",
	"Dev 2",
	"Dev 3",
	"QA Lead",
	"QA Engineer",
	"COO",
	"Ops Manager",
	"Ops Analyst 1",
	"Ops Analyst 2",
	"CFO",
	"Accountant",
]

padding = 20

arrow_id = "arrow"

line_style = { ..Svg.default_line_style, marker_end: arrow_id }

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
			Svg.line(from.x + padding, from.y + padding, to.x + padding, to.y + padding, line_style)

		Polyline(points) =>
			Svg.polyline(points.map(|p| { x: p.x + padding, y: p.y + padding }), line_style)

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
				line_style,
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
	defs = Svg.arrow_marker_defs(arrow_id, "#64748b")
	body = Str.join_with([routes, rects], "\n")

	Svg.document(total_width, total_height, defs, body)
}

main! : List(_) => Try({}, _)
main! = |args| {
	runtime_zero = args.len().to_f64() * 0
	settings = { ..Tree.default_settings, sibling_gap: 16, subtree_gap: 32, level_gap: 60 + runtime_zero }
	match Tree.prepare(spec, settings) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(prepared) => {
			result = Tree.layout_prepared(prepared)
			svg = render_svg(result.layout)

			output = Path.utf8("examples/org_chart/output.svg")
			match output.write_utf8!(svg) {
				Err(problem) => Err(WriteFailed(problem))
				Ok({}) =>
					Stdout.line!(
						"Laid out ${result.layout.positions.len().to_str()} nodes -> ${Path.display(output)}",
					)
				}
		}
	}
}
