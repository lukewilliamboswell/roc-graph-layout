import Drawing

## Shared appearance for Mermaid diagrams. Colours are sRGB and distances
## are CSS pixels. Construct `Options.{}` for a readable light palette, or
## supply only the properties you want to change. Labels are measured and
## drawn in Inter; changing their size also changes the space they receive.
Theme :: {}.{

	## A numeric property outside its documented range.
	Problem : [InvalidTheme(Str)]

	Options := {
		background : Drawing.Color ?? Drawing.white,
		node_fill : Drawing.Color ?? Drawing.rgb(0xFFFFFF),
		node_stroke : Drawing.Color ?? Drawing.rgb(0x28253D),
		node_text : Drawing.Color ?? Drawing.rgb(0x28253D),
		node_palette : List({ fill : Drawing.Color, stroke : Drawing.Color }) ?? [],
		note_fill : Drawing.Color ?? Drawing.rgb(0xFFF5AD),
		note_stroke : Drawing.Color ?? Drawing.rgb(0x28253D),
		note_text : Drawing.Color ?? Drawing.rgb(0x28253D),
		line : Drawing.Color ?? Drawing.rgb(0x000000),
		line_width : F64 ?? 2,
		label_background : Drawing.Color ?? Drawing.rgb(0xE5E5E5),
		label_text : Drawing.Color ?? Drawing.rgb(0x28253D),
		accent : Drawing.Color ?? Drawing.rgb(0x28253D),
		group_fill : Drawing.Color ?? Drawing.rgb(0xFDF4FF),
		group_stroke : Drawing.Color ?? Drawing.rgb(0xE879F9),
		font_size : F64 ?? 14,
		line_height : F64 ?? 1.1,
		max_label_width : F64 ?? 120,
		wrapping : [FamilyDefault, Wrap, NoWrap] ?? FamilyDefault,
		padding : F64 ?? 15,
		corner_radius : F64 ?? 12,
		corners : [FamilyDefault, Rounded, Square] ?? FamilyDefault,
		shadow : [NoShadow, Shadow({ dx : F64, dy : F64, opacity : F64 })] ?? Shadow({ dx: 4, dy: 4, opacity: 0.06 }),
	}

	## All independent invalid numeric properties, in a stable order. A valid
	## theme never needs to be silently clamped by a renderer. Sizes are
	## bounded to keep downstream geometry finite: text up to 1024 pixels,
	## line spacing up to 8 em, wrapping and padding up to 16384 pixels,
	## and outlines and corner radii up to 1024 pixels.
	validate : Options -> List(Problem)
	validate = |options| {
		var $problems = []
		for field in [
			("font_size", options.font_size, True, 1024),
			("line_height", options.line_height, True, 8),
			("max_label_width", options.max_label_width, True, 16384),
			("padding", options.padding, False, 16384),
			("line_width", options.line_width, False, 1024),
			("corner_radius", options.corner_radius, False, 1024),
		] {
			if !F64.is_finite(field.1) or field.1 < 0 or field.1 > field.3 or (field.2 and field.1 == 0) {
				$problems = $problems.append(InvalidTheme(field.0))
			}
		}
		match options.shadow {
			NoShadow => {}
			Shadow(s) => {
				if !F64.is_finite(s.dx) or s.dx.abs() > 16384 {
					$problems = $problems.append(InvalidTheme("shadow.dx"))
				}
				if !F64.is_finite(s.dy) or s.dy.abs() > 16384 {
					$problems = $problems.append(InvalidTheme("shadow.dy"))
				}
				if !F64.is_finite(s.opacity) or s.opacity < 0 or s.opacity > 1 {
					$problems = $problems.append(InvalidTheme("shadow.opacity"))
				}
			}
		}
		$problems
	}
}

expect Theme.validate(Theme.Options.{}).is_empty()
expect Theme.validate(Theme.Options.{ font_size: 0, padding: -1, line_width: F64.nan }).len() == 3
