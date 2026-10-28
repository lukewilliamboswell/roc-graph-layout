import DiagramSpacing
import Flowchart
import layout.Layered

## Mermaid source ordering, spacing defaults and subgraph direction policy.
## This adapter carries no solver state or geometric algorithm phases.
FlowSourceLayout :: {}.{
	Item : [GroupItem(U64), NodeItem(U64)]

	root_spacing : Layered.GroupedSpacing
	root_spacing = DiagramSpacing.root
	group_spacing : Layered.GroupedSpacing
	group_spacing = DiagramSpacing.inside

	## The members of a container in Mermaid's order: subgraphs first, last
	## declared first, then nodes in order.
	children : Flowchart.Diagram, Flowchart.Container -> List(Item)
	children = |diagram, container| {
		var $out = []
		var $g = diagram.groups.len()
		while $g > 0 {
			$g = $g - 1
			if (diagram.groups.get($g) ?? FlowSourceLayout.no_group).container == container {
				$out = $out.append(GroupItem($g))
			}
		}
		for i in 0..<diagram.nodes.len() {
			if (diagram.nodes.get(i) ?? FlowSourceLayout.no_node).container == container {
				$out = $out.append(NodeItem(i))
			}
		}
		$out
	}

	registered_children : Flowchart.Diagram, Flowchart.Container, List(Item) -> List(Item)
	registered_children = |diagram, container, registration| {
		if registration.is_empty() {
			return FlowSourceLayout.children(diagram, container)
		}
		registration.keep_if(
			|item| {
				parent = match item {
					NodeItem(i) => (diagram.nodes.get(i) ?? crash "validated node registration").container
					GroupItem(i) => (diagram.groups.get(i) ?? crash "validated group registration").container
				}
				parent == container
			},
		)
	}

	no_group : Flowchart.Group
	no_group = { id: "", title: "", container: Root, direction: Inherit, classes: [] }

	no_node : Flowchart.Node
	no_node = { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }

	no_edge : Flowchart.Edge
	no_edge = { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }

	## Which subgraph each container lies in, by item.
	parent_of : Flowchart.Diagram, Item -> [Root, Group(U64)]
	parent_of = |diagram, item| {
		container = match item {
			GroupItem(g) => (diagram.groups.get(g) ?? FlowSourceLayout.no_group).container
			NodeItem(i) => (diagram.nodes.get(i) ?? FlowSourceLayout.no_node).container
		}
		match container {
			Root => Root
			Group(g) => if (g < diagram.groups.len()) Group(g) else Root
		}
	}

	## Which subgraphs Mermaid has laid out on their own: one with a
	## `direction` of its own, or inside one laid out on its own, unless an
	## edge between different parents passes through it or ends at it. Such
	## an edge makes every subgraph from its ends up to their lowest common
	## ancestor, that one included, part of its parent's layout.
	separate_groups : Flowchart.Diagram -> List(Bool)
	separate_groups = |diagram| {
		count = diagram.groups.len()
		group_parent = |g|
			match (diagram.groups.get(g) ?? FlowSourceLayout.no_group).container {
				Group(p) => if (p < count) Some(p) else None
				Root => None
			}
		parent_of_end = |end|
			match end {
				Node(i) =>
					match (diagram.nodes.get(i) ?? FlowSourceLayout.no_node).container {
						Group(p) => if (p < count) Some(p) else None
						Root => None
					}
				Group(g) => group_parent(g)
			}
		# An end and the groups above it, innermost first, the end itself
		# included when it is a group.
		chain = |end| {
			start = match end {
				Node(_) => parent_of_end(end)
				Group(g) => Some(g)
			}
			var $out = []
			var $at = start
			var $guard = 0
			while $guard <= count {
				match $at {
					Some(g) => {
						$out = $out.append(g)
						$at = group_parent(g)
					}
					None => {
						$guard = count
					}
				}
				$guard = $guard + 1
			}
			$out
		}
		var $included = List.repeat(False, count)
		for edge in diagram.edges {
			if parent_of_end(edge.from) != parent_of_end(edge.to) {
				from_chain = chain(edge.from)
				to_chain = chain(edge.to)
				# Mermaid's lowest common ancestor of the two ends: an end that
				# contains the other, else the first shared group.
				lca = match (edge.from, edge.to) {
					(Group(a), _) if to_chain.contains(a) => Some(a)
					(_, Group(b)) if from_chain.contains(b) => Some(b)
					_ =>
						match from_chain.find_first(|g| to_chain.contains(g)) {
							Ok(g) => Some(g)
							Err(_) => None
						}
				}
				for c in [from_chain, to_chain] {
					var $going = True
					for g in c {
						if $going {
							$included = $included.set(g, True) ?? $included
							if Some(g) == lca {
								$going = False
							}
						}
					}
				}
			}
		}
		included = $included
		# Top-down: a subgraph's handling is settled before its members'.
		var $separate = List.repeat(False, count)
		var $done = List.repeat(False, count)
		var $round = 0
		while $round <= count {
			for g in 0..<count {
				if !($done.get(g) ?? True) {
					parent_done = match group_parent(g) {
						Some(p) => $done.get(p) ?? True
						None => True
					}
					if parent_done {
						own_direction = match (diagram.groups.get(g) ?? FlowSourceLayout.no_group).direction {
							Set(_) => True
							Inherit => False
						}
						inherited = match group_parent(g) {
							Some(p) => $separate.get(p) ?? False
							None => False
						}
						value = !(included.get(g) ?? False) and (own_direction or inherited)
						$separate = $separate.set(g, value) ?? $separate
						$done = $done.set(g, True) ?? $done
					}
				}
			}
			$round = $round + 1
		}
		$separate
	}

}

expect {
	diagram = {
		direction: Down,
		nodes: [{ ..FlowSourceLayout.no_node, id: "A" }, { ..FlowSourceLayout.no_node, id: "B" }],
		groups: [{ ..FlowSourceLayout.no_group, id: "outer" }, { ..FlowSourceLayout.no_group, id: "inner", container: Group(0) }],
		edges: [],
		classes: [],
	}
	registration = [NodeItem(1), GroupItem(1), NodeItem(0), GroupItem(0)]
	FlowSourceLayout.registered_children(diagram, Root, registration) == [NodeItem(1), NodeItem(0), GroupItem(0)]
		and FlowSourceLayout.registered_children(diagram, Group(0), registration) == [GroupItem(1)]
		and FlowSourceLayout.registered_children(diagram, Root, []) == [GroupItem(0), NodeItem(0), NodeItem(1)]
}
