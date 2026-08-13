app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Tree

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

node : List(U8), U64, List(a) -> { width : F64, height : F64, children : List(a) }
node = |bytes, index, children| {
	width: (byte_at(bytes, index * 2) % 40).to_f64(),
	height: (byte_at(bytes, index * 2 + 1) % 40).to_f64(),
	children,
}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	# Depth-first order is root, left child and its leaves, right child and its leaves.
	spec = node(
		bytes,
		0,
		[
			node(bytes, 1, [node(bytes, 2, []), node(bytes, 3, [])]),
			node(bytes, 4, [node(bytes, 5, []), node(bytes, 6, [])]),
		],
	)
	direction = match byte_at(bytes, 14) % 4 {
		0 => Down
		1 => Up
		2 => Left
		_ => Right
	}
	settings = {
		..Tree.default_settings,
		sibling_gap: (byte_at(bytes, 15) % 24).to_f64(),
		subtree_gap: (byte_at(bytes, 16) % 32).to_f64(),
		level_gap: (byte_at(bytes, 17) % 48).to_f64(),
		direction,
	}
	radial_settings = {
		..Tree.default_radial_settings,
		sibling_gap: settings.sibling_gap,
		subtree_gap: settings.subtree_gap,
		ring_gap: (byte_at(bytes, 18) % 48).to_f64(),
		start_angle: (byte_at(bytes, 19).to_f64() - 128) / 16,
		winding: if byte_at(bytes, 20) % 2 == 0 {
			Clockwise
		} else {
			CounterClockwise
		},
	}
	expected_depths = [0, 1, 2, 2, 1, 2, 2]

	match (Tree.prepare(spec, settings), Tree.prepare_radial(spec, radial_settings)) {
		(Ok(prepared), Ok(radial_prepared)) => {
			tidy = Tree.layout_prepared(prepared)
			radial = Tree.layout_radial_prepared(radial_prepared)
			tidy_ok = Tree.layout(spec, settings) == Ok(tidy)
				and Tree.layout(spec, settings) == Tree.layout(spec, settings)
					and tidy.depths == expected_depths
						and tidy.layout.positions.len() == 7
							and tidy.layout.routes.len() == 6
			radial_ok = Tree.layout_radial(spec, radial_settings) == Ok(radial)
				and Tree.layout_radial(spec, radial_settings) == Tree.layout_radial(spec, radial_settings)
					and radial.depths == expected_depths
						and radial.layout.positions.len() == 7
							and radial.layout.routes.len() == 6

			if tidy_ok and radial_ok {
				Fuzz.keep
			} else {
				crash "tree layout violated depth, alignment, equivalence, or determinism"
			}
		}
		_ => crash "bounded valid tree input failed preparation"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-tree-contract",
	generator: Fuzz.list(Fuzz.u8, 32),
	test,
	show: |input| Str.inspect(input),
})
