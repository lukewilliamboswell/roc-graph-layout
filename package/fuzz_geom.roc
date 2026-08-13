app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Geom

byte_at = |bytes, i| bytes.get(i) ?? 0

test = |bytes| {
	center = { x: (byte_at(bytes, 0) % 41).to_f64() - 20, y: (byte_at(bytes, 1) % 41).to_f64() - 20 }
	size = { width: (byte_at(bytes, 2) % 31).to_f64(), height: (byte_at(bytes, 3) % 31).to_f64() }
	toward = { x: (byte_at(bytes, 4) % 61).to_f64() - 30, y: (byte_at(bytes, 5) % 61).to_f64() - 30 }
	clipped = Geom.clip_to_node(center, size, toward)
	half_w = size.width / 2
	half_h = size.height / 2
	inside = (clipped.x - center.x).abs() <= half_w + 0.000000001 and (clipped.y - center.y).abs() <= half_h + 0.000000001
	on_boundary = clipped == center or ((clipped.x - center.x).abs() - half_w).abs() <= 0.000000001 or ((clipped.y - center.y).abs() - half_h).abs() <= 0.000000001
	dx = toward.x - center.x
	dy = toward.y - center.y
	length = Geom.hypot(dx, dy)
	hypot_ok = F64.is_finite(length) and length == Geom.hypot(dy, dx) and length == Geom.hypot(0 - dx, 0 - dy)
	if F64.is_finite(clipped.x) and F64.is_finite(clipped.y) and inside and on_boundary and hypot_ok {
		Fuzz.keep
	} else {
		crash "geometry violated clipping, boundary, symmetry, or finiteness"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-geom",
	generator: Fuzz.list(Fuzz.u8, 8),
	test,
	show: |input| Str.inspect(input),
})
