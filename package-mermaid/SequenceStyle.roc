import Drawing
import FlowDraw
import Theme

## The sequence renderer's role defaults, relative to the shared base knobs.
## In particular sequence typography is 16px while the common base is14px.
SequenceStyle :: {}.{
	resolve : Theme.Options -> Theme.Options
	resolve = |options| {
		defaults = Theme.Options.{}
		Theme.Options.{
			background: options.background,
			node_fill: options.node_fill,
			node_stroke: options.node_stroke,
			node_text: options.node_text,
			node_palette: options.node_palette,
			note_fill: options.note_fill,
			note_stroke: options.message_colors.note_stroke,
			note_text: options.note_text,
			line: options.message_colors.line,
			line_width: options.line_width * 1.5 / defaults.line_width,
			label_background: options.message_colors.control_fill,
			message_colors: options.message_colors,
			label_text: options.label_text,
			accent: options.accent,
			group_fill: options.group_fill,
			group_stroke: options.group_stroke,
			font_size: options.font_size * 16 / defaults.font_size,
			line_height: options.line_height / defaults.line_height,
			max_label_width: options.max_label_width * 130 / defaults.max_label_width,
			padding: options.padding * 10 / defaults.padding,
			corner_radius: match options.corners {
				FamilyDefault => options.corner_radius * 6 / defaults.corner_radius
				Rounded => options.corner_radius
				Square => 0
			},
			corners: options.corners,
			wrapping: options.wrapping,
			shadow: options.shadow,
		}
	}

	wrap : Bool, Theme.Options -> Bool
	wrap = |source, options| match options.wrapping {
		FamilyDefault => source
		Wrap => True
		NoWrap => False
	}

	actor : U64, Theme.Options -> { fill : Drawing.Color, stroke : Drawing.Color }
	actor = |index, options| {
		palette = if options.node_palette.is_empty() {
			FlowDraw.mermaid.group_colors
		} else {
			options.node_palette
		}
		entry = palette.get(index % palette.len()) ?? { fill: options.node_fill, stroke: options.node_stroke }
		entry
	}
}

expect {
	options = Theme.Options.{ message_colors: Theme.MessageColors.{ line: Drawing.black, note_stroke: Drawing.rgb(0x28253D), control_fill: Drawing.rgb(0xCCCCCC) } }
	actual = SequenceStyle.resolve(options)
	actual.line == Drawing.black and actual.note_stroke == Drawing.rgb(0x28253D) and actual.label_background == Drawing.rgb(0xCCCCCC)
}
