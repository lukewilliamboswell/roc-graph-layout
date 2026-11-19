import layout.Layered
import pf.Measure

## Benchmark consumer of the public coordinated-flow API. Keeping this
## fixture outside the dispatch runner allows focused optimized controls.
GroupedBench :: {}.{
	Graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }
	run! : Graph, Str, Str, U64 => Str
	run! = |graph, fixture, operation, seed| {
		members = List.repeat(0, graph.nodes.len()).map_with_index(|_, i| Node(i))
		half = graph.nodes.len() / 2
		child = Layered.group({ ..Layered.default_group_options, children: members.take_first(half), padding: { top: 12, right: 12, bottom: 12, left: 12 } })
		root = Layered.group({ ..Layered.default_group_options, children: [Nested(child)].concat(members.drop_first(half)) })
		witness = fixture == "model_order"
		witness_groups = if witness {
			List.repeat(0, graph.nodes.len() / 3).map_with_index(
				|_, copy| {
					inside = List.repeat(0, 3).map_with_index(|_, i| copy * 3 + i).keep_if(|i| i % 2 == 1).map(|i| Node(i))
					inner = Layered.group({ ..Layered.default_group_options, children: inside, padding: { top: 12, right: 12, bottom: 12, left: 12 } })
					Nested(Layered.group({ ..Layered.default_group_options, children: [Nested(inner)], padding: { top: 12, right: 12, bottom: 12, left: 12 } }))
				},
			)
		} else {
			[]
		}
		witness_root = Layered.group({ ..Layered.default_group_options, children: List.repeat(0, graph.nodes.len()).map_with_index(|_, i| i).keep_if(|i| i % 2 == 0).map(|i| Node(i)).concat(witness_groups) })
		input = {
			..Layered.default_grouped_input,
			nodes: graph.nodes,
			edges: graph.edges.map(|edge| { from: Node(edge.from), to: Node(edge.to) }),
			root: if witness {
				witness_root
			} else {
				root
			},
			edge_labels: if witness {
				List.repeat(0, graph.edges.len()).map_with_index(|_, i| i).keep_if(|i| i % 3 == 0).map(|edge| { edge, width: ([10.0, 10.0, 3.0, 8.0].get((21 + edge % 10) % 4) ?? 10), height: 17 })
			} else {
				[]
			},
		}
		settings = if witness {
			{ ..Layered.default_grouped_settings, direction: Right }
		} else {
			Layered.default_grouped_settings
		}
		args = { ..Layered.default_grouped_run, seed: seed.to_u32_wrap() }
		if operation == "zero" {
			_ = Measure.start!({})
			Measure.finish!(0)
		} else if operation == "prepared_layout" {
			match Layered.prepare_grouped(input, settings) {
				Err(_) => crash "valid grouped benchmark input was rejected"
				Ok(prepared) => {
					_ = Measure.start!({})
					result = Layered.layout_grouped_prepared(prepared, args)
					Measure.finish!(result.nodes.len() + result.layout.routes.len() + result.groups.len())
				}
			}
		} else {
			_ = Measure.start!({})
			result = Layered.layout_grouped(input, settings, args)
			observation = match result {
				Ok(value) => value.nodes.len() + value.layout.routes.len() + value.groups.len()
				Err(_) => crash "valid grouped benchmark input was rejected"
			}
			Measure.finish!(observation)
		}
	}
}
