## Small synthetic font files for tests and fuzz seeds: big-endian fields,
## tables whose offsets are worked out from the sizes of their parts, and a
## complete minimal font. Nothing here reads fonts; see `Font` and
## `FontShape`.
FontTest :: {}.{

	## A field of a table under construction. `Ref` and `Ref32` write a 16- or
	## 32-bit offset to a child table, which is placed after the fields in the
	## order the references appear; offsets count from the start of the table.
	Field : [U16(U64), I16(I64), U32(U64), Tag(Str), Ref(List(U8)), Ref32(List(U8)), Raw(List(U8))]

	u16 : U64 -> List(U8)
	u16 = |v| [v.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), v.bitwise_and(0xFF).to_u8_wrap()]

	u32 : U64 -> List(U8)
	u32 = |v| FontTest.u16(v.shr_zf_wrap(16).bitwise_and(0xFFFF)).concat(FontTest.u16(v.bitwise_and(0xFFFF)))

	i16 : I64 -> List(U8)
	i16 = |v| FontTest.u16((if (v < 0) v + 65536 else v).to_u64_wrap())

	size : Field -> U64
	size = |field|
		match field {
			U16(_) => 2
			I16(_) => 2
			Ref(_) => 2
			U32(_) => 4
			Tag(_) => 4
			Ref32(_) => 4
			Raw(bytes) => bytes.len()
		}

	## Lay out fields, then the tables they refer to.
	pack : List(Field) -> List(U8)
	pack = |fields| {
		var $head = []
		var $tail = []
		var $next = fields.fold(0, |sum, f| sum + FontTest.size(f))
		for field in fields {
			match field {
				U16(v) => {
					$head = $head.concat(FontTest.u16(v))
				}
				I16(v) => {
					$head = $head.concat(FontTest.i16(v))
				}
				U32(v) => {
					$head = $head.concat(FontTest.u32(v))
				}
				Tag(name) => {
					$head = $head.concat(name.to_utf8().concat([' ', ' ', ' ', ' ']).take_first(4))
				}
				Raw(bytes) => {
					$head = $head.concat(bytes)
				}
				Ref(child) => {
					$head = $head.concat(FontTest.u16($next))
					$tail = $tail.concat(child)
					$next = $next + child.len()
				}
				Ref32(child) => {
					$head = $head.concat(FontTest.u32($next))
					$tail = $tail.concat(child)
					$next = $next + child.len()
				}
			}
		}
		$head.concat($tail)
	}

	## A font file holding the given tables, each aligned to four bytes.
	file : List({ tag : Str, data : List(U8) }) -> List(U8)
	file = |tables| {
		count = tables.len()
		var $records = []
		var $body = []
		var $offset = 12 + 16 * count
		for t in tables {
			$records = $records.concat(t.tag.to_utf8().concat([' ', ' ', ' ', ' ']).take_first(4)).concat(FontTest.u32(0)).concat(FontTest.u32($offset)).concat(FontTest.u32(t.data.len()))
			padding = (4 - t.data.len() % 4) % 4
			$body = $body.concat(t.data).concat(List.repeat(0, padding))
			$offset = $offset + t.data.len() + padding
		}
		FontTest.u32(0x00010000).concat(FontTest.u16(count)).concat(FontTest.u16(0)).concat(FontTest.u16(0)).concat(FontTest.u16(0)).concat($records).concat($body)
	}

	## A `head` table: 54 bytes with units per em at 18 and the `loca` format
	## at 50.
	head : U64, Bool -> List(U8)
	head = |units, long_loca|
		List.repeat(0, 18).concat(FontTest.u16(units)).concat(List.repeat(0, 30)).concat(FontTest.u16(if (long_loca) 1 else 0)).concat(FontTest.u16(0))

	## An `hhea` table: ascent, descent (negative below the baseline) and the
	## number of long metrics.
	hhea : I64, I64, U64 -> List(U8)
	hhea = |ascent, descent, metrics|
		FontTest.u32(0x00010000).concat(FontTest.i16(ascent)).concat(FontTest.i16(descent)).concat(List.repeat(0, 26)).concat(FontTest.u16(metrics))

	maxp : U64 -> List(U8)
	maxp = |glyphs| FontTest.u32(0x00005000).concat(FontTest.u16(glyphs))

	## An `OS/2` table with the vertical metrics `Font` reads.
	os2 : { use_typo : Bool, typo_ascent : I64, typo_descent : I64, win_ascent : U64, win_descent : U64 } -> List(U8)
	os2 = |o|
		List.repeat(0, 62)
			.concat(FontTest.u16(if (o.use_typo) 0x80 else 0))
			.concat(List.repeat(0, 4))
			.concat(FontTest.i16(o.typo_ascent))
			.concat(FontTest.i16(o.typo_descent))
			.concat(FontTest.u16(0))
			.concat(FontTest.u16(o.win_ascent))
			.concat(FontTest.u16(o.win_descent))
			.concat(List.repeat(0, 8))

	## Long horizontal metrics: an advance and a zero left side bearing each.
	hmtx : List(U64) -> List(U8)
	hmtx = |advances| advances.fold([], |acc, a| acc.concat(FontTest.u16(a)).concat(FontTest.u16(0)))

	## A `cmap` table with the given encoding records (platform as `system`, encoding,
	## subtable).
	cmap : List({ system : U64, encoding : U64, subtable : List(U8) }) -> List(U8)
	cmap = |records|
		FontTest.pack(
			[U16(0), U16(records.len())].concat(records.join_map(|r| [U16(r.system), U16(r.encoding), Ref32(r.subtable)])),
		)

	## A format 4 subtable. Each segment maps by `delta`, or, when `glyphs` is
	## not empty, through its own glyph array (one entry per character). The
	## required final 0xFFFF segment is added.
	cmap4 : List({ first : U64, last : U64, delta : U64, glyphs : List(U64) }) -> List(U8)
	cmap4 = |segments| {
		all = segments.append({ first: 0xFFFF, last: 0xFFFF, delta: 1, glyphs: [] })
		n = all.len()
		# Glyph arrays follow the range offsets; an offset counts from its own
		# position.
		var $offsets = []
		var $array = []
		for s in 0..<n {
			seg = all.get(s) ?? { first: 0, last: 0, delta: 0, glyphs: [] }
			if seg.glyphs.is_empty() {
				$offsets = $offsets.append(0)
			} else {
				$offsets = $offsets.append(2 * (n - s) + $array.len())
				$array = $array.concat(seg.glyphs.join_map(FontTest.u16))
			}
		}
		body = FontTest.u16(2 * n)
			.concat(FontTest.u16(0))
			.concat(FontTest.u16(0))
			.concat(FontTest.u16(0))
			.concat(all.join_map(|seg| FontTest.u16(seg.last)))
			.concat(FontTest.u16(0))
			.concat(all.join_map(|seg| FontTest.u16(seg.first)))
			.concat(all.join_map(|seg| FontTest.u16(seg.delta)))
			.concat($offsets.join_map(FontTest.u16))
			.concat($array)
		FontTest.u16(4).concat(FontTest.u16(body.len() + 6)).concat(FontTest.u16(0)).concat(body)
	}

	## A format 12 subtable of groups (first, last, first glyph).
	cmap12 : List({ first : U64, last : U64, glyph : U64 }) -> List(U8)
	cmap12 = |groups|
		FontTest.u16(12)
			.concat(FontTest.u16(0))
			.concat(FontTest.u32(16 + 12 * groups.len()))
			.concat(FontTest.u32(0))
			.concat(FontTest.u32(groups.len()))
			.concat(groups.join_map(|g| FontTest.u32(g.first).concat(FontTest.u32(g.last)).concat(FontTest.u32(g.glyph))))

	## The tables of a minimal valid font with four glyphs: glyph 0 (the
	## missing glyph), 1 for `A`, 2 for `B`, 3 for `C`, advances 500, 600,
	## 700 and 800, 1000 units per em. Tests replace or add tables.
	basic : List({ tag : Str, data : List(U8) })
	basic = [
		{ tag: "head", data: FontTest.head(1000, False) },
		{ tag: "hhea", data: FontTest.hhea(800, -200, 4) },
		{ tag: "maxp", data: FontTest.maxp(4) },
		{ tag: "hmtx", data: FontTest.hmtx([500, 600, 700, 800]) },
		{ tag: "cmap", data: FontTest.cmap([{ system: 3, encoding: 1, subtable: FontTest.cmap4([{ first: 'A', last: 'C', delta: 65536 - 64, glyphs: [] }]) }]) },
	]

	## `basic` with a table added or replaced.
	replace : List({ tag : Str, data : List(U8) }), Str, List(U8) -> List({ tag : Str, data : List(U8) })
	replace = |tables, tag, data|
		tables.drop_if(|t| t.tag == tag).append({ tag, data })

	## `basic` without a table.
	without : List({ tag : Str, data : List(U8) }), Str -> List({ tag : Str, data : List(U8) })
	without = |tables, tag| tables.drop_if(|t| t.tag == tag)

	# ------------------------------------------------------------ layout tables

	## A coverage table of format 1 (a sorted glyph list).
	coverage1 : List(U64) -> List(U8)
	coverage1 = |glyphs| FontTest.pack([U16(1), U16(glyphs.len())].concat(glyphs.map(|g| U16(g))))

	## A coverage table of format 2 (ranges first, last, first coverage index).
	coverage2 : List({ first : U64, last : U64, index : U64 }) -> List(U8)
	coverage2 = |ranges| FontTest.pack([U16(2), U16(ranges.len())].concat(ranges.join_map(|r| [U16(r.first), U16(r.last), U16(r.index)])))

	## A class definition of format 1: classes of consecutive glyphs from
	## `start`.
	classes1 : U64, List(U64) -> List(U8)
	classes1 = |start, classes| FontTest.pack([U16(1), U16(start), U16(classes.len())].concat(classes.map(|c| U16(c))))

	## A class definition of format 2: ranges first, last, class.
	classes2 : List({ first : U64, last : U64, class : U64 }) -> List(U8)
	classes2 = |ranges| FontTest.pack([U16(2), U16(ranges.len())].concat(ranges.join_map(|r| [U16(r.first), U16(r.last), U16(r.class)])))

	## A `GSUB` or `GPOS` table: one script (`latn` or `DFLT`) whose default
	## language lists every feature, the features (tag and lookup indices),
	## and the lookups (type and subtables).
	layout : Str, List({ tag : Str, lookups : List(U64) }), List({ kind : U64, subtables : List(List(U8)) }) -> List(U8)
	layout = |script, features, lookups| FontTest.layout_listing(script, FontTest.counting(features.len()), 0xFFFF, features, lookups)

	## `layout` whose default language lists only some features (by index),
	## plus a required feature (0xFFFF for none).
	layout_listing : Str, List(U64), U64, List({ tag : Str, lookups : List(U64) }), List({ kind : U64, subtables : List(List(U8)) }) -> List(U8)
	layout_listing = |script, listed, required, features, lookups| {
		language = FontTest.pack([U16(0), U16(required), U16(listed.len())].concat(listed.map(|i| U16(i))))
		scripts = FontTest.pack([U16(1), Tag(script), Ref(FontTest.pack([Ref(language), U16(0)]))])
		feature_list = FontTest.pack(
			[U16(features.len())].concat(features.join_map(|f| [Tag(f.tag), Ref(FontTest.pack([U16(0), U16(f.lookups.len())].concat(f.lookups.map(|l| U16(l)))))])),
		)
		lookup_list = FontTest.pack(
			[U16(lookups.len())].concat(lookups.map(|l| Ref(FontTest.pack([U16(l.kind), U16(0), U16(l.subtables.len())].concat(l.subtables.map(|s| Ref(s))))))),
		)
		FontTest.pack([U32(0x00010000), Ref(scripts), Ref(feature_list), Ref(lookup_list)])
	}

	## An extension subtable (format 1) wrapping a subtable of `kind`.
	extension : U64, List(U8) -> List(U8)
	extension = |kind, subtable| FontTest.pack([U16(1), U16(kind), Ref32(subtable)])

	## A pair adjustment subtable of format 1: each covered first glyph (in
	## increasing order) with its pairs, a second glyph and the fields of both
	## value records.
	pair1 : U64, U64, List({ glyph : U64, pairs : List({ second : U64, values : List(I64) }) }) -> List(U8)
	pair1 = |format1, format2, sets| {
		set_tables = sets.map(|s| Ref(FontTest.pack([U16(s.pairs.len())].concat(s.pairs.join_map(|p| [U16(p.second)].concat(p.values.map(|v| I16(v))))))))
		FontTest.pack([U16(1), Ref(FontTest.coverage1(sets.map(|s| s.glyph))), U16(format1), U16(format2), U16(sets.len())].concat(set_tables))
	}

	## A pair adjustment subtable of format 2: coverage, the two class
	## definitions, the class counts and the fields of every cell, row by row.
	pair2 : U64, U64, List(U8), List(U8), List(U8), U64, U64, List(I64) -> List(U8)
	pair2 = |format1, format2, coverage, class1, class2, height, width, values|
		FontTest.pack([U16(2), Ref(coverage), U16(format1), U16(format2), Ref(class1), Ref(class2), U16(height), U16(width)].concat(values.map(|v| I16(v))))

	## A TrueType `kern` table of format 0 subtables, each with its coverage
	## field (1 for horizontal kerning) and pairs in the order given.
	kern : List({ coverage : U64, pairs : List({ left : U64, right : U64, value : I64 }) }) -> List(U8)
	kern = |subtables| {
		body = subtables.join_map(
			|s| {
				n = s.pairs.len()
				FontTest.pack([U16(0), U16(14 + 6 * n), U16(s.coverage), U16(n), U16(0), U16(0), U16(0)].concat(s.pairs.join_map(|p| [U16(p.left), U16(p.right), I16(p.value)])))
			},
		)
		FontTest.u16(0).concat(FontTest.u16(subtables.len())).concat(body)
	}

	## A TrueType glyph header with the given horizontal extent.
	outline : I64, I64 -> List(U8)
	outline = |left, right| FontTest.pack([I16(1), I16(left), I16(0), I16(right), I16(100)])

	## `loca` and `glyf` tables for glyphs given as their bytes (empty for a
	## glyph without an outline), with short or long offsets.
	outlines : List(List(U8)), Bool -> { loca : List(U8), glyf : List(U8) }
	outlines = |glyphs, long| {
		var $loca = []
		var $at = 0
		for g in glyphs {
			$loca = $loca.concat(if (long) FontTest.u32($at) else FontTest.u16($at // 2))
			$at = $at + g.len()
		}
		$loca = $loca.concat(if (long) FontTest.u32($at) else FontTest.u16($at // 2))
		{ loca: $loca, glyf: glyphs.join_map(|g| g) }
	}

	## Bytes with some replaced from `at`.
	patch : List(U8), U64, List(U8) -> List(U8)
	patch = |bytes, at, replacement|
		bytes.take_first(at).concat(replacement).concat(bytes.drop_first(at + replacement.len()))

	# Single substitution, format 1: add `delta` to covered glyphs.
	single1 : List(U64), I64 -> List(U8)
	single1 = |glyphs, delta| FontTest.pack([U16(1), Ref(FontTest.coverage1(glyphs)), I16(delta)])

	# Single substitution, format 2: covered glyphs replaced in order.
	single2 : List(U64), List(U64) -> List(U8)
	single2 = |glyphs, replacements| FontTest.pack([U16(2), Ref(FontTest.coverage1(glyphs)), U16(replacements.len())].concat(replacements.map(|g| U16(g))))

	# Multiple substitution: each covered glyph by a sequence.
	multiple : List(U64), List(List(U64)) -> List(U8)
	multiple = |glyphs, sequences| FontTest.pack([U16(1), Ref(FontTest.coverage1(glyphs)), U16(sequences.len())].concat(sequences.map(|seq| Ref(FontTest.pack([U16(seq.len())].concat(seq.map(|g| U16(g))))))))

	# Ligature substitution: per covered first glyph, its ligature_table (glyph and
	# the components after the first).
	ligature : List(U64), List(List({ glyph : U64, rest : List(U64) })) -> List(U8)
	ligature = |glyphs, sets| {
		set_tables = sets.map(|set| Ref(FontTest.pack([U16(set.len())].concat(set.map(|lig| Ref(FontTest.pack([U16(lig.glyph), U16(lig.rest.len() + 1)].concat(lig.rest.map(|g| U16(g))))))))))
		FontTest.pack([U16(1), Ref(FontTest.coverage1(glyphs)), U16(sets.len())].concat(set_tables))
	}

	records : List({ at : U64, lookup : U64 }) -> List(Field)
	records = |list| list.join_map(|r| [U16(r.at), U16(r.lookup)])

	# A context rule of format 1 or 2: input after the first glyph (glyphs or
	# classes) and its lookup records.
	rule : List(U64), List({ at : U64, lookup : U64 }) -> List(U8)
	rule = |input, calls| FontTest.pack([U16(input.len() + 1), U16(calls.len())].concat(input.map(|g| U16(g))).concat(FontTest.records(calls)))

	# A chained rule of format 1 or 2.
	chain_rule : List(U64), List(U64), List(U64), List({ at : U64, lookup : U64 }) -> List(U8)
	chain_rule = |back, input, ahead, calls|
		FontTest.pack(
			[U16(back.len())]
				.concat(back.map(|g| U16(g)))
				.concat([U16(input.len() + 1)])
				.concat(input.map(|g| U16(g)))
				.concat([U16(ahead.len())])
				.concat(ahead.map(|g| U16(g)))
				.concat([U16(calls.len())])
				.concat(FontTest.records(calls)),
		)

	# A rule set (offsets to rules), or a null offset for a missing set.
	rule_set : List(List(U8)) -> Field
	rule_set = |rules| if (rules.is_empty()) U16(0) else Ref(FontTest.pack([U16(rules.len())].concat(rules.map(|r| Ref(r)))))

	# Context substitution, format 1: rule sets per covered first glyph.
	context1 : List(U64), List(List(List(U8))) -> List(U8)
	context1 = |glyphs, sets| FontTest.pack([U16(1), Ref(FontTest.coverage1(glyphs)), U16(sets.len())].concat(sets.map(FontTest.rule_set)))

	# Context substitution, format 2: rule sets per class of the first glyph.
	context2 : List(U64), List(U8), List(List(List(U8))) -> List(U8)
	context2 = |glyphs, classes, sets| FontTest.pack([U16(2), Ref(FontTest.coverage1(glyphs)), Ref(classes), U16(sets.len())].concat(sets.map(FontTest.rule_set)))

	# Context substitution, format 3: a coverage per input position.
	context3 : List(List(U64)), List({ at : U64, lookup : U64 }) -> List(U8)
	context3 = |input, calls| FontTest.pack([U16(3), U16(input.len()), U16(calls.len())].concat(input.map(|glyphs| Ref(FontTest.coverage1(glyphs)))).concat(FontTest.records(calls)))

	chain1 : List(U64), List(List(List(U8))) -> List(U8)
	chain1 = |glyphs, sets| FontTest.pack([U16(1), Ref(FontTest.coverage1(glyphs)), U16(sets.len())].concat(sets.map(FontTest.rule_set)))

	chain2 : List(U64), List(U8), List(U8), List(U8), List(List(List(U8))) -> List(U8)
	chain2 = |glyphs, back, input, ahead, sets| FontTest.pack([U16(2), Ref(FontTest.coverage1(glyphs)), Ref(back), Ref(input), Ref(ahead), U16(sets.len())].concat(sets.map(FontTest.rule_set)))

	chain3 : List(List(U64)), List(List(U64)), List(List(U64)), List({ at : U64, lookup : U64 }) -> List(U8)
	chain3 = |back, input, ahead, calls| {
		coverages = |list| [U16(list.len())].concat(list.map(|glyphs| Ref(FontTest.coverage1(glyphs))))
		FontTest.pack([U16(3)].concat(coverages(back)).concat(coverages(input)).concat(coverages(ahead)).concat([U16(calls.len())]).concat(FontTest.records(calls)))
	}

	# ------------------------------------------------------------ whole fonts

	## A `GSUB` table with a lookup of every kind `FontShape` reads: lookup
	## 0 (feature `calt`) is chained context of formats 3 and 2, calling
	## single substitutions (1), an extension holding a ligature (2), context
	## of formats 1 and 2 (3), which call a multiple substitution (4).
	every_lookup : List(U8)
	every_lookup = FontTest.layout(
		"latn",
		[{ tag: "calt", lookups: [0] }],
		[
			{ kind: 6, subtables: [FontTest.chain3([[7]], [[1], [2]], [[3]], [{ at: 0, lookup: 1 }, { at: 1, lookup: 2 }]), FontTest.chain2([1], FontTest.classes1(7, [1]), FontTest.classes2([{ first: 1, last: 2, class: 1 }]), FontTest.classes1(3, [1]), [[], [FontTest.chain_rule([1], [1], [1], [{ at: 0, lookup: 3 }])]])] },
			{ kind: 1, subtables: [FontTest.single1([1, 2], 10), FontTest.single2([3], [30])] },
			{ kind: 7, subtables: [FontTest.extension(4, FontTest.ligature([1], [[{ glyph: 9, rest: [2] }]]))] },
			{ kind: 5, subtables: [FontTest.context1([1], [[FontTest.rule([2], [{ at: 0, lookup: 4 }])]]), FontTest.context2([1], FontTest.classes1(1, [1]), [[], [FontTest.rule([0], [{ at: 1, lookup: 4 }])]])] },
			{ kind: 2, subtables: [FontTest.multiple([1, 2], [[4, 5], []])] },
		],
	)

	## A `GPOS` table whose `kern` feature has pair adjustments of format 1,
	## format 2, and both behind extensions.
	every_pair : List(U8)
	every_pair = {
		pairs = FontTest.pair1(4, 0, [{ glyph: 1, pairs: [{ second: 2, values: [-50] }, { second: 3, values: [-30] }] }, { glyph: 2, pairs: [{ second: 1, values: [20] }] }])
		classes = FontTest.pair2(5, 4, FontTest.coverage2([{ first: 1, last: 3, index: 0 }]), FontTest.classes1(1, [0, 1, 1]), FontTest.classes2([{ first: 2, last: 3, class: 1 }]), 2, 2, [0, 0, 0, 1, -11, 2, -22, 3, -33, 4, 0, 5])
		FontTest.layout(
			"DFLT",
			[{ tag: "kern", lookups: [0, 1] }, { tag: "mark", lookups: [1] }],
			[{ kind: 2, subtables: [pairs, classes] }, { kind: 9, subtables: [FontTest.extension(2, classes), FontTest.extension(2, pairs)] }],
		)
	}

	## A complete font with 40 glyphs and every table `Font` reads: `A` to
	## `Z` are glyphs 1 to 26 (format 4 and format 12 character maps), with
	## outlines, typographic metrics, `GSUB` (`every_lookup`), `GPOS`
	## (`every_pair`) and a `kern` table that `GPOS` overrides.
	sample : List(U8)
	sample = {
		glyphs = FontTest.counting(40).map(|g| if (g % 3 == 0) [] else FontTest.outline(g.to_i64_wrap() - 5, 10 * g.to_i64_wrap()))
		boxes = FontTest.outlines(glyphs, True)
		characters = FontTest.cmap([
			{ system: 0, encoding: 3, subtable: FontTest.cmap4([{ first: 'A', last: 'Z', delta: 65536 - 64, glyphs: [] }, { first: 'a', last: 'c', delta: 0, glyphs: [27, 0, 29] }]) },
			{ system: 3, encoding: 10, subtable: FontTest.cmap12([{ first: 'A', last: 'Z', glyph: 1 }, { first: 0x1F600, last: 0x1F600, glyph: 30 }]) },
		])
		FontTest.file([
			{ tag: "head", data: FontTest.head(2048, True) },
			{ tag: "hhea", data: FontTest.hhea(1900, -500, 4) },
			{ tag: "maxp", data: FontTest.maxp(40) },
			{ tag: "OS/2", data: FontTest.os2({ use_typo: True, typo_ascent: 1800, typo_descent: -400, win_ascent: 2000, win_descent: 600 }) },
			{ tag: "hmtx", data: FontTest.hmtx([1000, 1100, 1200, 1300]).concat(List.repeat(0, 72)) },
			{ tag: "cmap", data: characters },
			{ tag: "loca", data: boxes.loca },
			{ tag: "glyf", data: boxes.glyf },
			{ tag: "GSUB", data: FontTest.every_lookup },
			{ tag: "GPOS", data: FontTest.every_pair },
			{ tag: "kern", data: FontTest.kern([{ coverage: 1, pairs: [{ left: 1, right: 2, value: -7 }] }]) },
		])
	}

	## `bytes` with patches applied: each group of four bytes of `patches`
	## names a position (three bytes, wrapped to the length) and its new
	## value.
	mutate : List(U8), List(U8) -> List(U8)
	mutate = |bytes, patches| {
		var $out = bytes
		var $k = 0
		while $k + 4 <= patches.len() and !$out.is_empty() {
			at = (patches.get($k) ?? 0).to_u64() * 65536 + (patches.get($k + 1) ?? 0).to_u64() * 256 + (patches.get($k + 2) ?? 0).to_u64()
			# The position is wrapped to the length, so it is in bounds.
			$out = $out.set(at % $out.len(), patches.get($k + 3) ?? 0) ?? []
			$k = $k + 4
		}
		$out
	}

	## The font file a fuzz input stands for. Inputs that start with a font
	## signature are the file itself, so a corpus can hold real fonts. Any
	## other input is a recipe: its first byte picks a base (`inter`, the
	## bytes of Inter; `sample`; `sample` cut short at a length from the next
	## two bytes; or no base, the rest of the input as it is) and the rest
	## patches it (see `mutate`), so most inputs are nearly valid fonts.
	fuzz_font : List(U8), List(U8) -> List(U8)
	fuzz_font = |bytes, inter| {
		signature = bytes.take_first(4)
		if signature == [0, 1, 0, 0] or signature == "true".to_utf8() or signature == "OTTO".to_utf8() or signature == "ttcf".to_utf8() {
			bytes
		} else {
			patches = bytes.drop_first(1)
			match (bytes.first() ?? 0) % 4 {
				0 => FontTest.mutate(inter, patches)
				1 => FontTest.mutate(FontTest.sample, patches)
				2 => {
					cut = ((patches.get(0) ?? 0).to_u64() * 256 + (patches.get(1) ?? 0).to_u64()) % (FontTest.sample.len() + 1)
					FontTest.mutate(FontTest.sample.take_first(cut), patches.drop_first(2))
				}
				_ => patches
			}
		}
	}

	## A font whose tables grow with `copies`: for each of up to 16 choice
	## bytes, `copies` items of the kind the byte picks (character map
	## entries, legacy kerning pairs, `GPOS` pair sets, `GPOS` class ranges,
	## ligatures, chained rules). The first byte also picks format 4 or 12
	## for the character map and whether `GPOS` replaces `kern`.
	scaled : List(U8), U64 -> List(U8)
	scaled = |choices, copies| {
		picks = choices.take_first(16)
		var $kinds = []
		for _ in 0..<copies {
			for b in picks {
				$kinds = $kinds.append(b.to_u64() % 6)
			}
		}
		items = $kinds.map_with_index(|kind, j| { kind, base: 8 + 4 * j })
		of_kind = |k| items.keep_if(|item| item.kind == k).map(|item| item.base)
		glyph_count = 16 + 4 * items.len()
		first = (picks.first() ?? 0).to_u64()
		mapped = of_kind(0)
		subtable = if first % 2 == 0 {
			FontTest.cmap4(mapped.map(|base| { first: 0x400 + 2 * base, last: 0x401 + 2 * base, delta: (65536 + base - (0x400 + 2 * base)) % 65536, glyphs: [] }))
		} else {
			FontTest.cmap12(mapped.map(|base| { first: 0x10000 + 2 * base, last: 0x10001 + 2 * base, glyph: base }))
		}
		legacy = FontTest.kern([{ coverage: 1, pairs: of_kind(1).map(|base| { left: base, right: base + 1, value: -3 }) }])
		pair_sets = of_kind(2).map(|base| { glyph: base, pairs: [{ second: base + 1, values: [-1] }, { second: base + 2, values: [-2] }] })
		class_ranges = of_kind(3)
		classes = FontTest.pair2(
			4,
			0,
			FontTest.coverage2(class_ranges.map_with_index(|base, i| { first: base, last: base + 1, index: 2 * i })),
			FontTest.classes2(class_ranges.map(|base| { first: base, last: base + 1, class: 1 })),
			FontTest.classes2(class_ranges.map(|base| { first: base + 2, last: base + 3, class: 1 })),
			2,
			2,
			[0, 0, 0, -5],
		)
		gpos = FontTest.layout("DFLT", [{ tag: "kern", lookups: [0] }], [{ kind: 2, subtables: [FontTest.pair1(4, 0, pair_sets), classes] }])
		ligatures = of_kind(4)
		chained = of_kind(5)
		gsub = FontTest.layout(
			"latn",
			[{ tag: "liga", lookups: [0, 1] }],
			[
				{ kind: 4, subtables: [FontTest.ligature(ligatures, ligatures.map(|base| [{ glyph: base + 3, rest: [base + 1, base + 2] }]))] },
				{ kind: 6, subtables: [FontTest.chain1(chained, chained.map(|base| [FontTest.chain_rule([base + 3], [base + 1], [base + 2], [{ at: 0, lookup: 2 }])]))] },
				{ kind: 1, subtables: [FontTest.single1(chained, 1)] },
			],
		)
		tables = [
			{ tag: "head", data: FontTest.head(1000, False) },
			{ tag: "hhea", data: FontTest.hhea(800, -200, glyph_count) },
			{ tag: "maxp", data: FontTest.maxp(glyph_count) },
			{ tag: "hmtx", data: FontTest.hmtx(FontTest.counting(glyph_count).map(|g| 100 + g % 400)) },
			{ tag: "cmap", data: FontTest.cmap([{ system: 3, encoding: if (first % 2 == 0) 1 else 10, subtable }]) },
			{ tag: "GSUB", data: gsub },
		]
		FontTest.file(if (first % 4 < 2) tables.append({ tag: "GPOS", data: gpos }) else tables.append({ tag: "kern", data: legacy }))
	}

	counting : U64 -> List(U64)
	counting = |n| {
		var $out = []
		for i in 0..<n {
			$out = $out.append(i)
		}
		$out
	}
}

expect FontTest.u16(0x1234) == [0x12, 0x34]
expect FontTest.i16(-2) == [0xFF, 0xFE]
expect FontTest.pack([U16(1), Ref([9, 9]), U16(2), Ref([7])]) == [0, 1, 0, 8, 0, 2, 0, 10, 9, 9, 7]
expect FontTest.file([{ tag: "abc", data: [1] }]).len() == 12 + 16 + 4
