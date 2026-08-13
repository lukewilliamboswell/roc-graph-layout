app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Overlap

byte_at = |bytes, i| bytes.get(i) ?? 0

test = |bytes| {
	n = (byte_at(bytes, 0) % 9).to_u64()
	gap = (byte_at(bytes, 1) % 9).to_f64()
	positions = List.repeat({}, n).map_with_index(
		|_, i| {
			x: (byte_at(bytes, 2 + i * 4) % 41).to_f64() - 20,
			y: (byte_at(bytes, 3 + i * 4) % 41).to_f64() - 20,
		},
	)
	sizes = List.repeat({}, n).map_with_index(
		|_, i| {
			width: (byte_at(bytes, 4 + i * 4) % 13).to_f64(),
			height: (byte_at(bytes, 5 + i * 4) % 13).to_f64(),
		},
	)
	result = Overlap.remove(positions, sizes, gap)
	input_clean = positions.fold_with_index(
		True,
		|outer, a, i|
			positions.fold_with_index(
				outer,
				|ok, b, j| if j <= i {
					ok
				} else {
					sa = sizes.get(i) ?? { width: 0, height: 0 }
					sb = sizes.get(j) ?? { width: 0, height: 0 }
					clear_x = (b.x - a.x).abs() >= (sa.width + sb.width) / 2 + gap
					clear_y = (b.y - a.y).abs() >= (sa.height + sb.height) / 2 + gap
					ok and (clear_x or clear_y)
				},
			),
	)
	clean = result.fold_with_index(
		True,
		|outer, a, i|
			result.fold_with_index(
				outer,
				|ok, b, j| if j <= i {
					ok
				} else {
					sa = sizes.get(i) ?? { width: 0, height: 0 }
					sb = sizes.get(j) ?? { width: 0, height: 0 }
					clear_x = (b.x - a.x).abs() >= (sa.width + sb.width) / 2 + gap - 0.000000001
					clear_y = (b.y - a.y).abs() >= (sa.height + sb.height) / 2 + gap - 0.000000001
					ok and (clear_x or clear_y)
				},
			),
	)
	stable = Overlap.remove(result, sizes, gap) == result
	deterministic = Overlap.remove(positions, sizes, gap) == result
	unchanged = if input_clean {
		result == positions
	} else {
		True
	}
	if result.len() != positions.len() {
		crash "overlap removal violated index alignment"
	} else if !clean {
		crash "overlap removal left overlapping boxes"
	} else if !stable {
		crash "overlap removal was not idempotent"
	} else if !deterministic {
		crash "overlap removal was not deterministic"
	} else if !unchanged {
		crash "overlap removal moved an already-separated placement"
	} else {
		Fuzz.keep
	}
}

target = Fuzz.target_with({
	name: "graph-layout-overlap",
	generator: Fuzz.list(Fuzz.u8, 40),
	test,
	show: |input| Str.inspect(input),
})
