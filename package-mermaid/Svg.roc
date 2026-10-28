import Drawing

## Writes a `Drawing.Picture` as a standalone SVG document. The output is
## well-formed XML whatever the label text holds, and the same picture always
## produces the same bytes: numbers are written with at most three decimals
## and never in exponent form, and paint is set with attributes rather than a
## style sheet, so documents can be inlined into a page side by side.
Svg :: {}.{

	## An SVG document showing exactly the picture's view, at one CSS pixel
	## per unit, with every label set in `font_family`.
	document : Drawing.Picture, Str -> Str
	document = |picture, font_family| {
		view = picture.view
		width = view.width.max(0)
		height = view.height.max(0)
		family = SvgParts.escape(font_family)
		var $out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"${SvgParts.number(view.x)} ${SvgParts.number(view.y)} ${SvgParts.number(width)} ${SvgParts.number(height)}\" width=\"${SvgParts.number(width)}\" height=\"${SvgParts.number(height)}\">\n"
		for item in picture.items {
			$out = $out.concat(SvgParts.item(item, family))
		}
		$out.concat("</svg>\n")
	}
}

# The parts of a document; internal, since only `Svg` is visible to importers.
SvgParts :: {}.{

	item : Drawing.Item, Str -> Str
	item = |it, family|
		match it {
			Shape(shape) => {
				fill = match shape.paint.fill {
					NoFill => "none"
					Fill(color) => SvgParts.color(color)
				}
				stroke = match shape.paint.stroke {
					NoStroke => ""
					Stroke(s) => " stroke=\"${SvgParts.color(s.color)}\" stroke-width=\"${SvgParts.number(s.width)}\""
				}
				d = SvgParts.path_data(shape.path)
				if d == "" or (fill == "none" and stroke == "") {
					""
				} else {
					"<path d=\"${d}\" fill=\"${fill}\"${stroke}/>\n"
				}
			}
			Text(label) => SvgParts.label_item(label, family, "")
			StyledText(styled) => SvgParts.label_item(
				styled.label,
				family,
				Str.join_with(
					[
						if styled.italic {
							" font-style=\"italic\""
						} else {
							""
						},
						if styled.underline {
							" text-decoration=\"underline\""
						} else {
							""
						},
						if styled.bold {
							" font-weight=\"bold\""
						} else {
							""
						},
					],
					"",
				),
			)
		}

	label_item : Drawing.Label, Str, Str -> Str
	label_item = |label, family, attributes| {
		anchor = match label.align {
			Start => ""
			Center => " text-anchor=\"middle\""
			End => " text-anchor=\"end\""
		}
		"<text x=\"${SvgParts.number(label.origin.x)}\" y=\"${SvgParts.number(label.origin.y)}\" font-family=\"${family}\" font-size=\"${SvgParts.number(label.size)}\" fill=\"${SvgParts.color(label.color)}\"${anchor}${attributes}>${SvgParts.escape(label.text)}</text>\n"
	}

	## Path data in absolute commands.
	path_data : List(Drawing.Segment) -> Str
	path_data = |path| {
		pt = |p| "${SvgParts.number(p.x)} ${SvgParts.number(p.y)}"
		var $out = ""
		for segment in path {
			$out = $out.concat(
				match segment {
					MoveTo(p) => "M${pt(p)}"
					LineTo(p) => "L${pt(p)}"
					CubicTo(c) => "C${pt(c.control_1)} ${pt(c.control_2)} ${pt(c.end)}"
					Close => "Z"
				},
			)
		}
		$out
	}

	## `#rrggbb`.
	color : Drawing.Color -> Str
	color = |c| "#${SvgParts.hex(c.red)}${SvgParts.hex(c.green)}${SvgParts.hex(c.blue)}"

	hex : U8 -> Str
	hex = |byte| {
		digit = |d| if (d < 10) '0' + d else 'a' + d - 10
		Str.from_utf8_lossy([digit(byte // 16), digit(byte % 16)])
	}

	## A number rounded to three decimals, without trailing zeros, exponent
	## or negative zero. Values beyond about 9.2e15 and non-finite values,
	## which a picture never holds, are written as `0`.
	number : F64 -> Str
	number = |value| {
		scaled = if (F64.is_finite(value) and value.abs() < 9.0e12) (value * 1000).round_to_i64_try() ?? 0 else 0
		if scaled == 0 {
			"0"
		} else {
			sign = if (scaled < 0) "-" else ""
			magnitude = scaled.abs()
			whole = (magnitude // 1000).to_str()
			fraction = magnitude % 1000
			if fraction == 0 {
				"${sign}${whole}"
			} else {
				digits = (1000 + fraction).to_str().to_utf8().drop_first(1)
				var $len = digits.len()
				while $len > 0 and (digits.get($len - 1) ?? '0') == '0' {
					$len = $len - 1
				}
				"${sign}${whole}.${Str.from_utf8_lossy(digits.take_first($len))}"
			}
		}
	}

	## Text as XML character data and attribute values: markup characters
	## and quotes escaped, tabs and line breaks as spaces, and characters XML
	## cannot hold at all (other control characters, U+FFFE and U+FFFF)
	## left out.
	escape : Str -> Str
	escape = |text| {
		bytes = text.to_utf8()
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		while $i < bytes.len() {
			b = bytes.get($i) ?? 0
			if b == 0xEF and (bytes.get($i + 1) ?? 0) == 0xBF and ((bytes.get($i + 2) ?? 0) == 0xBE or (bytes.get($i + 2) ?? 0) == 0xBF) {
				$i = $i + 3
			} else {
				$out = match b {
					'&' => $out.concat("&amp;".to_utf8())
					'<' => $out.concat("&lt;".to_utf8())
					'>' => $out.concat("&gt;".to_utf8())
					'"' => $out.concat("&quot;".to_utf8())
					'\'' => $out.concat("&apos;".to_utf8())
					'\t' => $out.append(' ')
					'\n' => $out.append(' ')
					'\r' => $out.append(' ')
					c if c < 0x20 => $out
					c => $out.append(c)
				}
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}
}

expect SvgParts.number(0) == "0"
expect SvgParts.number(-0.0001) == "0"
expect SvgParts.number(12) == "12"
expect SvgParts.number(-3.5) == "-3.5"
expect SvgParts.number(0.125) == "0.125"
expect SvgParts.number(1.0005) == "1.001"
expect SvgParts.number(7.0710678) == "7.071"
expect SvgParts.number(0.05) == "0.05"
expect SvgParts.number(1.0e300) == "0"
expect SvgParts.number(F64.nan) == "0"
expect SvgParts.color({ red: 40, green: 37, blue: 61 }) == "#28253d"
expect SvgParts.escape("a<b & \"c\" 'd'>") == "a&lt;b &amp; &quot;c&quot; &apos;d&apos;&gt;"
expect SvgParts.escape("x\u(0)y\u(1F)z\u(FFFF)") == "xyz"
expect SvgParts.escape("é ✓") == "é ✓"

expect
	Svg.document(
		{
			view: { x: 0, y: 0, width: 10, height: 20 },
			items: [
				Shape({ path: Drawing.rectangle({ x: 1, y: 2, width: 3, height: 4 }), paint: { fill: Fill(Drawing.white), stroke: Stroke({ color: Drawing.black, width: 2 }) } }),
				Text({ text: "A&B", origin: { x: 5, y: 6 }, size: 14, align: Center, color: Drawing.black }),
			],
		},
		"Inter",
	)
		== "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 20\" width=\"10\" height=\"20\">\n<path d=\"M1 2L4 2L4 6L1 6Z\" fill=\"#ffffff\" stroke=\"#000000\" stroke-width=\"2\"/>\n<text x=\"5\" y=\"6\" font-family=\"Inter\" font-size=\"14\" fill=\"#000000\" text-anchor=\"middle\">A&amp;B</text>\n</svg>\n"

expect {
	picture = { view: { x: 0, y: 0, width: 100, height: 40 }, items: [StyledText({ label: { text: "<member>", origin: { x: 12, y: 20 }, size: 14, align: Start, color: Drawing.black }, italic: True, underline: True, bold: False })] }
	svg = Svg.document(picture, "Inter")
	Drawing.is_finite(picture) and svg.contains("font-style=\"italic\"") and svg.contains("text-decoration=\"underline\"") and svg.contains("&lt;member&gt;")
}
