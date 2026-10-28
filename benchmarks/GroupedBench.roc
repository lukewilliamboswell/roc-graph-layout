import layout.Layered
import pf.Measure

## Benchmark consumer of the public coordinated-flow API. Keeping this
## fixture outside the dispatch runner allows focused optimized controls.
GroupedBench :: {}.{
	Graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }
	run! : Graph, Str, U64 => Str
	run! = |graph, operation, seed| {
		members = List.repeat(0, graph.nodes.len()).map_with_index(|_, i| Node(i))
		half = graph.nodes.len() / 2
		child = Layered.group({ ..Layered.default_group_options, children: members.take_first(half), padding: { top: 12, right: 12, bottom: 12, left: 12 } })
		root = Layered.group({ ..Layered.default_group_options, children: [Nested(child)].concat(members.drop_first(half)) })
		input = { ..Layered.default_grouped_input, nodes: graph.nodes, edges: graph.edges.map(|edge| { from: Node(edge.from), to: Node(edge.to) }), root }
		args = { ..Layered.default_grouped_run, seed: seed.to_u32_wrap() }
		if operation == "zero" {
			_ = Measure.start!({})
			Measure.finish!(0)
		} else if operation == "prepared_layout" {
			match Layered.prepare_grouped(input, Layered.default_grouped_settings) {
				Err(_) => crash "valid grouped benchmark input was rejected"
				Ok(prepared) => {
					_ = Measure.start!({})
					result = Layered.layout_grouped_prepared(prepared, args)
					Measure.finish!(result.nodes.len() + result.layout.routes.len() + result.groups.len())
				}
			}
		} else {
			_ = Measure.start!({})
			result = Layered.layout_grouped(input, Layered.default_grouped_settings, args)
			observation = match result {
				Ok(value) => value.nodes.len() + value.layout.routes.len() + value.groups.len()
				Err(_) => crash "valid grouped benchmark input was rejected"
			}
			Measure.finish!(observation)
		}
	}
}
