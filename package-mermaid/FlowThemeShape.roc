import Flowchart
import FlowGeometry
import Theme

## Themed sizing leaves the padded label rectangle inside every outline.
## Fixed decorations (a subroutine's frame, a double circle's outer ring,
## and a cylinder's rim) are additional to the caller's label padding.
FlowThemeShape :: {}.{
	root_two : F64
	root_two = (2.0).sqrt()

	size : Flowchart.Shape, FlowGeometry.TextBlock, Theme.Options -> { width : F64, height : F64 }
	size = |shape, label, theme| {
		minimum_width : F64
		minimum_width = 80
		padded_width = label.width + theme.padding * 2
		padded_height = label.height + theme.padding * 2
		box_width = label.width.max(minimum_width.min(theme.max_label_width)) + theme.padding * 2
		match shape {
			Rectangle => { width: box_width, height: padded_height }
			Rounded => {
				# A corner of the padded label box must lie inside the round
				# corner too. Solving r <= min(width,height)/2 after adding
				# (1 - 1/sqrt(2))*r on each side avoids iterative growth.
				local_root = FlowThemeShape.root_two
				radius = theme.corner_radius.min(box_width / local_root).min(padded_height / local_root)
				extra = 2 * (1 - 1 / local_root) * radius
				{ width: box_width + extra, height: padded_height + extra }
			}
			Stadium => { width: box_width + padded_height, height: padded_height }
			Subroutine => { width: box_width + 16, height: padded_height }
			Cylinder => {
				radius = (box_width / 2) / (2.5 + box_width / 50)
				# Drawing moves the label down by 10px. Reserve enough above
				# it to clear the complete top rim and below it to clear the
				# curved bottom, in addition to the requested padding.
				clearance = (4 * radius - 20).max(2 * radius + 20)
				{ width: box_width, height: padded_height + clearance }
			}
			Circle | DoubleCircle => {
				radius = ((padded_width / 2) * (padded_width / 2) + (padded_height / 2) * (padded_height / 2)).sqrt()
				ring = if (shape == DoubleCircle) 12 else 0
				diameter = 2 * (radius + ring)
				{ width: diameter, height: diameter }
			}
			Ellipse => { width: padded_width * FlowThemeShape.root_two, height: padded_height * FlowThemeShape.root_two }
			Asymmetric => { width: box_width + padded_height / 4, height: padded_height }
			Diamond => {
				side = padded_width + padded_height
				{ width: side, height: side }
			}
			Hexagon => { width: box_width + 2 * padded_height / 3.5, height: padded_height }
			LeanRight | LeanLeft | Trapezoid | InverseTrapezoid => { width: box_width + padded_height, height: padded_height }
		}
	}
}

expect {
	label = { lines: ["Content"], width: 70, height: 21 }
	[Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid].all(
		|shape| {
			small = FlowThemeShape.size(shape, label, Theme.Options.{ padding: 0 })
			large = FlowThemeShape.size(shape, label, Theme.Options.{ padding: 20 })
			large.width > small.width and large.height > small.height
		},
	)
}

expect {
	label = { lines: [""], width: 0, height: 0 }
	[Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid].all(
		|shape| {
			size = FlowThemeShape.size(shape, label, Theme.Options.{ padding: 0 })
			F64.is_finite(size.width) and F64.is_finite(size.height) and size.width >= 0 and size.height >= 0
		},
	)
}
