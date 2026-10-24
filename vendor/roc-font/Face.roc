import Sfnt
import TableCmap
import TableGlyf
import TableHead
import TableHhea
import TableHmtx
import TableMaxp
import TableOs2
import TableName
import TablePost
import TableVar
import LayoutGsub
import LayoutKerning

## A prepared face: every table `Font` uses, checked once, and the queries
## on it. `Font` is a face plus a location in its variation space.
##
## Internal. Reading composes the table readers (`from_tables` of each
## `Table*` and `Layout*` module), sorts their problems into required and
## optional tables, and applies the reading mode: a broken required table
## (`head`, `hhea`, `maxp`, `hmtx`, `cmap`, `loca`, `glyf`) rejects the font;
## a broken optional one (`OS/2`, `post`, `name`, `GSUB`, `GPOS`, `kern`,
## `fvar` with `avar`, `HVAR`, `MVAR`) is dropped and reported in
## `dropped`, unless reading is strict, which rejects for any problem.
Face := {
	units_per_em : U16,
	glyph_count : U64,
	advances : List(U16),
	boxes : List(TableGlyf.Bounds),
	cmap : TableCmap,
	hhea : TableHhea.Hhea,
	os2 : [Present(TableOs2.Metrics), Absent],
	post : TablePost,
	name : TableName,
	gsub : LayoutGsub,
	kerning : LayoutKerning,
	space : [Present(TableVar), Absent],
	hvar : [Present(TableVar.Hvar), Absent],
	mvar : [Present(TableVar.Mvar), Absent],
	max_depth : U64,
	dropped : List(Problem),
}.{

	Problem : [
		NotAFont,
		NoSuchFace({ face : U32, count : U32 }),
		OverLimit(Str),
		MissingTable(Str),
		BadTable({ table : Str, offset : U32 }),
		BadUnitsPerEm,
		NoUnicodeMapping,
	]

	Options : { face : U64, strict : Bool, max_bytes : U64, max_faces : U64, max_lookups : U64, max_depth : U64 }

	## A location in the variation space: normalised coordinates (F2Dot14,
	## one per axis, empty for a static font), the region scalars of the
	## `HVAR` and `MVAR` stores there, and whether any coordinate is not
	## zero (at the default location every delta is zero).
	Location : { coords : List(I16), hvar : List(U32), mvar : List(U32), varied : Bool }

	Metrics : {
		ascent : I32,
		descent : I32,
		line_gap : I32,
		cap_height : I32,
		x_height : I32,
		underline : { position : I32, thickness : I32 },
		strikeout : { position : I32, thickness : I32 },
	}

	default_location : Location
	default_location = { coords: [], hvar: [], mvar: [], varied: False }

	# ------------------------------------------------------------ reading

	## How many faces a file holds.
	face_count : List(U8) -> Try(U64, [NotAFont])
	face_count = |bytes| Sfnt.face_count(bytes)

	read : List(U8), Options -> Try(Face, List(Problem))
	read = |bytes, options| {
		if bytes.len() > options.max_bytes {
			return Err([OverLimit("max_bytes")])
		}
		count = match Sfnt.face_count(bytes) {
			Ok(c) => c
			Err(NotAFont) => return Err([NotAFont])
		}
		if count > options.max_faces {
			return Err([OverLimit("max_faces")])
		}
		tables = match Sfnt.directory_of(bytes, options.face) {
			Ok(t) => t
			Err(NotAFont) => return Err([NotAFont])
			Err(NoSuchFace(which)) => return Err([NoSuchFace(which)])
		}
		# A table that runs past the end of the file rejects the font, whichever
		# table it is, as OTS rejects it.
		var $required = []
		for t in tables {
			if !(t.offset <= bytes.len() and t.length <= bytes.len() - t.offset) {
				name = Str.from_utf8_lossy([t.tag.shr_zf_wrap(24), t.tag.shr_zf_wrap(16), t.tag.shr_zf_wrap(8), t.tag].map(|b| b.bitwise_and(0xFF).to_u8_wrap()))
				$required = $required.append(Sfnt.bad(name, t.offset))
			}
		}
		head = TableHead.from_tables(bytes, tables)
		hhea = TableHhea.from_tables(bytes, tables)
		maxp = TableMaxp.from_tables(bytes, tables)
		cmap = TableCmap.from_tables(bytes, tables)
		$required = Face.collect($required, head)
		$required = Face.collect($required, hhea)
		$required = Face.collect($required, maxp)
		$required = Face.collect($required, cmap)
		var $optional = []
		os2 = TableOs2.from_tables(bytes, tables)
		$optional = Face.collect($optional, os2)
		name = TableName.from_tables(bytes, tables)
		$optional = Face.collect_all($optional, name)
		match (head, hhea, maxp) {
			(Ok(h), Ok(hh), Ok(glyph_count)) => {
				advances = TableHmtx.from_tables(bytes, tables, hh.metric_count, glyph_count)
				boxes = TableGlyf.from_tables(bytes, tables, h.long_offsets, glyph_count)
				$required = Face.collect($required, advances)
				$required = Face.collect($required, boxes)
				post = TablePost.from_tables(bytes, tables, glyph_count)
				gsub = LayoutGsub.from_tables(bytes, tables, options.max_lookups)
				gpos = LayoutKerning.from_gpos(bytes, tables, glyph_count, options.max_lookups)
				kern = LayoutKerning.from_kern(bytes, tables)
				variations = Face.read_variations(bytes, tables, glyph_count)
				$optional = Face.collect_all($optional, post)
				$optional = Face.collect($optional, gsub)
				$optional = Face.collect($optional, gpos)
				match kern {
					Err(Drop(problem)) => {
						$optional = $optional.append(problem)
					}
					Err(Reject(problem)) => {
						$required = $required.append(problem)
					}
					Ok(_) => {}
				}
				$optional = $optional.concat(variations.problems)
				$required = Face.unique($required)
				$optional = Face.unique($optional).drop_if(|p| $required.contains(p))
				problems = $required.concat($optional)
				if !$required.is_empty() or (options.strict and !problems.is_empty()) {
					Err(problems)
				} else {
					match (advances, boxes, cmap) {
						(Ok(a), Ok(b), Ok(c)) =>
							Ok({
								units_per_em: h.units_per_em,
								glyph_count,
								advances: a,
								boxes: b,
								cmap: c,
								hhea: hh,
								os2: os2 ?? Absent,
								post: Face.present(post ?? Absent, TablePost.none),
								name: Face.present(name ?? Absent, TableName.none),
								gsub: gsub ?? LayoutGsub.none,
								kerning: LayoutKerning.combine(gpos ?? Absent, kern ?? Absent),
								space: variations.space,
								hvar: variations.hvar,
								mvar: variations.mvar,
								max_depth: options.max_depth,
								dropped: $optional,
							})
						# Unreachable: a failed required table is in `$required`.
						_ => Err(problems)
					}
				}
			}
			_ => {
				required = Face.unique($required)
				Err(required.concat(Face.unique($optional).drop_if(|p| required.contains(p))))
			}
		}
	}

	## Problems without repeats (a table past the end of the file is found
	## twice: by the directory check and by its reader), in first order.
	unique : List(Problem) -> List(Problem)
	unique = |problems| {
		var $out = []
		for p in problems {
			if !$out.contains(p) {
				$out = $out.append(p)
			}
		}
		$out
	}

	present : [Present(a), Absent], a -> a
	present = |found, fallback|
		match found {
			Present(value) => value
			Absent => fallback
		}

	## Add a reading result's problem, if it has one, to a list of problems.
	collect : List(p), Try(a, p) -> List(p)
	collect = |problems, result|
		match result {
			Ok(_) => problems
			Err(problem) => problems.append(problem)
		}

	collect_all : List(p), Try(a, List(p)) -> List(p)
	collect_all = |problems, result|
		match result {
			Ok(_) => problems
			Err(found) => problems.concat(found)
		}

	## `fvar` (with `avar`), then `HVAR` and `MVAR` when the variation space
	## reads. A bad `fvar` or `avar` drops the whole space; a bad `HVAR` or
	## `MVAR` drops only itself. `avar`, `HVAR` and `MVAR` without `fvar`
	## mean nothing and are not read.
	read_variations : List(U8), List(Sfnt.Table), U64 -> { space : [Present(TableVar), Absent], hvar : [Present(TableVar.Hvar), Absent], mvar : [Present(TableVar.Mvar), Absent], problems : List(Problem) }
	read_variations = |bytes, tables, glyph_count| {
		nothing = { space: Absent, hvar: Absent, mvar: Absent, problems: [] }
		match Sfnt.located(bytes, tables, "fvar", 0) {
			Missing => nothing
			Bad(at) => { ..nothing, problems: [Sfnt.bad("fvar", at)] }
			Found(fvar) => {
				avar = Sfnt.located(bytes, tables, "avar", 0)
				avar_offset = match avar {
					Found(found) => found.offset
					_ => 0
				}
				place = |problems| problems.map(|p| Sfnt.bad(p.table, (if (p.table == "avar") avar_offset else fvar.offset) + p.offset))
				space_read = match avar {
					Bad(at) => Err([Sfnt.bad("avar", at)])
					Found(found) => TableVar.read(fvar.data, Present(found.data)).map_err(place)
					Missing => TableVar.read(fvar.data, Absent).map_err(place)
				}
				match space_read {
					Err(problems) => { ..nothing, problems }
					Ok(space) => {
						axes = TableVar.axis_total(space)
						hvar = match Sfnt.located(bytes, tables, "HVAR", 0) {
							Missing => Ok(Absent)
							Bad(at) => Err([Sfnt.bad("HVAR", at)])
							Found(found) => TableVar.read_hvar(found.data, axes, glyph_count).map_ok(|value| Present(value)).map_err(|ps| ps.map(|p| Sfnt.bad(p.table, found.offset + p.offset)))
						}
						mvar = match Sfnt.located(bytes, tables, "MVAR", 0) {
							Missing => Ok(Absent)
							Bad(at) => Err([Sfnt.bad("MVAR", at)])
							Found(found) => TableVar.read_mvar(found.data, axes).map_ok(|value| Present(value)).map_err(|ps| ps.map(|p| Sfnt.bad(p.table, found.offset + p.offset)))
						}
						{
							space: Present(space),
							hvar: hvar ?? Absent,
							mvar: mvar ?? Absent,
							problems: Face.collect_all(Face.collect_all([], hvar), mvar),
						}
					}
				}
			}
		}
	}

	## The axis settings a `Font.Variation` stands for: CSS weight and width
	## values on `wght` and `wdth`, the optical size on `opsz` when given,
	## then the caller's axes whose tags are four bytes.
	settings : [Thin, ExtraLight, Light, Regular, Medium, SemiBold, Bold, ExtraBold, Black, Weight(U16)], [UltraCondensed, ExtraCondensed, Condensed, SemiCondensed, Normal, SemiExpanded, Expanded, ExtraExpanded, UltraExpanded, Percent(Dec)], [FontDefault, Size(Dec)], List({ tag : Str, value : Dec }) -> List({ tag : U32, value : Dec })
	settings = |weight_name, width_name, optical_size, axes| {
		weight = match weight_name {
			Thin => 100
			ExtraLight => 200
			Light => 300
			Regular => 400
			Medium => 500
			SemiBold => 600
			Bold => 700
			ExtraBold => 800
			Black => 900
			Weight(w) => Dec.from_attos(w.to_i128() * 1_000_000_000_000_000_000)
		}
		width = match width_name {
			UltraCondensed => 50
			ExtraCondensed => 62.5
			Condensed => 75
			SemiCondensed => 87.5
			Normal => 100
			SemiExpanded => 112.5
			Expanded => 125
			ExtraExpanded => 150
			UltraExpanded => 200
			Percent(p) => p
		}
		size = match optical_size {
			FontDefault => []
			Size(px) => [{ tag: Face.tag("opsz"), value: px }]
		}
		extra = axes.keep_if(|a| a.tag.to_utf8().len() == 4).map(|a| { tag: Face.tag(a.tag), value: a.value })
		[{ tag: Face.tag("wght"), value: weight }, { tag: Face.tag("wdth"), value: width }].concat(size).concat(extra)
	}

	# ------------------------------------------------------------ locations

	## The location for design-space settings (axis tag, value); see
	## `TableVar.coords_for`. A static font has one location.
	location : Face, List({ tag : U32, value : Dec }) -> Location
	location = |face, given|
		match face.space {
			Absent => Face.default_location
			Present(space) => {
				coords = TableVar.coords_for(space, given)
				hvar = match face.hvar {
					Present(h) => TableVar.region_scalars(h.store, coords)
					Absent => []
				}
				mvar = match face.mvar {
					Present(m) => TableVar.region_scalars(m.store, coords)
					Absent => []
				}
				{ coords, hvar, mvar, varied: coords.any(|c| c != 0) }
			}
		}

	## The axes of the variation space, in `fvar` order: tag, minimum,
	## default and maximum in design units.
	axes : Face -> List({ tag : Str, min : Dec, default : Dec, max : Dec })
	axes = |face|
		match face.space {
			Absent => []
			Present(space) => {
				# Fixed 16.16 is exact in `Dec`: 10^18 / 65536 is a whole number.
				dec = |list, a| Dec.from_attos((list.get(a) ?? 0).to_i128() * 15_258_789_062_500)
				var $out = List.with_capacity(space.tags.len())
				for a in 0..<space.tags.len() {
					t = (space.tags.get(a) ?? 0).to_u64()
					bytes = [t.shr_zf_wrap(24), t.shr_zf_wrap(16), t.shr_zf_wrap(8), t].map(|b| b.bitwise_and(0xFF).to_u8_wrap())
					$out = $out.append({ tag: Str.from_utf8_lossy(bytes), min: dec(space.minimum, a), default: dec(space.default, a), max: dec(space.maximum, a) })
				}
				$out
			}
		}

	## Whether the face has an axis with this tag.
	has_axis : Face, U32 -> Bool
	has_axis = |face, tag|
		match face.space {
			Absent => False
			Present(space) => space.tags.contains(tag)
		}

	# ------------------------------------------------------------ queries

	units_per_em : Face -> U16
	units_per_em = |face| face.units_per_em

	glyph_count : Face -> U64
	glyph_count = |face| face.glyph_count

	dropped : Face -> List(Problem)
	dropped = |face| face.dropped

	glyph : Face, U32 -> Try(U64, [Missing])
	glyph = |face, code_point| TableCmap.glyph(face.cmap, code_point, face.glyph_count)

	code_points : Face -> List(U32)
	code_points = |face| TableCmap.code_points(face.cmap, face.glyph_count)

	## A glyph's advance at a location: `hmtx`, plus the `HVAR` delta away
	## from the default location. Past the font: 0, as HarfBuzz.
	advance : Face, Location, U64 -> I32
	advance = |face, loc, id|
		match face.advances.get(id) {
			Err(_) => 0
			Ok(base) =>
				match face.hvar {
					Present(hvar) if loc.varied => TableVar.advance(hvar, loc.hvar, id, base.to_i64()).to_i32_wrap()
					_ => base.to_i32()
				}
		}

	## A glyph's bounding box at the default location, or `Empty`.
	extents : Face, U64 -> [Extents({ x_min : I32, y_min : I32, x_max : I32, y_max : I32 }), Empty]
	extents = |face, id|
		match face.boxes.get(id) {
			Ok(b) if b.x_min <= b.x_max and b.y_min <= b.y_max => Extents({ x_min: b.x_min.to_i32(), y_min: b.y_min.to_i32(), x_max: b.x_max.to_i32(), y_max: b.y_max.to_i32() })
			_ => Empty
		}

	tag : Str -> U32
	tag = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u32())

	# A metric at a location: `MVAR`'s delta for `tag` added to the stored
	# value, rounded as HarfBuzz rounds it.
	varied : Face, Location, Str, I32 -> I32
	varied = |face, loc, name, value|
		match face.mvar {
			Present(mvar) if loc.varied => TableVar.metric(mvar, loc.mvar, Face.tag(name), value.to_i64()).to_i32_wrap()
			_ => value
		}

	metrics : Face, Location -> Metrics
	metrics = |face, loc| {
		v = |name, value| Face.varied(face, loc, name, value)
		hh = face.hhea
		upem = face.units_per_em.to_i32()
		vertical = match face.os2 {
			Present(o) if o.use_typo => { ascent: v("hasc", o.typo_ascent), descent: -v("hdsc", o.typo_descent), line_gap: v("hlgp", o.typo_line_gap) }
			_ if hh.ascent != 0 or hh.descent != 0 => { ascent: v("hasc", hh.ascent), descent: -v("hdsc", hh.descent), line_gap: v("hlgp", hh.line_gap) }
			Present(o) if o.typo_ascent != 0 or o.typo_descent != 0 => { ascent: v("hasc", o.typo_ascent), descent: -v("hdsc", o.typo_descent), line_gap: v("hlgp", o.typo_line_gap) }
			Present(o) => { ascent: v("hcla", o.win_ascent), descent: v("hcld", o.win_descent), line_gap: 0 }
			Absent => { ascent: 0, descent: 0, line_gap: 0 }
		}
		# HarfBuzz's fallbacks for heights the font does not store.
		box_of = |code_point|
			match Face.glyph(face, code_point) {
				Err(_) => NoGlyph
				Ok(g) =>
					match Face.extents(face, g) {
						Extents(b) => Box(b)
						Empty => Box({ x_min: 0, y_min: 0, x_max: 0, y_max: 0 })
					}
			}
		stored = match face.os2 {
			Present(o) => o.heights
			Absent => Absent
		}
		heights = match stored {
			Present(h) => { x_height: v("xhgt", h.x_height), cap_height: v("cpht", h.cap_height) }
			Absent => {
				x_height: match box_of('x') {
					Box(b) => b.y_max
					NoGlyph => upem // 2
				},
				cap_height: match box_of('O') {
					Box(b) => b.y_max + b.y_min
					NoGlyph => upem * 2 // 3
				},
			}
		}
		strikeout = match face.os2 {
			Present(o) => { position: v("stro", o.strikeout_position), thickness: v("strs", o.strikeout_size) }
			Absent => { position: vertical.ascent // 2, thickness: upem // 18 }
		}
		line = TablePost.underline(face.post)
		{
			ascent: vertical.ascent,
			descent: vertical.descent,
			line_gap: vertical.line_gap,
			cap_height: heights.cap_height,
			x_height: heights.x_height,
			underline: { position: v("undo", line.position), thickness: v("unds", line.thickness) },
			strikeout,
		}
	}

	family_name : Face -> Try(Str, [Missing])
	family_name = |face| TableName.family_name(face.name)

	glyph_name : Face, U64 -> Try(Str, [Missing])
	glyph_name = |face, id| if (id > 0xFFFFFFFF) Err(Missing) else TablePost.glyph_name(face.post, id.to_u32_wrap())

	gsub : Face -> LayoutGsub
	gsub = |face| face.gsub

	kerning : Face -> LayoutKerning
	kerning = |face| face.kerning

	max_depth : Face -> U64
	max_depth = |face| face.max_depth
}
