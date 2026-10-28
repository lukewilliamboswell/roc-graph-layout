import LayeredFlowInput
import LayeredFlowGraph

## Generated structural phase inputs. Regenerate with
## tools/mermaid-oracle/record-phase-fixtures.py and a native oracle_dump.
## All dimensions are authored test measurements; no oracle geometry is read.
LayeredFlowFixtures :: {}.{
	Fixture : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes, registration : List([GroupItem(U64), NodeItem(U64)]) }
	root_spacing : LayeredFlowGraph.Spacing
	root_spacing = { node_node: 40, node_node_between_layers: 40, edge_node: 20, edge_node_between_layers: 20, edge_edge: 20, edge_edge_between_layers: 20, edge_label: 4, label_label: 0, label_node: 10, port_port: 20, node_self_loop: 20, ports_surrounding: 12 }
	group_spacing : LayeredFlowGraph.Spacing
	group_spacing = { node_node: 50, node_node_between_layers: 24, edge_node: 12, edge_node_between_layers: 30, edge_edge: 20, edge_edge_between_layers: 12, edge_label: 2.4, label_label: 0, label_node: 6, port_port: 12, node_self_loop: 12, ports_surrounding: 12 }
	get : Str -> Fixture
	get = |source| match source {
		"flowchart BT\nsubgraph s [Long title]\nA --> B\nend\nB --> D\n" => {
			diagram: { direction: Up, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(2), NodeItem(0), NodeItem(1)],
		}
		"flowchart LR\n    a --> a\n    a -->|retry| a\n    a --> b\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(0) }, { from: Node(0), to: Node(0) }, { from: Node(0), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, Some({ width: 35.26953125, height: 21 }), None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1)],
		}
		"flowchart LR\n    a --> b\n    a --> c\n    a --> d\n    b --> e\n    c --> e\n    d --> e\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(0), to: Node(2) }, { from: Node(0), to: Node(3) }, { from: Node(1), to: Node(4) }, { from: Node(2), to: Node(4) }, { from: Node(3), to: Node(4) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4)],
		}
		"flowchart LR\n    a --> b\n    a --> c\n    d --> b\n    d --> c\n    e --> b\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(0), to: Node(2) }, { from: Node(3), to: Node(1) }, { from: Node(3), to: Node(2) }, { from: Node(4), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4)],
		}
		"flowchart LR\n    a --> b\n    subgraph g [G]\n        c\n    end\n    subgraph h [H]\n        d\n    end\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Group(0) }, { container: Group(1) }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }, { container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }], edges: [{ from: Node(0), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None], group_titles: [{ width: 10, height: 15 }, { width: 10, height: 15 }] },
			registration: [GroupItem(1), GroupItem(0), NodeItem(0), NodeItem(1), NodeItem(3), NodeItem(2)],
		}
		"flowchart LR\n    a --> b --> c\n    a --> c\n    c --> a\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }, { from: Node(0), to: Node(2) }, { from: Node(2), to: Node(0) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2)],
		}
		"flowchart LR\n    a --> b --> c\n    a --> c\n    d --> b\n    d --> e --> c\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }, { from: Node(0), to: Node(2) }, { from: Node(3), to: Node(1) }, { from: Node(3), to: Node(4) }, { from: Node(4), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4)],
		}
		"flowchart LR\n    a --> b --> c --> d\n    a --> d\n    d --> b\n    a -->|go| c\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }, { from: Node(2), to: Node(3) }, { from: Node(0), to: Node(3) }, { from: Node(3), to: Node(1) }, { from: Node(0), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None, None, Some({ width: 35.26953125, height: 21 })], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3)],
		}
		"flowchart LR\n    a --> d\n    b --> c\n    a --> c\n    b --> d\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(2), to: Node(3) }, { from: Node(0), to: Node(3) }, { from: Node(2), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3)],
		}
		"flowchart LR\n    a -->|go| b\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [Some({ width: 35.26953125, height: 21 })], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1)],
		}
		"flowchart LR\n    r --> z\n    r --> y\n    r --> x\n    q --> y\n" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(0), to: Node(2) }, { from: Node(0), to: Node(3) }, { from: Node(4), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4)],
		}
		"flowchart LR\na --> b\nb --> a\na --> b\na --> a\nsubgraph g [Group]\nc --> d\nend\nisolated" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(0) }, { from: Node(0), to: Node(1) }, { from: Node(0), to: Node(0) }, { from: Node(2), to: Node(3) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(0), NodeItem(1), NodeItem(4), NodeItem(2), NodeItem(3)],
		}
		"flowchart LR\nsubgraph s [Long title]\nA --> B\nend\nB --> D\n" => {
			diagram: { direction: Right, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(2), NodeItem(0), NodeItem(1)],
		}
		"flowchart RL\nsubgraph s [Long title]\nA --> B\nend\nB --> D\n" => {
			diagram: { direction: Left, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(2), NodeItem(0), NodeItem(1)],
		}
		"flowchart TD\n    a --> e\n    subgraph e [E]\n    end\n" => {
			diagram: { direction: Down, nodes: [{ container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 0 }], edges: [{ from: Node(0), to: Group(0) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }], edge_labels: [None], group_titles: [{ width: 0, height: 0 }] },
			registration: [GroupItem(0), NodeItem(0)],
		}
		"flowchart TD\n    subgraph g [G]\n        subgraph h [H]\n            direction LR\n            a\n        end\n        subgraph k [K]\n            b\n        end\n    end\n    b --> c\n" => {
			diagram: { direction: Down, nodes: [{ container: Group(1) }, { container: Group(2) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }, { container: Group(0), direction: Set(Right), separate: True, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }, { container: Group(0), direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }], edges: [{ from: Node(1), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None], group_titles: [{ width: 10, height: 15 }, { width: 10, height: 15 }, { width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(2), GroupItem(2), GroupItem(1), NodeItem(1), NodeItem(0)],
		}
		"flowchart TD\n    subgraph s [S]\n        direction LR\n        a --> b\n    end\n    subgraph t [T]\n        direction LR\n        c --> d\n    end\n    s --> t\n    d --> e\n" => {
			diagram: { direction: Down, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Group(1) }, { container: Group(1) }, { container: Root }], groups: [{ container: Root, direction: Set(Right), separate: True, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 20, min_height: 0 }, { container: Root, direction: Set(Right), separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(2), to: Node(3) }, { from: Group(0), to: Group(1) }, { from: Node(3), to: Node(4) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None, None, None], group_titles: [{ width: 10, height: 15 }, { width: 10, height: 15 }] },
			registration: [GroupItem(1), GroupItem(0), NodeItem(4), NodeItem(2), NodeItem(3), NodeItem(0), NodeItem(1)],
		}
		"flowchart TD\nsubgraph s [Long title]\nA --> B\nend\nB --> D\n" => {
			diagram: { direction: Down, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(1), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(2), NodeItem(0), NodeItem(1)],
		}
		"flowchart TD\nsubgraph services [A long group title that needs to wrap without colliding with the nodes inside]\nA[First service with a particularly long explanatory label]\nB[Second service<br>With an explicit break]\nC[Third service]\nA -->|A long relationship label explaining why this transition happens| B\nA --> C\nB --> A\nend\nC --> D([Completed])\n" => {
			diagram: { direction: Down, nodes: [{ container: Group(0) }, { container: Group(0) }, { container: Group(0) }, { container: Root }], groups: [{ container: Root, direction: Inherit, separate: False, spacing: LayeredFlowFixtures.group_spacing, padding: { top: 44, right: 24, bottom: 24, left: 24 }, min_width: 0, min_height: 20 }], edges: [{ from: Node(0), to: Node(1) }, { from: Node(0), to: Node(2) }, { from: Node(1), to: Node(0) }, { from: Node(2), to: Node(3) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }, { width: 152, height: 41 }], edge_labels: [Some({ width: 35.26953125, height: 21 }), None, None, None], group_titles: [{ width: 10, height: 15 }] },
			registration: [GroupItem(0), NodeItem(3), NodeItem(0), NodeItem(1), NodeItem(2)],
		}
		"fuzz-regression-ordering-small" => {
			diagram: { direction: Left, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(0) }, { from: Node(1), to: Node(0) }, { from: Node(2), to: Node(3) }, { from: Node(4), to: Node(5) }, { from: Node(2), to: Node(5) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 3, height: 0 }, { width: 148, height: 125 }, { width: 3, height: 0 }, { width: 148, height: 125 }, { width: 3, height: 0 }, { width: 148, height: 125 }], edge_labels: [None, Some({ width: 4, height: 5 }), None, Some({ width: 128, height: 7 }), None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4), NodeItem(5)],
		}
		"fuzz-regression-ordering-sweeps" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(1) }, { from: Node(0), to: Node(1) }, { from: Node(2), to: Node(0) }, { from: Node(0), to: Node(2) }, { from: Node(3), to: Node(1) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 117, height: 69 }, { width: 2, height: 117 }, { width: 46, height: 2 }, { width: 69, height: 46 }], edge_labels: [None, None, None, None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3)],
		}
		"fuzz-regression-loops-many" => {
			diagram: { direction: Right, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(0) }, { from: Node(0), to: Node(0) }, { from: Node(0), to: Node(1) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(3) }, { from: Node(4), to: Node(4) }, { from: Node(4), to: Node(3) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(2) }, { from: Node(2), to: Node(5) }, { from: Node(6), to: Node(6) }, { from: Node(6), to: Node(6) }, { from: Node(6), to: Node(4) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 165, height: 66 }, { width: 33, height: 61 }, { width: 165, height: 66 }, { width: 33, height: 61 }, { width: 165, height: 66 }, { width: 33, height: 61 }, { width: 165, height: 66 }], edge_labels: [None, Some({ width: 70, height: 9 }), None, None, Some({ width: 65, height: 18 }), None, None, None, None, None, Some({ width: 65, height: 18 }), None, None, None, Some({ width: 41, height: 6 }), None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4), NodeItem(5), NodeItem(6)],
		}
		"fuzz-regression-loops-sweeps" => {
			diagram: { direction: Left, nodes: [{ container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }, { container: Root }], groups: [], edges: [{ from: Node(0), to: Node(0) }, { from: Node(0), to: Node(1) }, { from: Node(0), to: Node(0) }, { from: Node(0), to: Node(0) }, { from: Node(0), to: Node(2) }, { from: Node(0), to: Node(0) }, { from: Node(0), to: Node(1) }, { from: Node(3), to: Node(3) }, { from: Node(3), to: Node(3) }, { from: Node(3), to: Node(4) }, { from: Node(5), to: Node(5) }, { from: Node(5), to: Node(5) }, { from: Node(5), to: Node(5) }, { from: Node(5), to: Node(2) }], spacing: LayeredFlowFixtures.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 } },
			sizes: { nodes: [{ width: 75, height: 3 }, { width: 3, height: 126 }, { width: 75, height: 3 }, { width: 3, height: 126 }, { width: 75, height: 3 }, { width: 3, height: 126 }], edge_labels: [None, None, None, Some({ width: 17, height: 15 }), None, None, None, None, Some({ width: 79, height: 7 }), None, None, Some({ width: 7, height: 34 }), None, None], group_titles: [] },
			registration: [NodeItem(0), NodeItem(1), NodeItem(2), NodeItem(3), NodeItem(4), NodeItem(5)],
		}
		_ => crash "missing structural phase fixture"
	}
}
