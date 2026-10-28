import Drawing
import Flowchart

## Shared appearance for Mermaid diagrams. Colours are sRGB and distances
## are CSS pixels. Construct `Options.{}` for a readable light palette, or
## supply only the properties you want to change. Labels are measured and
## drawn in Inter; changing their size also changes the space they receive.
Theme :: {}.{
	Options := {
		background : Drawing.Color ?? Drawing.white,
		node_fill : Drawing.Color ?? Drawing.rgb(0xEEF2FF),
		node_stroke : Drawing.Color ?? Drawing.rgb(0xA5B4FC),
		node_text : Drawing.Color ?? Drawing.rgb(0x312E81),
		line : Drawing.Color ?? Drawing.rgb(0x64748B),
		line_width : F64 ?? 1.5,
		label_background : Drawing.Color ?? Drawing.white,
		label_text : Drawing.Color ?? Drawing.rgb(0x334155),
		accent : Drawing.Color ?? Drawing.rgb(0x4F46E5),
		group_fill : Drawing.Color ?? Drawing.rgb(0xF8FAFC),
		group_stroke : Drawing.Color ?? Drawing.rgb(0xCBD5E1),
		font_size : F64 ?? 14,
		line_height : F64 ?? 1.4,
		max_label_width : F64 ?? 220,
		padding : F64 ?? 12,
		corner_radius : F64 ?? 8,
		shadow : [NoShadow, Shadow({ dx : F64, dy : F64, opacity : F64 })] ?? NoShadow,
	}

	## All independent invalid numeric properties, in a stable order. A valid
	## theme never needs to be silently clamped by a renderer.
	validate : Options -> List(Flowchart.Problem)
	validate = |options| {
		var $problems = []
		for field in [
			("font_size", options.font_size, True),
			("line_height", options.line_height, True),
			("max_label_width", options.max_label_width, True),
			("padding", options.padding, False),
			("line_width", options.line_width, False),
			("corner_radius", options.corner_radius, False),
		] {
			if !F64.is_finite(field.1) or field.1 < 0 or (field.2 and field.1 == 0) {
				$problems = $problems.append(Unsupported("invalid theme property: ${field.0}"))
			}
		}
		match options.shadow {
			NoShadow => {}
			Shadow(s) => {
				if !F64.is_finite(s.dx) {
					$problems = $problems.append(Unsupported("invalid theme property: shadow.dx"))
				}
				if !F64.is_finite(s.dy) {
					$problems = $problems.append(Unsupported("invalid theme property: shadow.dy"))
				}
				if !F64.is_finite(s.opacity) or s.opacity < 0 or s.opacity > 1 {
					$problems = $problems.append(Unsupported("invalid theme property: shadow.opacity"))
				}
			}
		}
		$problems
	}
}

expect Theme.validate(Theme.Options.{}).is_empty()
expect Theme.validate(Theme.Options.{ font_size: 0, padding: -1, line_width: F64.nan }).len() == 3
