import Drawing
import Flowchart

## Node outlines as Mermaid 12 draws them in its default look, fitted to the
## shape's bounding box. Mermaid sizes each shape from its label; here the
## box is given, so each outline is the same figure scaled to fill it. Where
## Mermaid generates an outline from many sampled points, the clean curve is
## used instead.
FlowDrawShape :: {}.{

	## The outlines that make up a node's shape, painted in order with the
	## node's fill and stroke (a double circle is two circles), and where the
	## centre of the label sits relative to the centre of the box.
	Outline : { paths : List(List(Drawing.Segment)), label_offset : Drawing.Point }

	## Radius of the corners of a rounded rectangle.
	corner_radius : F64
	corner_radius = 12

	## Gap between the rings of a double circle.
	ring_gap : F64
	ring_gap = 12

	## How far a cylinder's label sits below its centre, to clear the top
	## rim.
	cylinder_label_drop : F64
	cylinder_label_drop = 10

	## The outline of a shape filling `box`. Negative sizes count as zero.
	outline : Flowchart.Shape, Drawing.Rect -> Outline
	outline = |shape, given| {
		box = { x: given.x, y: given.y, width: given.width.max(0), height: given.height.max(0) }
		w = box.width
		h = box.height
		x = box.x
		y = box.y
		cx = x + w / 2
		cy = y + h / 2
		centered = |paths| { paths, label_offset: { x: 0, y: 0 } }
		match shape {
			Rectangle => centered([Drawing.rectangle(box)])
			Rounded => centered([Drawing.rounded_rectangle(box, FlowDrawShape.corner_radius)])
			Stadium => centered([FlowDrawShape.stadium(box)])
			Subroutine => {
				frame = (w / 2).min(8)
				centered([
					Drawing.polygon([
						{ x: x + frame, y: y + h },
						{ x: x + w - frame, y: y + h },
						{ x: x + w - frame, y },
						{ x: x + frame, y },
						{ x: x + frame, y: y + h },
						{ x, y: y + h },
						{ x: x + w, y: y + h },
						{ x: x + w, y },
						{ x, y },
						{ x, y: y + h },
					]),
				])
			}
			Cylinder => {
				rx = w / 2
				ry = (rx / (2.5 + w / 50)).min(h / 2)
				body = h - 2 * ry
				{
					paths: [FlowDrawShape.cylinder(box, rx, ry, body)],
					label_offset: { x: 0, y: FlowDrawShape.cylinder_label_drop.min(body / 2) },
				}
			}
			Circle => {
				r = w.min(h) / 2
				centered([Drawing.ellipse({ x: cx, y: cy }, r, r)])
			}
			DoubleCircle => {
				outer = w.min(h) / 2
				inner = (outer - FlowDrawShape.ring_gap).max(0)
				centered([Drawing.ellipse({ x: cx, y: cy }, outer, outer), Drawing.ellipse({ x: cx, y: cy }, inner, inner)])
			}
			Ellipse => centered([Drawing.ellipse({ x: cx, y: cy }, w / 2, h / 2)])
			Asymmetric => {
				notch = (h / 4).min(w)
				{
					paths: [Drawing.polygon([{ x, y }, { x: x + notch, y: cy }, { x, y: y + h }, { x: x + w, y: y + h }, { x: x + w, y }])],
					label_offset: { x: notch / 2, y: 0 },
				}
			}
			Diamond => centered([Drawing.polygon([{ x: cx, y }, { x: x + w, y: cy }, { x: cx, y: y + h }, { x, y: cy }])])
			Hexagon => {
				m = (h / 3.5).min(w / 2)
				centered([Drawing.polygon([{ x: x + m, y }, { x: x + w - m, y }, { x: x + w, y: cy }, { x: x + w - m, y: y + h }, { x: x + m, y: y + h }, { x, y: cy }])])
			}
			LeanRight => {
				s = (h / 2).min(w)
				centered([Drawing.polygon([{ x, y: y + h }, { x: x + w - s, y: y + h }, { x: x + w, y }, { x: x + s, y }])])
			}
			LeanLeft => {
				s = (h / 2).min(w)
				centered([Drawing.polygon([{ x: x + s, y: y + h }, { x: x + w, y: y + h }, { x: x + w - s, y }, { x, y }])])
			}
			Trapezoid => {
				s = (h / 2).min(w / 2)
				centered([Drawing.polygon([{ x, y: y + h }, { x: x + w, y: y + h }, { x: x + w - s, y }, { x: x + s, y }])])
			}
			InverseTrapezoid => {
				s = (h / 2).min(w / 2)
				centered([Drawing.polygon([{ x: x + s, y: y + h }, { x: x + w - s, y: y + h }, { x: x + w, y }, { x, y }])])
			}
		}
	}

	## A rectangle with semicircular ends.
	stadium : Drawing.Rect -> List(Drawing.Segment)
	stadium = |box| {
		r = box.height.min(box.width) / 2
		left = box.x + r
		right = box.x + box.width - r
		top = box.y
		bottom = box.y + box.height
		cy = box.y + box.height / 2
		[
			MoveTo({ x: left, y: top }),
			LineTo({ x: right, y: top }),
			Drawing.quarter({ x: right, y: top }, { x: right + r, y: top }, { x: right + r, y: cy }),
			Drawing.quarter({ x: right + r, y: cy }, { x: right + r, y: bottom }, { x: right, y: bottom }),
			LineTo({ x: left, y: bottom }),
			Drawing.quarter({ x: left, y: bottom }, { x: left - r, y: bottom }, { x: left - r, y: cy }),
			Drawing.quarter({ x: left - r, y: cy }, { x: left - r, y: top }, { x: left, y: top }),
			Close,
		]
	}

	## A cylinder seen from slightly above: the whole top rim as an ellipse,
	## the sides, and the front half of the bottom rim. As in Mermaid the
	## path is left open at the top right, which a fill closes.
	cylinder : Drawing.Rect, F64, F64, F64 -> List(Drawing.Segment)
	cylinder = |box, rx, ry, body| {
		left = box.x
		right = box.x + 2 * rx
		mid = box.x + rx
		rim = box.y + ry
		base = rim + body
		[
			MoveTo({ x: left, y: rim }),
			Drawing.quarter({ x: left, y: rim }, { x: left, y: rim + ry }, { x: mid, y: rim + ry }),
			Drawing.quarter({ x: mid, y: rim + ry }, { x: right, y: rim + ry }, { x: right, y: rim }),
			Drawing.quarter({ x: right, y: rim }, { x: right, y: rim - ry }, { x: mid, y: rim - ry }),
			Drawing.quarter({ x: mid, y: rim - ry }, { x: left, y: rim - ry }, { x: left, y: rim }),
			LineTo({ x: left, y: base }),
			Drawing.quarter({ x: left, y: base }, { x: left, y: base + ry }, { x: mid, y: base + ry }),
			Drawing.quarter({ x: mid, y: base + ry }, { x: right, y: base + ry }, { x: right, y: base }),
			LineTo({ x: right, y: rim }),
		]
	}
}

expect FlowDrawShape.outline(Rectangle, { x: 0, y: 0, width: 10, height: 4 }).paths == [Drawing.rectangle({ x: 0, y: 0, width: 10, height: 4 })]
expect FlowDrawShape.outline(DoubleCircle, { x: 0, y: 0, width: 40, height: 40 }).paths.len() == 2
expect FlowDrawShape.outline(Asymmetric, { x: 0, y: 0, width: 100, height: 40 }).label_offset == { x: 5, y: 0 }
expect FlowDrawShape.outline(Diamond, { x: 0, y: 0, width: -5, height: 4 }).paths == [Drawing.polygon([{ x: 0, y: 0 }, { x: 0, y: 2 }, { x: 0, y: 4 }, { x: 0, y: 2 }])]
