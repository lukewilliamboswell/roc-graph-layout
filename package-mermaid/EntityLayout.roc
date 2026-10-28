import Drawing
import FlowGeometry

## The ELK head/tail-label spacing phase, shared by real class rendering and
## reference-sized layout probes. Labels at an endpoint consume space next to
## that endpoint's layer; they do not become extra ranks. Intervals identify
## layers even when their nodes have different heights. Sorting is a bounded
## bottom-up merge, avoiding the compiler builtin's adversarial quicksort path.
EntityLayout :: {}.{
	Terminal : { node : U64, point : Drawing.Point, next : Drawing.Point, extent : F64 }
	Interval : { low : F64, high : F64, index : U64 }
	Layer : { low : F64, high : F64, before : F64, after : F64 }

	reserve : FlowGeometry.Geometry, List(Terminal), Bool -> FlowGeometry.Geometry
	reserve = |geometry, terminals, vertical| {
		if terminals.is_empty() {
			return geometry
		}
		intervals = geometry.nodes.map_with_index(|box, index| if (vertical) { low: box.y, high: box.y + box.height, index } else { low: box.x, high: box.x + box.width, index })
		sorted = EntityLayout.sort(intervals)
		var $layers = []
		var $membership = List.repeat(0, intervals.len())
		for interval in sorted {
			last = $layers.last() ?? { low: 0, high: -1, before: 0, after: 0 }
			if !$layers.is_empty() and interval.low <= last.high + 0.001 {
				index = $layers.len() - 1
				$layers = $layers.set(index, { ..last, high: last.high.max(interval.high) }) ?? []
				$membership = $membership.set(interval.index, index) ?? []
			} else {
				index = $layers.len()
				$layers = $layers.append({ low: interval.low, high: interval.high, before: 0, after: 0 })
				$membership = $membership.set(interval.index, index) ?? []
			}
		}
		for terminal in terminals {
			layer_index = $membership.get(terminal.node) ?? 0
			match $layers.get(layer_index) {
				Err(_) => {}
				Ok(layer) => {
					outward = if (vertical) terminal.next.y - terminal.point.y else terminal.next.x - terminal.point.x
					updated = if outward > 0 {
						{ ..layer, after: layer.after.max(terminal.extent) }
					} else {
						{ ..layer, before: layer.before.max(terminal.extent) }
					}
					$layers = $layers.set(layer_index, updated) ?? []
				}
			}
		}
		layers = $layers
		var $cuts = List.repeat({ low: 0, high: 0, start: 0, end: 0 }, layers.len())
		var $prefix = 0.0
		for i in 0..<layers.len() {
			layer = layers.get(i) ?? { low: 0, high: 0, before: 0, after: 0 }
			start = $prefix + layer.before
			end = start + layer.after
			$cuts = $cuts.set(i, { low: layer.low, high: layer.high, start, end }) ?? []
			$prefix = end
		}
		cuts = $cuts
		project = |point| {
			coordinate = if (vertical) point.y else point.x
			var $low = 0
			var $high = cuts.len()
			while $low < $high {
				middle = $low + ($high - $low) // 2
				cut = cuts.get(middle) ?? { low: 0, high: 0, start: 0, end: 0 }
				if cut.low <= coordinate + 0.001 {
					$low = middle + 1
				} else {
					$high = middle
				}
			}
			shift = if $low == 0 {
				0
			} else {
				cut = cuts.get($low - 1) ?? { low: 0, high: 0, start: 0, end: 0 }
				if (coordinate <= cut.high + 0.001) cut.start else cut.end
			}
			if (vertical) { x: point.x, y: point.y + shift } else { x: point.x + shift, y: point.y }
		}
		nodes = geometry.nodes.map_with_index(
			|box, i| {
				shift = (cuts.get($membership.get(i) ?? 0) ?? { low: 0, high: 0, start: 0, end: 0 }).start
				if (vertical) { ..box, y: box.y + shift } else { ..box, x: box.x + shift }
			},
		)
		edges = geometry.edges.map(
			|edge| {
				points: edge.points.map(project),
				label: match edge.label {
					Some(point) => Some(project(point))
					None => None
				},
			},
		)
		{ ..geometry, nodes, edges }
	}

	sort : List(Interval) -> List(Interval)
	sort = |input| {
		count = input.len()
		if count < 2 {
			return input
		}
		var $source = input
		var $target = List.repeat({ low: 0, high: 0, index: 0 }, count)
		var $width = 1
		while $width < count {
			var $start = 0
			while $start < count {
				middle = ($start + $width).min(count)
				end = (middle + $width).min(count)
				var $a = $start
				var $b = middle
				var $out = $start
				while $out < end {
					left = $source.get($a) ?? { low: 0, high: 0, index: 0 }
					right = $source.get($b) ?? { low: 0, high: 0, index: 0 }
					use_left = $a < middle and ($b >= end or left.low < right.low or (left.low == right.low and left.index < right.index))
					value = if (use_left) left else right
					$target = $target.set($out, value) ?? []
					if use_left {
						$a = $a + 1
					} else {
						$b = $b + 1
					}
					$out = $out + 1
				}
				$start = end
			}
			previous = $source
			$source = $target
			$target = previous
			$width = $width * 2
		}
		$source
	}
}

expect EntityLayout.sort([{ low: 3, high: 4, index: 0 }, { low: 1, high: 2, index: 1 }, { low: 1, high: 2, index: 2 }]).map(|i| i.index) == [1, 2, 0]

## Oracle-derived terminal-label gap: source label14+spacing4 and target
## label14+marker clearance12+spacing4 add48 next to the endpoint layers.
expect {
	geometry = { nodes: [{ x: 0, y: 0, width: 30, height: 77 }, { x: 0, y: 117, width: 30, height: 77 }], edges: [{ points: [{ x: 15, y: 77 }, { x: 15, y: 117 }], label: None }], groups: [], bounds: { x: 0, y: 0, width: 30, height: 194 } }
	terminals = [{ node: 0, point: { x: 15, y: 77 }, next: { x: 15, y: 117 }, extent: 18 }, { node: 1, point: { x: 15, y: 117 }, next: { x: 15, y: 77 }, extent: 30 }]
	result = EntityLayout.reserve(geometry, terminals, True)
	(result.nodes.get(1) ?? { x: 0, y: 0, width: 0, height: 0 }).y == 165 and (result.edges.first() ?? { points: [], label: None }).points == [{ x: 15, y: 77 }, { x: 15, y: 165 }]
}
