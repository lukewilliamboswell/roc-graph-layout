#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	svg: "../svg/main.roc",
}

import pf.Path
import pf.Stdout
import layout.Geom
import layout.Layered
import svg.Svg

## A small build-pipeline-shaped DAG: one source fans out into two
## intermediate stages that both feed a shared build step, which in turn
## feeds two independent downstream consumers. The `fetch -> package` edge
## skips two layers, so it routes through waypoints and (with the default
## settings) renders as a smooth curve.
stages = ["fetch", "compile", "lint", "build", "test", "package", "publish"]

nodes = stages.map(|_| { width: 90, height: 40 })

edges = [
	{ from: 0, to: 1 }, # fetch -> compile
	{ from: 0, to: 2 }, # fetch -> lint
	{ from: 1, to: 3 }, # compile -> build
	{ from: 2, to: 3 }, # lint -> build
	{ from: 3, to: 4 }, # build -> test
	{ from: 3, to: 5 }, # build -> package
	{ from: 4, to: 6 }, # test -> publish
	{ from: 5, to: 6 }, # package -> publish
	{ from: 0, to: 5 }, # fetch -> package (vendored assets skip the build)
]

padding = 20

arrow_id = "arrow"

line_style = { ..Svg.default_line_style, marker_end: arrow_id }

render_node : { x : F64, y : F64 }, { width : F64, height : F64 }, Str -> Str
render_node = |center, size, label| {
	cx = center.x + padding
	cy = center.y + padding

	rect = Svg.rect_centered(cx, cy, size.width, size.height, Svg.default_rect_style)
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
		nodes.map_with_index(
			|size, i| render_node(result.positions.get(i) ?? Geom.point(0, 0), size, stages.get(i) ?? ""),
		),
		"\n",
	)

	routes = Str.join_with(result.routes.map(render_route), "\n")
	defs = Svg.arrow_marker_defs(arrow_id, "#64748b")
	body = Str.join_with([routes, rects], "\n")

	Svg.document(total_width, total_height, defs, body)
}

main! : List(_) => Try({}, _)
main! = |args| {
	graph = { nodes, edges }
	input = { ..Layered.default_input, graph }
	settings = { ..Layered.default_settings, node_gap: 24 + args.len().to_f64(), layer_gap: 70 }
	match Layered.prepare(input, settings) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(prepared) => {
			result = Layered.layout_prepared(prepared, Layered.default_run)
			svg = render_svg(result.layout)

			output = Path.utf8("examples/build_pipeline/output.svg")
			match output.write_utf8!(svg) {
				Err(problem) => Err(WriteFailed(problem))
				Ok({}) =>
					Stdout.line!(
						"Laid out ${nodes.len().to_str()} nodes and ${edges.len().to_str()} edges -> ${Path.display(output)}",
					)
				}
		}
	}
}
