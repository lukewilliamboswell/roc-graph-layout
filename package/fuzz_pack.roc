app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Pack

byte_at = |bytes, i| bytes.get(i) ?? 0

test = |bytes| {
	n = (byte_at(bytes, 0) % 10).to_u64()
	boxes = List.repeat({}, n).map_with_index(
		|_, i| {
			width: (byte_at(bytes, 1 + i * 2) % 31).to_f64(),
			height: (byte_at(bytes, 2 + i * 2) % 31).to_f64(),
		},
	)
	settings = {
		gap: (byte_at(bytes, 24) % 10).to_f64(),
		target_aspect: ((byte_at(bytes, 25) % 16) + 1).to_f64() / 4,
	}
	result = Pack.pack(boxes, settings)
	nonoverlap = result.positions.fold_with_index(
		True,
		|outer, a, i|
			result.positions.fold_with_index(
				outer,
				|ok, b, j| if j <= i {
					ok
				} else {
					sa = boxes.get(i) ?? { width: 0, height: 0 }
					sb = boxes.get(j) ?? { width: 0, height: 0 }
					clear_x = (b.x - a.x).abs() * 2 >= sa.width + sb.width
					clear_y = (b.y - a.y).abs() * 2 >= sa.height + sb.height
					ok and (clear_x or clear_y)
				},
			),
	)
	contained = result.positions.fold_with_index(
		True,
		|ok, p, i| {
			box = boxes.get(i) ?? { width: 0, height: 0 }
			ok and p.x - box.width / 2 >= result.bounds.x
				and p.y - box.height / 2 >= result.bounds.y
					and p.x + box.width / 2 <= result.bounds.x + result.bounds.width
						and p.y + box.height / 2 <= result.bounds.y + result.bounds.height
		},
	)
	finite = result.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
		and F64.is_finite(result.bounds.width) and F64.is_finite(result.bounds.height)
	if result.positions.len() == boxes.len() and nonoverlap and contained and finite and Pack.pack(boxes, settings) == result {
		Fuzz.keep
	} else {
		crash "packing violated alignment, non-overlap, bounds, finiteness, or determinism"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-pack",
	generator: Fuzz.list(Fuzz.u8, 28),
	test,
	show: |input| Str.inspect(input),
})
