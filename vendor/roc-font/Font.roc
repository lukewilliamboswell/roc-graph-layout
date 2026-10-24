import Face
import Shaper

## A font read from TrueType or OpenType bytes, ready to measure and shape
## text. Read it once with `from_bytes`; every query and every shaping call
## on it then succeeds.
##
## Everything is in font units: integers in the font's own grid of
## `units_per_em` units to the em. Divide by `units_per_em` and multiply by
## the font size for pixels or points; rounding to a device grid is left to
## the caller, because every consumer rounds differently.
##
## Glyph ids are `U32`. Text is a `Str`, and shaping reports which part of
## the text each glyph draws as UTF-8 byte offsets into it (clusters).
##
## No font is built in: callers supply the bytes of the font they use. The
## bytes are never trusted; `from_bytes` reports everything wrong with a
## file it cannot use.
Font :: { face : Face, location : Face.Location }.{

	# ------------------------------------------------------------ reading

	## How to read a font file.
	##
	## - `face`: which font of a collection (a `.ttc` file) to read, from 0.
	##   A single font file has only face 0.
	## - `strict`: reject the font for any problem. By default reading is
	##   lenient, as browsers are: a broken optional table (such as
	##   substitutions, positioning, kerning, names or variations) is left
	##   out and reported by `dropped`, and the font reads without it.
	## - `limits`: bounds on the work and memory a file may ask for.
	ReadOptions := { face : U32 ?? 0, strict : Bool ?? False, limits : Limits ?? Limits.{} }

	## Bounds on what a font file may ask for. Exceeding one is an
	## `OverLimit` problem naming the field, never a crash.
	##
	## - `max_bytes`: the largest file accepted.
	## - `max_faces`: the most faces a collection may hold.
	## - `max_lookups`: the most substitution or positioning lookups a table
	##   may list; a table with more is dropped (or, when strict, rejects the
	##   font).
	## - `max_depth`: how deeply contextual substitutions may call further
	##   substitutions while shaping.
	##
	## The defaults admit every real font with room to spare.
	Limits := { max_bytes : U64 ?? 268_435_456, max_faces : U32 ?? 1024, max_lookups : U32 ?? 16_384, max_depth : U32 ?? 64 }

	## Why bytes could not be read as a font, or what lenient reading left
	## out.
	##
	## - `NotAFont`: too short, or not a TrueType, OpenType or collection
	##   signature.
	## - `NoSuchFace`: `ReadOptions.face` is not below the collection's face
	##   count.
	## - `OverLimit`: the `Limits` field that was exceeded.
	## - `MissingTable`: a table the font cannot be used without, by its
	##   four-letter tag (`head`, `hhea`, `maxp`, `hmtx` or `cmap`).
	## - `BadTable`: a table by its tag, and the byte offset in the file of
	##   the part that is wrong (a count, an offset or a record that does not
	##   fit, or a value the format does not allow).
	## - `BadUnitsPerEm`: units per em outside 16 to 16384.
	## - `NoUnicodeMapping`: no character map this reader can use (one for
	##   Unicode, a Windows symbol map or a Macintosh map, in format 0, 4, 6,
	##   10, 12 or 13).
	Problem : [
		NotAFont,
		NoSuchFace({ face : U32, count : U32 }),
		OverLimit(Str),
		MissingTable(Str),
		BadTable({ table : Str, offset : U32 }),
		BadUnitsPerEm,
		NoUnicodeMapping,
	]

	## Read a font file. Every independent problem is reported at once.
	##
	## ```
	## font = Font.from_bytes(bytes, Font.ReadOptions.{})?
	## pdf_font = Font.from_bytes(bytes, Font.ReadOptions.{ strict: True })?
	## ```
	##
	## The font measures at `Variation.{}` (Regular weight) until `at` moves
	## it.
	from_bytes : List(U8), ReadOptions -> Try(Font, List(Problem))
	from_bytes = |bytes, options| {
		limits = options.limits
		read = Face.read(bytes, { face: options.face.to_u64(), strict: options.strict, max_bytes: limits.max_bytes, max_faces: limits.max_faces.to_u64(), max_lookups: limits.max_lookups.to_u64(), max_depth: limits.max_depth.to_u64() })
		match read {
			Ok(face) => Ok({ face, location: Face.location(face, Face.settings(Regular, Normal, FontDefault, [])) })
			Err(problems) => Err(problems)
		}
	}

	## How many fonts a file holds: 1 for a single font file, the face count
	## of a collection.
	face_count : List(U8) -> Try(U32, [NotAFont])
	face_count = |bytes|
		match Face.face_count(bytes) {
			Ok(count) => Ok(count.min(0xFFFFFFFF).to_u32_wrap())
			Err(NotAFont) => Err(NotAFont)
		}

	## The problems of the optional tables lenient reading left out; empty
	## when nothing was left out.
	dropped : Font -> List(Problem)
	dropped = |font| Face.dropped(font.face)

	# ------------------------------------------------------------ facts

	## The font's vertical measures, in font units, at the font's location.
	##
	## - `ascent` and `descent`: the height above and the depth below the
	##   baseline (both positive for ordinary fonts), and `line_gap`, the
	##   extra space between lines, as a browser takes them: the typographic
	##   values when the font asks for them, else the horizontal header's,
	##   else the typographic ones, else the Windows ones (with no line gap).
	## - `cap_height` and `x_height`: the height of capitals and of small
	##   letters. Fonts that do not store them get HarfBuzz's estimates: the
	##   top of `x`, and the top plus the bottom of `O` (half and two thirds
	##   of the em without those letters).
	## - `underline` and `strikeout`: each line's position (its top, from the
	##   baseline, negative below) and thickness. A font without the tables
	##   that store them has no underline (zeros) and, for strikeout,
	##   HarfBuzz's estimate: half the ascent, one eighteenth of the em thick.
	Metrics : {
		ascent : I32,
		descent : I32,
		line_gap : I32,
		cap_height : I32,
		x_height : I32,
		underline : { position : I32, thickness : I32 },
		strikeout : { position : I32, thickness : I32 },
	}

	## The size of the em square in font units.
	units_per_em : Font -> U16
	units_per_em = |font| Face.units_per_em(font.face)

	## The font's vertical measures; see `Metrics`. In a variable font they
	## follow the font's location.
	metrics : Font -> Metrics
	metrics = |font| Face.metrics(font.face, font.location)

	## How many glyphs the font has; glyph ids run below this.
	glyph_count : Font -> U32
	glyph_count = |font| Face.glyph_count(font.face).min(0xFFFFFFFF).to_u32_wrap()

	## The glyph that draws a Unicode code point, if the font has one. Fonts
	## whose character map is not in Unicode (old symbol fonts and Macintosh
	## fonts) are translated to Unicode the way HarfBuzz does.
	glyph : Font, U32 -> Try(U32, [Missing])
	glyph = |font, code_point|
		match Face.glyph(font.face, code_point) {
			Ok(g) => Ok(g.to_u32_wrap())
			Err(Missing) => Err(Missing)
		}

	## A glyph's advance width, at the font's location. A glyph id past the
	## font has an advance of 0, as in HarfBuzz.
	advance : Font, U32 -> I32
	advance = |font, id| Face.advance(font.face, font.location, id.to_u64())

	## A glyph's bounding box, or `Empty` for a glyph that draws nothing
	## (such as a space), a glyph id past the font, or a font without
	## TrueType outlines. Current limit: boxes are those of the font's
	## default instance, wherever `at` puts a variable font.
	extents : Font, U32 -> [Extents({ x_min : I32, y_min : I32, x_max : I32, y_max : I32 }), Empty]
	extents = |font, id| Face.extents(font.face, id.to_u64())

	## Every code point the font maps to a glyph, in increasing order: what a
	## glyph atlas or a coverage check needs.
	code_points : Font -> List(U32)
	code_points = |font| Face.code_points(font.face)

	## The font's family name (such as `Inter`), in English when the font
	## has it: the typographic family name if present, else the family name.
	family_name : Font -> Try(Str, [Missing])
	family_name = |font| Face.family_name(font.face)

	## A glyph's PostScript name (such as `uni00E9`), if the font has names.
	glyph_name : Font, U32 -> Try(Str, [Missing])
	glyph_name = |font, id| Face.glyph_name(font.face, id.to_u64())

	# ------------------------------------------------------------ variations

	## Where to measure a variable font: its weight, width and optical size,
	## and any other axis by its tag.
	##
	## - `weight` and `width` follow CSS (`font-weight`, `font-stretch`).
	## - `optical_size`: the font's own default, or `Size(px)` for text drawn
	##   at that size, as a browser sets it.
	## - `axes`: values for any axis, such as `{ tag: "GRAD", value: 50 }`.
	##   They apply after the named fields and override them, like CSS
	##   `font-variation-settings`; a later entry for one tag wins. A tag
	##   that is not four bytes, or that the font lacks, is ignored.
	##
	## Values outside an axis's range are clamped to it, as the format
	## defines. Named fields apply only to axes the font has, and a font
	## without variations ignores them all.
	Variation := { weight : Weight ?? Regular, width : Width ?? Normal, optical_size : OpticalSize ?? FontDefault, axes : List({ tag : Str, value : Dec }) ?? [] }

	## CSS weights: `Thin` is 100, `Regular` 400, `Bold` 700, `Black` 900,
	## or any value from 1 to 1000.
	Weight : [Thin, ExtraLight, Light, Regular, Medium, SemiBold, Bold, ExtraBold, Black, Weight(U16)]

	## CSS widths, as a percentage of normal: `UltraCondensed` is 50,
	## `ExtraCondensed` 62.5, `Condensed` 75, `SemiCondensed` 87.5, `Normal`
	## 100, `SemiExpanded` 112.5, `Expanded` 125, `ExtraExpanded` 150 and
	## `UltraExpanded` 200.
	Width : [UltraCondensed, ExtraCondensed, Condensed, SemiCondensed, Normal, SemiExpanded, Expanded, ExtraExpanded, UltraExpanded, Percent(Dec)]

	## The font's own default optical size, or the size in CSS pixels the
	## text is drawn at.
	OpticalSize : [FontDefault, Size(Dec)]

	## One axis of a variable font: its four-letter tag (such as `wght`) and
	## its range in the axis's own units.
	Axis : { tag : Str, min : Dec, default : Dec, max : Dec }

	## The font at another point of its variation space. Every query and
	## shaping call on the result measures there: advances and metrics vary.
	## Current limits: glyph boxes (`extents`) and kerning stay those of
	## the font's default instance. Cheap: the font's tables are shared.
	##
	## ```
	## bold = Font.at(font, Font.Variation.{ weight: Bold })
	## ```
	at : Font, Variation -> Font
	at = |font, variation| { face: font.face, location: Face.location(font.face, Face.settings(variation.weight, variation.width, variation.optical_size, variation.axes)) }

	## The axes of a variable font, in the font's order; empty for a static
	## font.
	axes : Font -> List(Axis)
	axes = |font| Face.axes(font.face)

	# ------------------------------------------------------------ shaping

	## Which way text runs. `FromScript` takes the script's own direction
	## (right to left for Arabic and Hebrew, for example; left to right for
	## an empty script).
	Direction : [FromScript, LeftToRight, RightToLeft]

	## How clusters merge, as HarfBuzz's monotone cluster levels: glyphs that
	## draw several characters together (ligatures) share the first
	## character's cluster either way. Forming clusters of whole graphemes
	## (a letter with its accents) needs Unicode data roc-font leaves to the
	## `unicode` package: pass each scalar's grapheme start as its offset to
	## `shape_scalars` for that.
	ClusterLevel : [Graphemes, Characters]

	## A typographic feature, turned on (value 1, the default), off (0) or to
	## a value, over the whole text or the UTF-8 byte range `start ..< end`.
	##
	## ```
	## no_ligatures = Font.Feature.{ tag: "liga", value: 0 }
	## small_caps = Font.Feature.{ tag: "smcp", start: 4, end: 9 }
	## ```
	##
	## The tag is the feature's four-letter OpenType name. Values above 1
	## turn a feature on; choosing among alternates by value is not
	## supported yet.
	Feature := { tag : Str, value : U32 ?? 1, start : U32 ?? 0, end : U32 ?? 4_294_967_295 }

	## Bounds on shaping work, per input character, never below 16384 in
	## all: `growth` bounds how many glyphs the run may grow to and
	## `operations` how many nested substitutions may be made (HarfBuzz's
	## factors). Past them shaping stops changing the run and returns what it
	## has; the defaults never bind on a real font.
	ShapeLimits := { growth : U32 ?? 64, operations : U32 ?? 1024 }

	## How to shape.
	##
	## - `script`: the text's ISO 15924 script code, such as `Latn`, `Grek`,
	##   `Cyrl` or `Arab`. Empty is Latin, as a browser shapes text whose
	##   script it is not told. roc-font does not detect scripts; split text
	##   into runs of one script (with the `unicode` package) first.
	## - `language`: a BCP 47 language tag, such as `en`, `tr` or `sr-Latn`,
	##   which can select the font's language-specific forms. Empty is none.
	##   `-x-hbot` and `-x-hbsc` private-use subtags give raw OpenType
	##   language and script tags, as in HarfBuzz.
	## - `direction`, `features`, `clusters` and `limits`: see their types.
	##   Without features, the browser defaults for the direction apply
	##   (ligatures, contextual forms and kerning, among others).
	##
	## Every script is shaped as HarfBuzz's default shaper shapes it. Scripts
	## that need more (Arabic joining, Indic reordering, Hebrew's own rules)
	## and steps that need Unicode data (normalisation, mirroring brackets in
	## right-to-left text, hiding default-ignorable characters) are not done
	## yet.
	ShapeOptions := { script : Str ?? "", language : Str ?? "", direction : Direction ?? FromScript, features : List(Feature) ?? [], clusters : ClusterLevel ?? Graphemes, limits : ShapeLimits ?? ShapeLimits.{} }

	## A shaped run, one entry per glyph in each list, in visual order (left
	## to right, also for right-to-left text):
	##
	## - `glyphs`: glyph ids;
	## - `advances`: how far each glyph moves the pen, in font units;
	## - `offsets`: where to draw each glyph relative to the pen;
	## - `clusters`: the UTF-8 byte offset in the text of the first character
	##   each glyph draws;
	## - `flags`: bit 0 is set when breaking the text at the start of the
	##   glyph's cluster would change the glyphs on either side (a ligature
	##   or kerning spans it), so both sides must be shaped again.
	Run : { glyphs : List(U32), advances : List({ x : I32, y : I32 }), offsets : List({ x : I32, y : I32 }), clusters : List(U32), flags : List(U8) }

	## The choices `ShapeOptions` make for one font, worked out once. Plan
	## once and shape many times with `shape_planned`. A plan belongs to the
	## font it was made for; with another font the run is defined but
	## meaningless.
	ShapePlan :: { plan : Shaper.Plan }

	## Work out a plan for shaping with these options.
	plan : Font, ShapeOptions -> ShapePlan
	plan = |font, options| {
		limits = options.limits
		features = options.features.map(|f| { tag: f.tag, value: f.value, start: f.start, end: f.end })
		{ plan: Shaper.plan(font.face, { script: options.script, language: options.language, direction: options.direction, features, growth: limits.growth.to_u64(), operations: limits.operations.to_u64() }) }
	}

	## Shape text: the glyphs that draw it, where, and which text each draws.
	##
	## ```
	## run = Font.shape(font, "office -> home", Font.ShapeOptions.{})
	## ```
	shape : Font, Str, ShapeOptions -> Run
	shape = |font, text, options| Font.shape_planned(font, Font.plan(font, options), text)

	## Shape text with a plan made by `plan`.
	shape_planned : Font, ShapePlan, Str -> Run
	shape_planned = |font, shape_plan, text| Shaper.shape(font.face, font.location, shape_plan.plan, Shaper.decode(text))

	## Shape characters a paragraph layer has already split up: each scalar
	## value with the offset to report as its cluster (normally its UTF-8
	## byte offset in the paragraph). Scalars sharing an offset form one
	## cluster. Clusters in the run are these offsets.
	shape_scalars : Font, ShapePlan, List({ scalar : U32, offset : U32 }) -> Run
	shape_scalars = |font, shape_plan, scalars| Shaper.shape(font.face, font.location, shape_plan.plan, scalars)

	## The width of text shaped with the default options: the sum of its
	## advances, in font units.
	width : Font, Str -> I32
	width = |font, text| {
		run = Font.shape(font, text, ShapeOptions.{})
		total = run.advances.fold(0.I64, |sum, a| sum + a.x.to_i64())
		total.max(-2147483648).min(2147483647).to_i32_wrap()
	}
}
