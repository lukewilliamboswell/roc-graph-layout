import BenchFormat
import BenchJson

## The benchmark cases in `benchmarks/cases/<tier>.jsonl`: one JSON object
## per line, each naming a family, an operation, a fixture and how many
## samples to take.
BenchCases := [].{

	## One case, with the fields the runner uses. `size` and `seed` keep their
	## JSON text, which is how the benchmark executable receives them.
	Case : {
		id : Str,
		series : Str,
		tier : Str,
		family : Str,
		operation : Str,
		source : Str,
		fixture : Str,
		size : Str,
		seed : Str,
		warmups : U64,
		samples : U64,
		timeout_ms : U64,
	}

	## The layout families the benchmark executable implements.
	families : List(Str)
	families = ["tree_tidy", "tree_radial", "layered", "circular", "force", "stress", "radial", "constrained", "overlap", "pack", "compound", "route", "metrics_crossings", "metrics_bends"]

	## Read and check every case in `text`, the contents of the file at
	## `path`. The first problem found is the error, naming its line.
	parse : Str, Str -> Try(List(Case), [InvalidCases(Str)])
	parse = |path, text| {
		var $cases = []
		var $ids = []
		var $number = 0.U64
		for line in Str.split_on(text, "\n") {
			$number = $number + 1
			if line.trim() != "" {
				at = "${path}:${$number.to_str()}"
				case = case_of(at, line, $ids)?
				$ids = $ids.append(case.id)
				$cases = $cases.append(case)
			}
		}
		Ok($cases)
	}
}

allowed : List(Str)
allowed = ["schema_version", "id", "series", "tier", "family", "operation", "fixture", "settings", "warmups", "samples", "timeout_seconds"]

fixture_fields : List(Str)
fixture_fields = ["source", "name", "size", "seed", "parameters"]

case_of : Str, Str, List(Str) -> Try(BenchCases.Case, [InvalidCases(Str)])
case_of = |at, line, ids| {
	value = BenchJson.parse(line).map_err(|InvalidJson(problem)| InvalidCases("${at}: invalid JSON: ${problem}"))?
	keys = match value {
		Obj(_) => BenchJson.keys(value)
		_ => return Err(InvalidCases("${at}: a case must be a JSON object"))
	}
	unknown = keys.keep_if(|key| !allowed.contains(key))
	if !unknown.is_empty() {
		return Err(InvalidCases("${at}: unknown fields ${BenchFormat.python_list(sorted(unknown))}"))
	}
	missing = allowed.keep_if(|key| !keys.contains(key))
	if !missing.is_empty() {
		return Err(InvalidCases("${at}: missing fields ${BenchFormat.python_list(sorted(missing))}"))
	}
	schema_ok = match BenchJson.get(value, "schema_version") {
		Ok(Num(raw)) => raw == "1" or raw == "1.0"
		_ => Bool.False
	}
	family_ok = match BenchJson.get(value, "family") {
		Ok(Text(family)) => BenchCases.families.contains(family)
		_ => Bool.False
	}
	if !schema_ok or !family_ok {
		return Err(InvalidCases("${at}: unsupported schema/family"))
	}
	id = match BenchJson.get(value, "id") {
		Ok(Text(text)) => text
		Ok(other) => BenchJson.render(other)
		Err(Missing) => ""
	}
	if ids.contains(id) {
		return Err(InvalidCases("${at}: duplicate id ${id}"))
	}
	fixture = BenchJson.get(value, "fixture") ?? Null
	fixture_keys = BenchJson.keys(fixture)
	source_ok = match BenchJson.get(fixture, "source") {
		Ok(Text(source)) => source == "generated" or source == "embedded"
		_ => Bool.False
	}
	if sorted(fixture_keys) != sorted(fixture_fields) or fixture_keys.len() != fixture_fields.len() or !source_ok {
		return Err(InvalidCases("${at}: invalid fixture"))
	}
	if BenchJson.is_truthy(BenchJson.get(value, "settings") ?? Null) or BenchJson.is_truthy(BenchJson.get(fixture, "parameters") ?? Null) {
		return Err(InvalidCases("${at}: settings/parameters are reserved for schema v2"))
	}
	typed = |problem| InvalidCases("${at}: ${Str.inspect(problem)}")
	Ok({
		id,
		series: BenchJson.text(value, "series").map_err(typed)?,
		tier: BenchJson.text(value, "tier").map_err(typed)?,
		family: BenchJson.text(value, "family").map_err(typed)?,
		operation: BenchJson.text(value, "operation").map_err(typed)?,
		source: BenchJson.text(fixture, "source").map_err(typed)?,
		fixture: BenchJson.text(fixture, "name").map_err(typed)?,
		size: number_text(fixture, "size").map_err(typed)?,
		seed: number_text(fixture, "seed").map_err(typed)?,
		warmups: BenchJson.count(value, "warmups").map_err(typed)?,
		samples: BenchJson.count(value, "samples").map_err(typed)?,
		timeout_ms: BenchJson.millis(value, "timeout_seconds").map_err(typed)?,
	})
}

number_text : BenchJson.Value, Str -> Try(Str, [Missing, NotNumber(Str)])
number_text = |value, key|
	match BenchJson.get(value, key)? {
		Num(raw) => Ok(raw)
		_ => Err(NotNumber(key))
	}

sorted : List(Str) -> List(Str)
sorted = |names| List.sort_with(names, |a, b| compare_bytes(Str.to_utf8(a), Str.to_utf8(b)))

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if (a < b) Before else if (a > b) After else compare_bytes(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

good = "{\"schema_version\":1,\"id\":\"tree-smoke\",\"series\":\"tree\",\"tier\":\"smoke\",\"family\":\"tree_tidy\",\"operation\":\"one_call\",\"fixture\":{\"source\":\"generated\",\"name\":\"star\",\"size\":100,\"seed\":0,\"parameters\":{}},\"settings\":{},\"warmups\":1,\"samples\":2,\"timeout_seconds\":30}"

expect BenchCases.parse("c.jsonl", "${good}\n\n") == Ok([{ id: "tree-smoke", series: "tree", tier: "smoke", family: "tree_tidy", operation: "one_call", source: "generated", fixture: "star", size: "100", seed: "0", warmups: 1, samples: 2, timeout_ms: 30000 }])
expect BenchCases.parse("c.jsonl", "${good}\n${good}") == Err(InvalidCases("c.jsonl:2: duplicate id tree-smoke"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, "\"tier\"", "\"zz\":0,\"extra\":1,\"tier\"")) == Err(InvalidCases("c.jsonl:1: unknown fields ['extra', 'zz']"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, ",\"warmups\":1,\"samples\":2", "")) == Err(InvalidCases("c.jsonl:1: missing fields ['samples', 'warmups']"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, "tree_tidy", "tree_untidy")) == Err(InvalidCases("c.jsonl:1: unsupported schema/family"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, "\"schema_version\":1", "\"schema_version\":2")) == Err(InvalidCases("c.jsonl:1: unsupported schema/family"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, "generated", "random")) == Err(InvalidCases("c.jsonl:1: invalid fixture"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, ",\"seed\":0", "")) == Err(InvalidCases("c.jsonl:1: invalid fixture"))
expect BenchCases.parse("c.jsonl", Str.replace_each(good, "\"settings\":{}", "\"settings\":{\"x\":1}")) == Err(InvalidCases("c.jsonl:1: settings/parameters are reserved for schema v2"))
expect BenchCases.parse("c.jsonl", "\n[1]") == Err(InvalidCases("c.jsonl:2: a case must be a JSON object"))
