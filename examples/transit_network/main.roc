#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	layout: "../../package/main.roc",
	fixtures: "../data/main.roc",
	svg: "../svg/main.roc",
}
import fixtures.ExampleData
import layout.Graph
import pf.Path
import pf.Stdout
import svg.Svg

fixture = ExampleData.transit_network

padding : F64
padding = 24

render_node = |center, index| {
	size = fixture.graph.nodes.get(index) ?? { width: 0, height: 0 }
	name = fixture.labels.get(index) ?? ""
	cx = center.x + padding
	cy = center.y + padding
	\\${Svg.rect_centered(cx, cy, size.width, size.height, Svg.default_rect_style)}
	\\${Svg.text_centered(cx, cy, name, Svg.default_text_style)}
}

render_route = |route|
	match route {
		Line(from, to) => Svg.line(from.x + padding, from.y + padding, to.x + padding, to.y + padding, Svg.default_line_style)
		Polyline(points) => Svg.polyline(points.map(|point| { x: point.x + padding, y: point.y + padding }), Svg.default_line_style)
		Curves(segments) => Svg.curves(segments.map(|segment| { from: { x: segment.from.x + padding, y: segment.from.y + padding }, ctl_a: { x: segment.ctl_a.x + padding, y: segment.ctl_a.y + padding }, ctl_b: { x: segment.ctl_b.x + padding, y: segment.ctl_b.y + padding }, to: { x: segment.to.x + padding, y: segment.to.y + padding } }), Svg.default_line_style)
	}

main! : List(_) => Try({}, _)
main! = |args| {
	runtime_zero = args.len().to_f64() * 0
	settings = { ..Graph.default_stress_settings, node_gap: 28 + runtime_zero, mode: Exact }
	match Graph.layout_stress(fixture.graph, settings, { ..Graph.default_stress_run, seed: 11 }) {
		Err(problems) => Err(LayoutProblems(problems))
		Ok(result) => {
			layout_ = result.layout
			nodes = Str.join_with(layout_.positions.map_with_index(render_node), "\n")
			routes = Str.join_with(layout_.routes.map(render_route), "\n")
			markup = Svg.square_document(layout_.bounds.width + padding * 2, layout_.bounds.height + padding * 2, "", Str.join_with([routes, nodes], "\n"))
			output = Path.utf8("examples/transit_network/output.svg")
			output.write_utf8!(markup)?
			Stdout.line!("Laid out ${layout_.positions.len().to_str()} transit stops -> ${Path.display(output)}")?
			Ok({})
		}
	}
}
