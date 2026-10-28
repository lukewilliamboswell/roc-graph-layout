import layout.Layered

## Measured-layout defaults shared by Mermaid's diagram renderers.
## Custom visual themes remain in the rendering and measurement layer.
DiagramSpacing :: {}.{

	## Spacing at the top level: Mermaid sets a base of 40, which doubles
	## every spacing the engine derives from its base.
	root : Layered.GroupedSpacing
	root = {
		node_node: 40,
		node_node_between_layers: 40,
		edge_node: 20,
		edge_node_between_layers: 20,
		edge_edge: 20,
		edge_edge_between_layers: 20,
		edge_label: 4,
		label_label: 0,
		port_port: 20,
		node_self_loop: 20,
		ports_surrounding: 12,
	}

	## Spacing inside subgraphs: a base of 24, with node, edge and
	## edge-to-layer spacing set on their own.
	inside : Layered.GroupedSpacing
	inside = {
		node_node: 50,
		node_node_between_layers: 24,
		edge_node: 12,
		edge_node_between_layers: 30,
		edge_edge: 20,
		edge_edge_between_layers: 12,
		edge_label: 2.4,
		label_label: 0,
		port_port: 12,
		node_self_loop: 12,
		ports_surrounding: 12,
	}

}
