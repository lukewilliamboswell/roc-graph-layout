import Sfnt
import Bytes

## The PostScript table (`post`): the underline's position and thickness,
## the italic angle, whether the font is monospaced, and the glyphs'
## PostScript names.
##
## Internal. Reading checks the table once and reports every independent
## problem; after a successful read every query here is total. Versions 1.0,
## 2.0, 2.5 and 3.0 are read; any other version is a problem.
##
## Glyph names by version:
##
## - 1.0: the first 258 glyphs carry the standard Macintosh names, in their
##   standard order.
## - 2.0: each glyph has an index; below 258 it selects a standard name, from
##   258 a name stored in the table as a length byte and that many bytes.
##   Reading finds where each stored name a glyph refers to starts, in one
##   list of offsets into the table bytes; the names are neither copied nor
##   decoded until a query asks for one.
## - 2.5 (deprecated, but read): each glyph has a signed byte added to its
##   index to select a standard name.
## - 3.0: no names.
##
## Only glyphs below the font's glyph count (from `maxp`) have names. A
## version 2.0 or 2.5 table that lists fewer glyphs leaves the rest without
## names, and entries past the font's glyph count are never read; neither is
## a problem, because no query can observe them. A glyph whose stored name
## is empty has no name.
##
## The format gives stored names no encoding; they are meant to be ASCII. A
## name is decoded as ISO 8859-1 (each byte is the character of that
## number), as fontTools does, so every name is a valid `Str` and ASCII names
## are returned unchanged.
##
## Problems name the table and the byte offset in the file: the version, a
## glyph count whose index array does not fit, a version 2.5 offset that
## selects no standard name, or the first stored name that runs past the end
## of the table while a glyph still refers to it or a later one.
TablePost := {
	# Fixed 16.16 degrees, counter-clockwise from vertical.
	italic_angle : I32,
	underline_position : I16,
	underline_thickness : I16,
	fixed_pitch : Bool,
	names : Names,
}.{

	# Where glyph names come from. `count` is the number of glyphs that have
	# a name entry and lie below the font's glyph count. `Indexed` holds the
	# table bytes (indices from byte 34) and where each stored name starts
	# (its length byte); `Offsets` holds the table bytes (offsets from byte
	# 34).
	Names : [NoNames, Standard(U64), Indexed({ bytes : List(U8), count : U64, starts : List(U32) }), Offsets({ bytes : List(U8), count : U64 })]

	## A table with zero metrics and no glyph names.
	none : TablePost
	none = { italic_angle: 0, underline_position: 0, underline_thickness: 0, fixed_pitch: Bool.False, names: NoNames }

	# ------------------------------------------------------------ queries

	## The underline's position (the top of the line, negative below the
	## baseline) and thickness, in font units.
	underline : TablePost -> { position : I32, thickness : I32 }
	underline = |post| { position: post.underline_position.to_i32(), thickness: post.underline_thickness.to_i32() }

	## The italic angle in degrees counter-clockwise from vertical, as the
	## table stores it: a fixed-point number with 16 fractional bits
	## (`-12.5` degrees is `-819200`).
	italic_angle : TablePost -> I32
	italic_angle = |post| post.italic_angle

	## Whether the font says its glyphs all have the same advance.
	fixed_pitch : TablePost -> Bool
	fixed_pitch = |post| post.fixed_pitch

	## A glyph's PostScript name, if the table gives it one.
	glyph_name : TablePost, U32 -> Try(Str, [Missing])
	glyph_name = |post, glyph| {
		g = glyph.to_u64()
		match post.names {
			NoNames => Err(Missing)
			Standard(count) => if (g < count) Ok(TablePost.standard_name(g)) else Err(Missing)
			Offsets({ bytes, count }) =>
				if g < count {
					# Reading checked that every glyph below `count` selects a
					# standard name.
					offset = Bytes.u8(bytes, 34 + g).to_i64_wrap()
					shift = if (offset >= 128) offset - 256 else offset
					Ok(TablePost.standard_name((g.to_i64_wrap() + shift).to_u64_wrap()))
				} else {
					Err(Missing)
				}
			Indexed({ bytes, count, starts }) =>
				if g >= count {
					Err(Missing)
				} else {
					index = Bytes.u16(bytes, 34 + 2 * g)
					if index < 258 {
						Ok(TablePost.standard_name(index))
					} else {
						# Reading found a start for every stored name a glyph
						# below `count` refers to, and checked that the name
						# lies inside the table.
						start = (starts.get(index - 258) ?? 0).to_u64()
						length = Bytes.u8(bytes, start)
						if (length == 0) Err(Missing) else Ok(TablePost.latin1(bytes, start + 1, length))
					}
				}
		}
	}

	# A standard Macintosh glyph name. Callers pass indices below 258, so
	# the fallback is unreachable.
	standard_name : U64 -> Str
	standard_name = |index| TablePost.standard.get(index) ?? ""

	# Decode ISO 8859-1. Every byte is a character, so the fallback is
	# unreachable.
	latin1 : List(U8), U64, U64 -> Str
	latin1 = |data, start, length| {
		var $out = List.with_capacity(2 * length)
		for i in 0..<length {
			b = Bytes.u8(data, start + i)
			$out =
				if b < 0x80 {
					$out.append(b.to_u8_wrap())
				} else {
					$out.append(b.shr_zf_wrap(6).bitwise_or(0xC0).to_u8_wrap()).append(b.bitwise_and(0x3F).bitwise_or(0x80).to_u8_wrap())
				}
		}
		Str.from_utf8($out) ?? ""
	}

	# ------------------------------------------------------------ reading

	## The PostScript table of a font file with `glyph_count` glyphs, or
	## `Absent` when the font has none. The table is optional.
	from_tables : List(U8), List(Sfnt.Table), U64 -> Try([Present(TablePost), Absent], List([BadTable({ table : Str, offset : U32 })]))
	from_tables = |bytes, tables, glyph_count| {
		tag = Sfnt.tag_of("post")
		match tables.find_first(|t| t.tag == tag) {
			Err(_) => Ok(Absent)
			Ok(t) =>
				if Bytes.fits(t.offset, t.length, bytes.len()) {
					match TablePost.read(bytes.sublist({ start: t.offset, len: t.length }), t.offset, glyph_count) {
						Ok(post) => Ok(Present(post))
						Err(problems) => Err(problems)
					}
				} else {
					Err([TablePost.bad(t.offset, 0)])
				}
		}
	}

	## Check a `post` table's bytes for a font with `glyph_count` glyphs.
	## `base` is the table's offset in the file, used only to place problems.
	read : List(U8), U64, U64 -> Try(TablePost, List([BadTable({ table : Str, offset : U32 })]))
	read = |data, base, glyph_count| {
		size = data.len()
		version = Bytes.u32(data, 0)
		if size < 32 {
			return Err([TablePost.bad(base, 0)])
		}
		header = |names| {
			italic_angle: Bytes.u32(data, 4).to_u32_wrap().to_i32_wrap(),
			underline_position: Bytes.i16(data, 8).to_i16_wrap(),
			underline_thickness: Bytes.i16(data, 10).to_i16_wrap(),
			fixed_pitch: Bytes.u32(data, 12) != 0,
			names,
		}
		if version == 0x00010000 {
			Ok(header(Standard(if (glyph_count < 258) glyph_count else 258)))
		} else if version == 0x00030000 {
			Ok(header(NoNames))
		} else if version == 0x00020000 {
			match TablePost.read_indexed(data, base, glyph_count) {
				Ok(names) => Ok(header(names))
				Err(problems) => Err(problems)
			}
		} else if version == 0x00025000 {
			match TablePost.read_offsets(data, base, glyph_count) {
				Ok(names) => Ok(header(names))
				Err(problems) => Err(problems)
			}
		} else {
			Err([TablePost.bad(base, 0)])
		}
	}

	# Version 2.0: the glyph name indices and the stored names they use.
	read_indexed : List(U8), U64, U64 -> Try(Names, List([BadTable({ table : Str, offset : U32 })]))
	read_indexed = |data, base, glyph_count| {
		size = data.len()
		listed = Bytes.u16(data, 32)
		if !Bytes.fits(34, 2 * listed, size) {
			return Err([TablePost.bad(base, 32)])
		}
		count = if (listed < glyph_count) listed else glyph_count
		var $highest = 0
		for g in 0..<count {
			index = Bytes.u16(data, 34 + 2 * g)
			if index > $highest {
				$highest = index
			}
		}
		# Stored names the glyphs refer to: 0 up to `needed`.
		needed = if ($highest >= 258) $highest - 257 else 0
		first = 34 + 2 * listed
		# Each stored name takes at least its length byte, so a count that
		# cannot fit is refused before anything is allocated for it.
		if needed > size - first {
			return Err([TablePost.bad(base, size)])
		}
		var $starts = List.with_capacity(needed)
		var $at = first
		var $short = Bool.False
		for _k in 0..<needed {
			if !$short {
				if $at < size and Bytes.fits($at + 1, Bytes.u8(data, $at), size) {
					$starts = $starts.append($at.to_u32_wrap())
					$at = $at + 1 + Bytes.u8(data, $at)
				} else {
					$short = Bool.True
				}
			}
		}
		if $short {
			Err([TablePost.bad(base, $at)])
		} else {
			Ok(Indexed({ bytes: data, count, starts: $starts }))
		}
	}

	# Version 2.5: per glyph, a signed offset from its index to a standard
	# name.
	read_offsets : List(U8), U64, U64 -> Try(Names, List([BadTable({ table : Str, offset : U32 })]))
	read_offsets = |data, base, glyph_count| {
		listed = Bytes.u16(data, 32)
		if !Bytes.fits(34, listed, data.len()) {
			return Err([TablePost.bad(base, 32)])
		}
		count = if (listed < glyph_count) listed else glyph_count
		var $problems = []
		for g in 0..<count {
			offset = Bytes.u8(data, 34 + g)
			# The selected index, g + offset with offset signed, must be in
			# 0 to 257.
			selects = if (offset >= 128) g + offset >= 256 and g + offset - 256 < 258 else g + offset < 258
			if !selects {
				$problems = $problems.append(TablePost.bad(base, 34 + g))
			}
		}
		if $problems.is_empty() {
			Ok(Offsets({ bytes: data, count }))
		} else {
			Err($problems)
		}
	}

	# A problem at byte `at` of a table at `base` in the file. Fonts larger
	# than 4 GiB are refused before tables are read, so the sum fits.
	bad : U64, U64 -> [BadTable({ table : Str, offset : U32 })]
	bad = |base, at| BadTable({ table: "post", offset: (base + at).to_u32_wrap() })

	# The 258 standard Macintosh glyph names, in their standard order.
	standard : List(Str)
	standard = [".notdef", ".null", "nonmarkingreturn", "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand", "quotesingle", "parenleft", "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash", "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "bracketleft", "backslash", "bracketright", "asciicircum", "underscore", "grave", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde", "Adieresis", "Aring", "Ccedilla", "Eacute", "Ntilde", "Odieresis", "Udieresis", "aacute", "agrave", "acircumflex", "adieresis", "atilde", "aring", "ccedilla", "eacute", "egrave", "ecircumflex", "edieresis", "iacute", "igrave", "icircumflex", "idieresis", "ntilde", "oacute", "ograve", "ocircumflex", "odieresis", "otilde", "uacute", "ugrave", "ucircumflex", "udieresis", "dagger", "degree", "cent", "sterling", "section", "bullet", "paragraph", "germandbls", "registered", "copyright", "trademark", "acute", "dieresis", "notequal", "AE", "Oslash", "infinity", "plusminus", "lessequal", "greaterequal", "yen", "mu", "partialdiff", "summation", "product", "pi", "integral", "ordfeminine", "ordmasculine", "Omega", "ae", "oslash", "questiondown", "exclamdown", "logicalnot", "radical", "florin", "approxequal", "Delta", "guillemotleft", "guillemotright", "ellipsis", "nonbreakingspace", "Agrave", "Atilde", "Otilde", "OE", "oe", "endash", "emdash", "quotedblleft", "quotedblright", "quoteleft", "quoteright", "divide", "lozenge", "ydieresis", "Ydieresis", "fraction", "currency", "guilsinglleft", "guilsinglright", "fi", "fl", "daggerdbl", "periodcentered", "quotesinglbase", "quotedblbase", "perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis", "Egrave", "Iacute", "Icircumflex", "Idieresis", "Igrave", "Oacute", "Ocircumflex", "apple", "Ograve", "Uacute", "Ucircumflex", "Ugrave", "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent", "ring", "cedilla", "hungarumlaut", "ogonek", "caron", "Lslash", "lslash", "Scaron", "scaron", "Zcaron", "zcaron", "brokenbar", "Eth", "eth", "Yacute", "yacute", "Thorn", "thorn", "minus", "multiply", "onesuperior", "twosuperior", "threesuperior", "onehalf", "onequarter", "threequarters", "franc", "Gbreve", "gbreve", "Idotaccent", "Scedilla", "scedilla", "Cacute", "cacute", "Ccaron", "ccaron", "dcroat"]
}
