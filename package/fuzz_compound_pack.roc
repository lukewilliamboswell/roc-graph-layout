app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Compound

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

group_spec = |Group(spec)| spec

finite_rect = |rect| F64.is_finite(rect.x) and F64.is_finite(rect.y) and F64.is_finite(rect.width) and F64.is_finite(rect.height) and rect.width >= 0 and rect.height >= 0

contains = |outer, inner| inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height

geometry_matches = |geometry, insets, header| {
	header_height = match header {
		None => 0
		Reserve(payload) => payload.height
	}
	expected_content = {
		x: geometry.rect.x + insets.left,
		y: geometry.rect.y + insets.top + header_height,
		width: geometry.rect.width - insets.left - insets.right,
		height: geometry.rect.height - insets.top - header_height - insets.bottom,
	}
	header_matches = match (header, geometry.header) {
		(None, None) => True
		(Reserve(payload), Some(rect)) => rect == { x: geometry.rect.x, y: geometry.rect.y, width: geometry.rect.width, height: payload.height }
		_ => False
	}
	finite_rect(geometry.rect) and finite_rect(geometry.content) and geometry.content == expected_content and contains(geometry.rect, geometry.content) and header_matches
}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	count = (byte_at(bytes, 0) % 12).to_u64()
	nodes = List.repeat({ width: 0, height: 0 }, count).map_with_index(
		|_, i| {
			width: (byte_at(bytes, i * 2 + 1) % 50).to_f64(),
			height: (byte_at(bytes, i * 2 + 2) % 50).to_f64(),
		},
	)
	base = group_spec(Compound.default_group)
	child_specs = List.repeat(base, count).map_with_index(
		|_, i| {
			insets = {
				top: (byte_at(bytes, 34 + i * 4) % 9).to_f64(),
				right: (byte_at(bytes, 35 + i * 4) % 9).to_f64(),
				bottom: (byte_at(bytes, 36 + i * 4) % 9).to_f64(),
				left: (byte_at(bytes, 37 + i * 4) % 9).to_f64(),
			}
			header = if byte_at(bytes, 82 + i) % 2 == 0 {
				None
			} else {
				Reserve({ height: (byte_at(bytes, 94 + i) % 13).to_f64() })
			}
			{ ..base, insets, header, children: [Node(i)] }
		},
	)
	children = child_specs.map(|spec| Nested(Group(spec)))
	root_insets = { top: (byte_at(bytes, 106) % 12).to_f64(), right: (byte_at(bytes, 107) % 12).to_f64(), bottom: (byte_at(bytes, 108) % 12).to_f64(), left: (byte_at(bytes, 109) % 12).to_f64() }
	root_header = if byte_at(bytes, 110) % 2 == 0 {
		None
	} else {
		Reserve({ height: (byte_at(bytes, 111) % 17).to_f64() })
	}
	root_spec = { ..base, children, algorithm: Rows({ gap: (byte_at(bytes, 30) % 20).to_f64() }), insets: root_insets, header: root_header }
	root = Group(root_spec)
	edge_count = if count == 0 {
		0
	} else {
		(byte_at(bytes, 31) % 12).to_u64()
	}
	edges = List.repeat({ from: 0, to: 0 }, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 48 + i * 2).to_u64() % count, to: byte_at(bytes, 49 + i * 2).to_u64() % count })
	input = { graph: { nodes, edges }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Compound.default_routing }
	result = Compound.layout(input, Compound.default_run)
	repeated = Compound.layout(input, Compound.default_run)
	match result {
		Err(_) => crash "valid compound input was rejected"
		Ok(layout) =>
			if result != repeated {
				crash "compound layout is nondeterministic"
			}
				else if layout.layout.positions.len() != count {
					crash "compound layout lost source alignment"
				}
					else if layout.layout.routes.len() != edges.len() or layout.attachments.len() != edges.len() or layout.group_crossings.len() != edges.len() or !layout.label_anchors.is_empty() {
						crash "compound routing lost source alignment"
					}
						else if layout.groups.len() != count + 1 {
							crash "compound group geometry lost preorder alignment"
						}
							else if !layout.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) or !finite_rect(layout.layout.bounds) or !layout.attachments.all(|ends| F64.is_finite(ends.from.point.x) and F64.is_finite(ends.from.point.y) and F64.is_finite(ends.to.point.x) and F64.is_finite(ends.to.point.y)) or !layout.group_crossings.join().all(|crossing| F64.is_finite(crossing.point.x) and F64.is_finite(crossing.point.y) and F64.is_finite(crossing.offset) and crossing.offset >= 0 and crossing.offset <= 1) {
								crash "compound layout returned non-finite geometry"
							}
								else if !layout.layout.routes.all(
									|route| match route {
										Line(a, b) => F64.is_finite(a.x) and F64.is_finite(a.y) and F64.is_finite(b.x) and F64.is_finite(b.y)
										Polyline(points) => points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) and points.fold_with_index(
											True,
											|orthogonal, p, i| match points.get(i + 1) {
												Ok(next) => orthogonal and (p.x == next.x or p.y == next.y)
												Err(_) => orthogonal
											},
										)
										Curves(_) => False
									},
								) {
									crash "compound routing returned invalid geometry"
								}
									else {
										root_geometry = layout.groups.first() ?? { rect: { x: 0, y: 0, width: 0, height: 0 }, content: { x: 0, y: 0, width: 0, height: 0 }, header: None }
										root_matches = root_geometry.rect == layout.layout.bounds and geometry_matches(root_geometry, root_insets, root_header)
										children_match = child_specs.fold_with_index(
											True,
											|ok, spec, i| {
												geometry = layout.groups.get(i + 1) ?? root_geometry
												node = nodes.get(i) ?? { width: 0, height: 0 }
												position = layout.layout.positions.get(i) ?? { x: 0, y: 0 }
												node_rect = { x: position.x - node.width / 2, y: position.y - node.height / 2, width: node.width, height: node.height }
												ok and geometry_matches(geometry, spec.insets, spec.header) and contains(root_geometry.content, geometry.rect) and contains(geometry.content, node_rect)
											},
										)
										if !root_matches or !children_match {
											crash "compound containment or reserved geometry contract failed"
										} else {
											Fuzz.keep
										}
									}
		}
}

target = Fuzz.target_with({
	name: "graph-layout-compound",
	generator: Fuzz.list(Fuzz.u8, 128),
	test,
	show: |input| Str.inspect(input),
})
