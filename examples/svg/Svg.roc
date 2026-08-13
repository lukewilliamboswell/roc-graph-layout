## Small, dependency-free helpers for hand-rendering SVG documents from plain
## geometry — the kind of output a layout algorithm produces. Not a general
## SVG library: just enough to turn positions, boxes, and routes into markup.
Svg :: {}.{
	RectStyle : { rx : F64, fill : Str, stroke : Str, stroke_width : F64 }
	default_rect_style : RectStyle
	default_rect_style = { rx: 4, fill: "#eef2ff", stroke: "#4338ca", stroke_width: 2 }

	TextStyle : { anchor : Str, baseline : Str, font_family : Str, font_size : F64, fill : Str }
	default_text_style : TextStyle
	default_text_style = { anchor: "middle", baseline: "middle", font_family: "sans-serif", font_size: 14, fill: "#111827" }

	LineStyle : { stroke : Str, stroke_width : F64, marker_end : Str }
	default_line_style : LineStyle
	default_line_style = { stroke: "#64748b", stroke_width: 1.5, marker_end: "" }

	## A complete SVG document: fixed-size canvas, an optional `<defs>` block
	## (e.g. from [arrow_marker_defs]), a background rect, then `body`.
	document : F64, F64, Str, Str -> Str
	document = |width, height, defs, body| {
		w = width.to_str()
		h = height.to_str()

		\\<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
		\\${defs}
		\\<rect x="0" y="0" width="${w}" height="${h}" fill="#ffffff" />
		\\${body}
		\\</svg>
	}

	## A square 720px preview around rectangular content. The view box keeps
	## the content's natural scale and centers its shorter dimension, so a set
	## of generated examples has consistent dimensions without distortion.
	square_document : F64, F64, Str, Str -> Str
	square_document = |content_width, content_height, defs, body| {
		side = content_width.max(content_height)
		dx = (side - content_width) / 2
		dy = (side - content_height) / 2
		s = side.to_str()

		\\<svg xmlns="http://www.w3.org/2000/svg" width="720" height="720" viewBox="0 0 ${s} ${s}">
		\\${defs}
		\\<rect x="0" y="0" width="${s}" height="${s}" fill="#ffffff" />
		\\<g transform="translate(${dx.to_str()} ${dy.to_str()})">
		\\${body}
		\\</g>
		\\</svg>
	}

	## A `<defs>` block with a single arrowhead marker, referenced from a
	## route's `marker_end` as `"url(#${id})"`.
	arrow_marker_defs : Str, Str -> Str
	arrow_marker_defs = |id, fill|
		\\<defs>
		\\<marker id="${id}" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">
		\\<path d="M0,0 L8,4 L0,8 z" fill="${fill}" />
		\\</marker>
		\\</defs>

	## A rectangle centered at `(cx, cy)` with the given full width/height —
	## matching a layout's "positions are centers" convention.
	rect_centered : F64, F64, F64, F64, RectStyle -> Str
	rect_centered = |cx, cy, width, height, style| {
		x = cx - width / 2
		y = cy - height / 2

		\\<rect x="${x.to_str()}" y="${y.to_str()}" width="${width.to_str()}" height="${height.to_str()}" rx="${style.rx.to_str()}" fill="${style.fill}" stroke="${style.stroke}" stroke-width="${style.stroke_width.to_str()}" />
	}

	## Centered text, e.g. a node label placed over a [rect_centered].
	text_centered : F64, F64, Str, TextStyle -> Str
	text_centered = |cx, cy, content, style|
		\\<text x="${cx.to_str()}" y="${cy.to_str()}" text-anchor="${style.anchor}" dominant-baseline="${style.baseline}" font-family="${style.font_family}" font-size="${style.font_size.to_str()}" fill="${style.fill}">${content}</text>

	line : F64, F64, F64, F64, LineStyle -> Str
	line = |x1, y1, x2, y2, style| {
		marker = Svg.marker_attr(style.marker_end)

		\\<line x1="${x1.to_str()}" y1="${y1.to_str()}" x2="${x2.to_str()}" y2="${y2.to_str()}" stroke="${style.stroke}" stroke-width="${style.stroke_width.to_str()}" stroke-linecap="round" stroke-linejoin="round"${marker} />
	}

	polyline : List({ x : F64, y : F64 }), LineStyle -> Str
	polyline = |points, style| {
		coords = Str.join_with(points.map(|p| "${p.x.to_str()},${p.y.to_str()}"), " ")
		marker = Svg.marker_attr(style.marker_end)

		\\<polyline points="${coords}" fill="none" stroke="${style.stroke}" stroke-width="${style.stroke_width.to_str()}" stroke-linecap="round" stroke-linejoin="round"${marker} />
	}

	## A chain of cubic Bezier segments as one `<path>`. A segment that starts
	## where the previous one ended continues the same subpath (a single `M`
	## followed by several `C` commands); a segment that starts elsewhere opens
	## a new subpath with its own `M`.
	curves : List({ from : { x : F64, y : F64 }, ctl_a : { x : F64, y : F64 }, ctl_b : { x : F64, y : F64 }, to : { x : F64, y : F64 } }), LineStyle -> Str
	curves = |segments, style| {
		move_cmd = |seg| "M ${seg.from.x.to_str()} ${seg.from.y.to_str()}"
		curve_cmd = |seg| "C ${seg.ctl_a.x.to_str()} ${seg.ctl_a.y.to_str()}, ${seg.ctl_b.x.to_str()} ${seg.ctl_b.y.to_str()}, ${seg.to.x.to_str()} ${seg.to.y.to_str()}"

		parts = segments.map_with_index(
			|seg, i| {
				if i == 0 {
					"${move_cmd(seg)} ${curve_cmd(seg)}"
				} else {
					match segments.get(i - 1) {
						Ok(prev) =>
							if prev.to == seg.from {
								curve_cmd(seg)
							} else {
								"${move_cmd(seg)} ${curve_cmd(seg)}"
							}

						Err(_) => "${move_cmd(seg)} ${curve_cmd(seg)}"
					}
				}
			},
		)

		d = Str.join_with(parts, " ")
		marker = Svg.marker_attr(style.marker_end)

		\\<path d="${d}" fill="none" stroke="${style.stroke}" stroke-width="${style.stroke_width.to_str()}" stroke-linecap="round" stroke-linejoin="round"${marker} />
	}

	## A leading-space `marker-end="url(#...)"` attribute, or `""` when unset —
	## meant to be interpolated straight after an element's other attributes.
	marker_attr : Str -> Str
	marker_attr = |marker_end|
		if marker_end.is_empty() {
			""
		} else {
			\\ marker-end="url(#${marker_end})"
		}
}

## A centered rect's top-left corner sits half a size back from its center.
expect Svg.rect_centered(50, 50, 20, 10, Svg.default_rect_style) == "<rect x=\"40\" y=\"45\" width=\"20\" height=\"10\" rx=\"4\" fill=\"#eef2ff\" stroke=\"#4338ca\" stroke-width=\"2\" />"

## A line with no marker omits the marker-end attribute entirely.
expect Svg.line(0, 0, 10, 10, Svg.default_line_style) == "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"10\" stroke=\"#64748b\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" />"

## A line with a marker references it by id.
expect Svg.line(0, 0, 10, 10, { ..Svg.default_line_style, marker_end: "arrow" }) == "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"10\" stroke=\"#64748b\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" marker-end=\"url(#arrow)\" />"

## A single Bezier segment is one `M` followed by one `C`.
expect Svg.curves([{ from: { x: 0, y: 0 }, ctl_a: { x: 10, y: 0 }, ctl_b: { x: 10, y: 20 }, to: { x: 20, y: 20 } }], Svg.default_line_style) == "<path d=\"M 0 0 C 10 0, 10 20, 20 20\" fill=\"none\" stroke=\"#64748b\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" />"

## A segment starting where the previous one ended continues the subpath:
## one `M`, two `C`s.
expect Svg.curves(
	[
		{ from: { x: 0, y: 0 }, ctl_a: { x: 10, y: 0 }, ctl_b: { x: 10, y: 20 }, to: { x: 20, y: 20 } },
		{ from: { x: 20, y: 20 }, ctl_a: { x: 30, y: 20 }, ctl_b: { x: 30, y: 40 }, to: { x: 40, y: 40 } },
	],
	Svg.default_line_style,
) == "<path d=\"M 0 0 C 10 0, 10 20, 20 20 C 30 20, 30 40, 40 40\" fill=\"none\" stroke=\"#64748b\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" />"

## A segment starting elsewhere opens a new subpath with its own `M`.
expect Svg.curves(
	[
		{ from: { x: 0, y: 0 }, ctl_a: { x: 10, y: 0 }, ctl_b: { x: 10, y: 20 }, to: { x: 20, y: 20 } },
		{ from: { x: 25, y: 25 }, ctl_a: { x: 35, y: 25 }, ctl_b: { x: 35, y: 45 }, to: { x: 45, y: 45 } },
	],
	Svg.default_line_style,
) == "<path d=\"M 0 0 C 10 0, 10 20, 20 20 M 25 25 C 35 25, 35 45, 45 45\" fill=\"none\" stroke=\"#64748b\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" />"
