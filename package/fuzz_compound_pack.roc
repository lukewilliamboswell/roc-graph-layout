app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Compound

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	count = (byte_at(bytes, 0) % 9).to_u64()
	gap = (byte_at(bytes, 1) % 20).to_f64()
	groups = List.repeat({}, count).map_with_index(
		|_, i| {
			width: (byte_at(bytes, 2 + i * 2) % 50).to_f64(),
			height: (byte_at(bytes, 3 + i * 2) % 50).to_f64(),
		},
	)
	result = Compound.pack_groups(groups, gap)
	repeated = Compound.pack_groups(groups, gap)
	# fresh binding rather than a shadowing rebind: rebinding a name whose new
	# definition references the old one segfaults the compiler under this
	# platform (repro filed); the count guard also has to come first, since
	# `count - 1` underflows U64 at zero.
	expected_width = if count == 0 {
		0
	} else {
		groups.fold(0, |sum, group| sum + group.width) + gap * (count - 1).to_f64()
	}
	expected_height = groups.fold(0, |height, group| height.max(group.height))
	contained = result.positions.fold_with_index(
		True,
		|ok, position, i| {
			group = groups.get(i) ?? { width: 0, height: 0 }
			ok and position.x >= 0 and position.y == 0 and position.x + group.width <= result.bounds.width
		},
	)
	spaced = result.positions.fold_with_index(
		True,
		|ok, position, i|
			if i == 0 {
				ok and position.x == 0
			} else {
				previous = result.positions.get(i - 1) ?? position
				previous_group = groups.get(i - 1) ?? { width: 0, height: 0 }
				ok and position.x == previous.x + previous_group.width + gap
			},
	)
	if result != repeated {
		crash "compound packing is nondeterministic"
	} else if result.positions.len() != count {
		crash "compound packing lost source alignment"
	} else if result.bounds.x != 0 or result.bounds.y != 0 or result.bounds.width != expected_width or result.bounds.height != expected_height {
		crash "compound packing returned incorrect bounds"
	} else if !contained or !spaced {
		crash "compound groups escaped their bounds or lost row translation"
	} else {
		Fuzz.keep
	}
}

target = Fuzz.target_with({
	name: "graph-layout-compound-pack",
	generator: Fuzz.list(Fuzz.u8, 32),
	test,
	show: |input| Str.inspect(input),
})
