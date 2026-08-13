#!/usr/bin/env roc
app [main!] {
	pf: platform "platform/main.roc",
	layout: "../package/main.roc",
	fixtures: "fixtures/main.roc",
}

import pf.Measure
import pf.Stdout
import layout.Compound
import layout.Constrained
import layout.ForceLayout
import layout.Graph
import layout.Layered
import layout.Metrics
import layout.Overlap
import layout.Pack
import layout.RadialLayout
import layout.Route
import layout.StressLayout
import layout.Tree
import fixtures.Embedded
import Generators

arg_at = |args, index, fallback| args.get(index) ?? fallback

parse_u64 = |text, fallback| match U64.from_str(text) {
	Ok(value) => value
	Err(_) => fallback
}

graph_for = |source, fixture, n, seed| if source == "embedded" {
	Embedded.get(fixture)
} else {
	Generators.graph(fixture, n, seed)
}

run_case! = |family, operation, source, fixture, n, seed| {
	graph = graph_for(source, fixture, n, seed)
	if family == "tree_tidy" {
		tree = Generators.tree(fixture, n)
		_ = Measure.start!({})
		result = Tree.layout(tree, Tree.default_settings)
		observation = match result {
			Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + List.len(value.depths)
			Err(problems) => List.len(problems)
		}
		Measure.finish!(observation)
	} else if family == "tree_radial" {
		tree = Generators.tree(fixture, n)
		_ = Measure.start!({})
		result = Tree.layout_radial(tree, Tree.default_radial_settings)
		observation = match result {
			Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + List.len(value.depths)
			Err(problems) => List.len(problems)
		}
		Measure.finish!(observation)
	} else if family == "layered" {
		input = { ..Layered.default_input, graph }
		if operation == "prepared_layout" {
			match Layered.prepare(input, Layered.default_settings) {
				Err(problems) => {
					_ = Measure.start!({})
					Measure.finish!(List.len(problems))
				}
				Ok(prepared) => {
					_ = Measure.start!({})
					result = Layered.layout_prepared(prepared, Layered.default_run)
					Measure.finish!(result.layout.positions.len() + result.layout.routes.len() + result.layers.len())
				}
			}
		} else {
			_ = Measure.start!({})
			result = Layered.layout(input, Layered.default_settings, Layered.default_run)
			observation = match result {
				Ok(value) => value.layout.positions.len() + value.layout.routes.len() + value.layers.len()
				Err(problems) => List.len(problems)
			}
			Measure.finish!(observation)
		}
	} else if family == "circular" {
		_ = Measure.start!({})
		result = Graph.layout_circular(graph, Graph.default_circular_settings)
		observation = match result {
			Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + List.len(value.order)
			Err(problems) => List.len(problems)
		}
		Measure.finish!(observation)
	} else if family == "force" {
		settings = { ..ForceLayout.force_defaults, max_iterations: 1 }
		if operation == "place_prepared" {
			match ForceLayout.prepare_force(graph, settings) {
				Err(problems) => {
					_ = Measure.start!({})
					Measure.finish!(List.len(problems))
				}
				Ok(prepared) => {
					_ = Measure.start!({})
					result = ForceLayout.place_force(prepared, { ..ForceLayout.force_default_run, seed: seed.to_u32_wrap() })
					Measure.finish!(result.positions.len() + result.components.len() + result.convergence.iterations)
				}
			}
		} else {
			_ = Measure.start!({})
			result = ForceLayout.layout_force(graph, settings, { ..ForceLayout.force_default_run, seed: seed.to_u32_wrap() })
			observation = match result {
				Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + value.convergence.iterations
				Err(problems) => List.len(problems)
			}
			Measure.finish!(observation)
		}
	} else if family == "stress" {
		pivot_count : U64
		pivot_count = n.min(16)
		settings = { ..StressLayout.stress_defaults, mode: Pivots(pivot_count), max_iterations: 1 }
		if operation == "place_prepared" {
			match StressLayout.prepare_stress(graph, settings) {
				Err(problems) => {
					_ = Measure.start!({})
					Measure.finish!(List.len(problems))
				}
				Ok(prepared) => {
					_ = Measure.start!({})
					result = StressLayout.place_stress(prepared, { ..StressLayout.stress_default_run, seed: seed.to_u32_wrap() })
					Measure.finish!(result.positions.len() + result.components.len() + result.convergence.iterations)
				}
			}
		} else {
			_ = Measure.start!({})
			result = StressLayout.layout_stress(graph, settings, { ..StressLayout.stress_default_run, seed: seed.to_u32_wrap() })
			observation = match result {
				Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + value.convergence.iterations
				Err(problems) => List.len(problems)
			}
			Measure.finish!(observation)
		}
	} else if family == "radial" {
		_ = Measure.start!({})
		result = RadialLayout.layout_radial(graph, RadialLayout.radial_defaults)
		observation = match result {
			Ok(value) => List.len(value.layout.positions) + List.len(value.layout.routes) + List.len(value.rings)
			Err(problems) => List.len(problems)
		}
		Measure.finish!(observation)
	} else if family == "constrained" {
		input = { graph, constraints: [] }
		settings = { ..Constrained.default_settings, max_iterations: 1 }
		_ = Measure.start!({})
		result = Constrained.layout(input, settings, { ..Constrained.default_run, seed: seed.to_u32_wrap() })
		observation = match result {
			Ok(value) => value.layout.positions.len() + value.layout.routes.len() + value.convergence.iterations
			Err(problems) => List.len(problems)
		}
		Measure.finish!(observation)
	} else if family == "overlap" {
		positions = Generators.positions(fixture, n)
		sizes = List.repeat({ width: 24, height: 16 }, n)
		_ = Measure.start!({})
		result = Overlap.remove(positions, sizes, 4)
		Measure.finish!(result.len())
	} else if family == "pack" {
		boxes = List.repeat({ width: 24, height: 16 }, n)
		_ = Measure.start!({})
		result = Pack.pack(boxes, Pack.default_settings)
		Measure.finish!(result.positions.len() + result.bounds.width.to_u64_wrap())
	} else if family == "compound" {
		boxes = List.repeat({ width: 24, height: 16 }, n)
		children = List.repeat(0, n).map_with_index(|_, i| Node(i))
		root = Group({ children, algorithm: Rows({ gap: 4 }), padding: 16, min_width: 0, min_height: 0 })
		input = { ..Compound.default_input, graph: { nodes: boxes, edges: [] }, root }
		_ = Measure.start!({})
		result = Compound.layout(input, Compound.default_run)
		observation = match result {
			Ok(value) => value.layout.positions.len() + value.groups.len()
			Err(problems) => problems.len()
		}
		Measure.finish!(observation)
	} else if family == "route" {
		positions = List.repeat(0, n + 1).map_with_index(|_, i| { x: i.to_f64() * 40, y: 0 })
		nodes = List.repeat({ width: 24, height: 16 }, n + 1)
		edges = List.repeat(0, n).map_with_index(|_, i| { from: i, to: i + 1 })
		input = { ..Route.default_input, graph: { nodes, edges }, positions }
		_ = Measure.start!({})
		result = Route.orthogonal(input, Route.default_settings)
		observation = match result {
			Ok(value) => value.layout.routes.len() + value.layout.positions.len()
			Err(problems) => problems.len()
		}
		Measure.finish!(observation)
	} else {
		routes = Generators.routes(fixture, n)
		_ = Measure.start!({})
		value = if family == "metrics_bends" {
			Metrics.bends(routes)
		} else {
			Metrics.crossings(routes)
		}
		Measure.finish!(value)
	}
}

main! = |args| {
	family = arg_at(args, 1, "tree_tidy")
	operation = arg_at(args, 2, "one_call")
	source = arg_at(args, 3, "generated")
	fixture = arg_at(args, 4, "chain")
	n = parse_u64(arg_at(args, 5, "1"), 1)
	seed = parse_u64(arg_at(args, 6, "0"), 0)
	telemetry = run_case!(family, operation, source, fixture, n, seed)
	m = if family == "tree_tidy" or family == "tree_radial" {
		if n > 0 {
			n - 1
		} else {
			0
		}
	} else {
		(graph_for(source, fixture, n, seed)).edges.len()
	}
	line = Str.join_with(
		[
			telemetry,
			\\,"family":"${family}","operation":"${operation}","fixture":"${fixture}","n":${n.to_str()},"m":${m.to_str()},"digest":${Str.count_utf8_bytes(telemetry).to_str()}}
			,
		],
		"",
	)
	Stdout.line!(line)
}
