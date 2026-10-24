import ShaperLanguages

## From the plain-language names callers give (ISO 15924 script codes and
## BCP 47 language tags) to the OpenType script and language system tags a
## font's layout tables use, as HarfBuzz maps them (`hb-ot-tag.cc`,
## `hb-common.cc`), and each script's natural direction.
##
## Internal. Tags are big-endian four-byte numbers. Not mapped (HarfBuzz's
## `hb_ot_tags_from_complex_language`): language tags whose meaning
## depends on a region or variant subtag, such as `zh-HK` or `ro-MD`; their
## primary subtag maps as usual.
ShaperTags :: {}.{

	tag_of : Str -> U64
	tag_of = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u64())

	## Up to four bytes as a tag, padded with spaces (HarfBuzz's
	## `hb_tag_from_string`).
	tag_from_bytes : List(U8) -> U64
	tag_from_bytes = |bytes| {
		var $t = 0
		for k in 0..<4 {
			$t = $t * 256 + (bytes.get(k) ?? ' ').to_u64()
		}
		$t
	}

	## The ISO 15924 script a code names, normalised to one capital and
	## three small letters, with HarfBuzz's aliases; `Zzzz` (unknown) for
	## anything that does not look like a script code.
	script_of : Str -> U64
	script_of = |code| {
		raw = ShaperTags.tag_from_bytes(code.to_utf8())
		tag = raw.bitwise_and(0xDFDFDFDF).bitwise_or(0x00202020)
		aliases = [
			("Qaai", "Zinh"),
			("Qaac", "Copt"),
			("Aran", "Arab"),
			("Cyrs", "Cyrl"),
			("Geok", "Geor"),
			("Hans", "Hani"),
			("Hant", "Hani"),
			("Jamo", "Hang"),
			("Latf", "Latn"),
			("Latg", "Latn"),
			("Syre", "Syrc"),
			("Syrj", "Syrc"),
			("Syrn", "Syrc"),
		]
		match aliases.find_first(|(from, _)| ShaperTags.tag_of(from) == tag) {
			Ok((_, to)) => ShaperTags.tag_of(to)
			Err(_) =>
				if tag.bitwise_and(0xE0E0E0E0) == 0x40606060 {
					tag
				} else {
					ShaperTags.tag_of("Zzzz")
				}
		}
	}

	## The OpenType script tags to try for an ISO 15924 code, best first.
	## An empty code is Latin (`latn`), as a browser shapes Latin text whose
	## script it is not told.
	script_tags : Str -> List(U64)
	script_tags = |code|
		if code.is_empty() {
			[ShaperTags.tag_of("latn")]
		} else {
			script = ShaperTags.script_of(code)
			new_tags = [
				("Beng", "bng2"),
				("Deva", "dev2"),
				("Gujr", "gjr2"),
				("Guru", "gur2"),
				("Knda", "knd2"),
				("Mlym", "mlm2"),
				("Orya", "ory2"),
				("Taml", "tml2"),
				("Telu", "tel2"),
				("Mymr", "mym2"),
			]
			newer = match new_tags.find_first(|(iso, _)| ShaperTags.tag_of(iso) == script) {
				Ok(("Mymr", t)) => [ShaperTags.tag_of(t)]
				Ok((_, t)) => {
					two = ShaperTags.tag_of(t)
					# The `3` versions replace the last byte.
					[two.bitwise_and(0xFFFFFF00).bitwise_or('3'.to_u64()), two]
				}
				Err(_) => []
			}
			old_tags = [("Zmth", "math"), ("Hira", "kana"), ("Hrkt", "kana"), ("Laoo", "lao "), ("Yiii", "yi  "), ("Nkoo", "nko "), ("Vaii", "vai ")]
			old = match old_tags.find_first(|(iso, _)| ShaperTags.tag_of(iso) == script) {
				Ok((_, t)) => ShaperTags.tag_of(t)
				Err(_) => script.bitwise_or(0x20000000)
			}
			newer.append(old)
		}

	## A script's natural horizontal direction: `Rtl`, `Ltr`, or `Either`
	## for scripts written both ways and for an empty code.
	script_direction : Str -> [Ltr, Rtl, Either]
	script_direction = |code|
		if code.is_empty() {
			Either
		} else {
			script = ShaperTags.script_of(code)
			rtl = ["Arab", "Hebr", "Syrc", "Thaa", "Cprt", "Khar", "Phnx", "Nkoo", "Lydi", "Avst", "Armi", "Phli", "Prti", "Sarb", "Orkh", "Samr", "Mand", "Merc", "Mero", "Mani", "Mend", "Nbat", "Narb", "Palm", "Phlp", "Hatr", "Adlm", "Rohg", "Sogo", "Sogd", "Elym", "Chrs", "Yezi", "Ougr", "Gara", "Sidt"]
			either = ["Hung", "Ital", "Runr", "Tfng"]
			if rtl.any(|s| ShaperTags.tag_of(s) == script) {
				Rtl
			} else if either.any(|s| ShaperTags.tag_of(s) == script) {
				Either
			} else {
				Ltr
			}
		}

	## A language tag in lower case with `_` as `-`, as HarfBuzz keeps one.
	normalize : Str -> List(U8)
	normalize = |language| language.to_utf8().map(|b| if (b == '_') '-' else if (b >= 'A' and b <= 'Z') b + 32 else b)

	## The OpenType tags a language and script string give: language system
	## tags to try, best first, and script tags when the language carries a
	## private-use `-x-hbsc` subtag (HarfBuzz's way to give a raw script
	## tag; `-x-hbot` gives a raw language system tag).
	language_tags : Str -> { languages : List(U64), scripts : [Given(U64), NotGiven] }
	language_tags = |language| {
		lang = ShaperTags.normalize(language)
		if lang.is_empty() {
			return { languages: [], scripts: NotGiven }
		}
		# The private-use part, and where the plain part ends.
		split =
			if lang.starts_with(['x', '-']) {
				{ limit: 0, private: lang }
			} else {
				var $limit = lang.len()
				var $private = []
				var $s = 1
				while $s + 1 < lang.len() {
					if (lang.get($s - 1) ?? 0) == '-' and (lang.get($s + 1) ?? 0) == '-' {
						if (lang.get($s) ?? 0) == 'x' {
							$private = lang.drop_first($s)
							$limit = $limit.min($s - 1)
							$s = lang.len()
						} else {
							$limit = $limit.min($s - 1)
							$s = $s + 1
						}
					} else {
						$s = $s + 1
					}
				}
				{ limit: $limit, private: $private }
			}
		scripts = match ShaperTags.private_tag(split.private, "-hbsc", Lower) {
			Ok(t) => Given(t)
			Err(_) => NotGiven
		}
		languages = match ShaperTags.private_tag(split.private, "-hbot", Upper) {
			Ok(t) => [t]
			Err(_) => ShaperTags.from_language(lang.take_first(split.limit))
		}
		{ languages, scripts }
	}

	## A raw tag after `prefix` in a private-use subtag: eight hexadecimal
	## digits after a `-`, or up to four letters and digits (padded).
	private_tag : List(U8), Str, [Lower, Upper] -> Try(U64, [NotGiven])
	private_tag = |private, prefix, case| {
		pre = prefix.to_utf8()
		var $at = Err(NotFound)
		var $k = 0
		while $k + pre.len() <= private.len() {
			if private.sublist({ start: $k, len: pre.len() }) == pre {
				$at = Ok($k + pre.len())
				$k = private.len()
			} else {
				$k = $k + 1
			}
		}
		match $at {
			Err(_) => Err(NotGiven)
			Ok(start) => {
				rest = private.drop_first(start)
				alnum = |b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9')
				hex = |b| (b >= 'a' and b <= 'f') or (b >= '0' and b <= '9')
				if rest.first() == Ok('-') {
					digits = rest.drop_first(1).take_first(8)
					if digits.len() == 8 and digits.all(hex) {
						Ok(digits.fold(0, |acc, b| acc * 16 + (if (b <= '9') (b - '0').to_u64() else (b - 'a').to_u64() + 10)))
					} else {
						Err(NotGiven)
					}
				} else {
					upper = match case {
						Upper => True
						Lower => False
					}
					var $chars = []
					var $i = 0
					while $i < 4 and alnum(rest.get($i) ?? 0) {
						b = rest.get($i) ?? 0
						$chars = $chars.append(if (upper and b >= 'a' and b <= 'z') b - 32 else b)
						$i = $i + 1
					}
					if $chars.is_empty() {
						Err(NotGiven)
					} else {
						t = ShaperTags.tag_from_bytes($chars)
						# `DFLT` in any case is the default script tag.
						Ok(if (t.bitwise_and(0xDFDFDFDF) == ShaperTags.tag_of("DFLT")) t.bitwise_xor((0xFFFFFFFF).bitwise_xor(0xDFDFDFDF)) else t)
					}
				}
			}
		}
	}

	## Language system tags for the plain part of a language tag, by its
	## primary (or extended) language subtag.
	from_language : List(U8) -> List(U64)
	from_language = |plain| {
		dash = plain.find_first_index(|b| b == '-')
		# An extended language subtag (three letters) replaces the primary.
		subtag = match dash {
			Ok(d) if plain.len() >= 6 => {
				rest = plain.drop_first(d + 1)
				ext = match rest.find_first_index(|b| b == '-') {
					Ok(e) => rest.take_first(e)
					Err(_) => rest
				}
				if (ext.len() == 3 and ext.all(|b| b >= 'a' and b <= 'z')) ext else ShaperTags.first_subtag(plain)
			}
			_ => ShaperTags.first_subtag(plain)
		}
		key = ShaperTags.tag_from_bytes(subtag)
		if subtag.len() == 2 {
			ShaperTags.lookup_two(key)
		} else if subtag.len() == 3 {
			match ShaperTags.search(ShaperLanguages.three, 8, key) {
				Ok(i) => [ShaperTags.tag_at(ShaperLanguages.three, 8 * i + 4)]
				Err(_) =>
					match ShaperTags.search(ShaperLanguages.multi, 16, key) {
						Ok(i) => [4, 8, 12].map(|k| ShaperTags.tag_at(ShaperLanguages.multi, 16 * i + k)).drop_if(|t| t == 0x20202020)
						Err(_) =>
							if ShaperTags.search(ShaperLanguages.blocked, 4, key).is_ok() {
								[]
							} else {
								# Assumed to be ISO 639-3, upper-cased.
								[key.bitwise_and((0xFFFFFFFF).bitwise_xor(0x20202000))]
							}
					}
			}
		} else {
			[]
		}
	}

	## The four-byte tag at `at` of a table.
	tag_at : List(U8), U64 -> U64
	tag_at = |table, at| {
		var $t = 0
		for k in 0..<4 {
			$t = $t * 256 + (table.get(at + k) ?? 0).to_u64()
		}
		$t
	}

	first_subtag : List(U8) -> List(U8)
	first_subtag = |plain|
		match plain.find_first_index(|b| b == '-') {
			Ok(d) => plain.take_first(d)
			Err(_) => plain
		}

	# Up to three tags of a two-letter subtag, in table order.
	lookup_two : U64 -> List(U64)
	lookup_two = |key| {
		table = ShaperLanguages.two
		match ShaperTags.search(table, 8, key) {
			Err(_) => []
			Ok(found) => {
				var $i = found
				while $i > 0 and ShaperTags.tag_at(table, 8 * ($i - 1)) == key {
					$i = $i - 1
				}
				var $out = []
				while $out.len() < 3 and 8 * $i < table.len() and ShaperTags.tag_at(table, 8 * $i) == key {
					$out = $out.append(ShaperTags.tag_at(table, 8 * $i + 4))
					$i = $i + 1
				}
				$out
			}
		}
	}

	## Binary search of a table of `stride`-byte records keyed by their
	## first four bytes: the index of a record with the key.
	search : List(U8), U64, U64 -> Try(U64, [NotFound])
	search = |table, stride, key| {
		var $low = 0
		var $high = table.len() // stride
		while $low < $high {
			mid = ($low + $high) // 2
			probe = ShaperTags.tag_at(table, stride * mid)
			if key < probe {
				$high = mid
			} else if key > probe {
				$low = mid + 1
			} else {
				return Ok(mid)
			}
		}
		Err(NotFound)
	}
}
