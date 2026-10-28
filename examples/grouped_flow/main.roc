#!/usr/bin/env roc
app [main!] {
	layout: "../../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import layout.Layered
import pf.Stdout

## A coordinated flow with a nested subsystem, a cross-boundary edge, a
## group endpoint and a measured edge label. This uses only the geometry
## package; a caller can draw the returned rectangles and polylines anywhere.
input : Layered.GroupedInput
input = {
	..Layered.default_grouped_input,
	nodes: [{ width: 80, height: 30 }, { width: 100, height: 40 }, { width: 60, height: 35 }],
	edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }, { from: Node(0), to: Group(1) }],
	edge_labels: [{ edge: 0, width: 45, height: 18 }],
	root: Group({
		children: [
			Node(0),
			Nested(
				Group({
					children: [Node(1), Node(2)],
					flow: Together,
					spacing: Inherit,
					padding: { top: 24, right: 16, bottom: 16, left: 16 },
					min_width: 120,
					min_height: 60,
					label: Some({ width: 90, height: 18 }),
				}),
			),
		],
		flow: Together,
		spacing: Inherit,
		padding: { top: 12, right: 12, bottom: 12, left: 12 },
		min_width: 0,
		min_height: 0,
		label: None,
	}),
}

main! : List(_) => Try({}, _)
main! = |args| match Layered.layout_grouped(input, { ..Layered.default_grouped_settings, direction: if (args.is_empty()) Down else Right }, Layered.default_grouped_run) {
	Err(problems) => Err(InvalidDiagram(Str.inspect(problems)))
	Ok(result) => Stdout.line!(Str.inspect(result))
}

expect match Layered.prepare_grouped(input, Layered.default_grouped_settings) {
	Err(_) => False
	Ok(prepared) => {
		result = Layered.layout_grouped_prepared(prepared, Layered.default_grouped_run)
		result.nodes.len() == 3 and result.groups.len() == 2 and result.layout.routes.len() == 3 and result.label_anchors.len() == 1
			and Layered.layout_grouped(input, Layered.default_grouped_settings, Layered.default_grouped_run) == Ok(result)
	}
}
