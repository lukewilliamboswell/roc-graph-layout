import BenchCases
import BenchFormat
import BenchJson

## What the benchmark runner writes after sampling: the per-case summary as
## CSV and Markdown, the smoke tier's determinism check, and the comparison
## of two sample files.
BenchReport := [].{

	## The contents of `summary.csv` and `summary.md` for the sample rows.
	## Only rows whose status is `ok` are summarised. Within a series, each
	## case after the smallest reports how much its median time grew over the
	## next smaller case, and the exponent that growth implies.
	summarize : List(BenchJson.Value) -> Try({ csv : Str, markdown : Str }, [InvalidSamples(Str)])
	summarize = |rows| {
		ok = rows.keep_if(is_ok)
		ids = unique(ok.keep_oks(|row| BenchJson.text(row, "case_id")))
		base = ids.map_try(|id| summary_of(id, ok.keep_if(|row| BenchJson.text(row, "case_id") == Ok(id))))?
		summaries = with_growth(base)
		header = ["case_id", "family", "operation", "fixture", "n", "m", "samples", "median_ns", "min_ns", "median_peak_extra_bytes", "median_bytes_requested", "growth_ratio", "empirical_exponent"]
		csv = Str.join_with(
			[BenchFormat.csv_record(header)].concat(
				summaries.map(
					|s|
						BenchFormat.csv_record(
							[s.case_id, s.family, s.operation, s.fixture, s.n_text, s.m_text, s.samples.to_str(), s.median_ns.to_str(), s.min_ns.to_str(), s.median_peak.to_str(), s.median_requested.to_str(), s.growth, s.exponent],
						),
				),
			),
			"",
		)
		lines = [
			"# Benchmark summary",
			"",
			"| Case | n | median ms | peak extra MiB | growth | exponent |",
			"|---|---:|---:|---:|---:|---:|",
		].concat(
			summaries.map(
				|s| "| ${s.case_id} | ${s.n_text} | ${BenchFormat.fixed(s.median_ns.to_f64() / 1000000.0, 3)} | ${BenchFormat.fixed(s.median_peak.to_f64() / 1048576.0, 3)} | ${s.growth} | ${s.exponent} |",
			),
		)
		Ok({ csv, markdown: "${Str.join_with(lines, "\n")}\n" })
	}

	## Why the smoke tier failed, if it did: a case without samples, a sample
	## that did not succeed, or telemetry that differs between samples of one
	## case. Every sample of a case runs the same deterministic work.
	smoke_problem : List(BenchCases.Case), List(BenchJson.Value) -> Try({}, [SmokeFailed(Str)])
	smoke_problem = |cases, rows| {
		for case in cases {
			group = rows.keep_if(|row| BenchJson.text(row, "case_id") == Ok(case.id))
			if group.is_empty() or !group.all(is_ok) {
				return Err(SmokeFailed("smoke failure: ${case.id}"))
			}
			stable = |row| ["observation", "alloc_calls", "realloc_calls", "dealloc_calls", "bytes_requested", "bytes_released", "peak_extra_bytes"].map(|key| BenchJson.get(row, key))
			match group {
				[first, .. as rest] =>
					if rest.any(|row| stable(row) != stable(first)) {
						return Err(SmokeFailed("nondeterministic telemetry: ${case.id}"))
					}
				[] => {}
			}
		}
		Ok({})
	}

	## One line per case that both sample files completed: the change in time
	## and in bytes requested from `baseline` to `candidate`, compared by the
	## last successful sample of each. Samples taken on different systems,
	## compilers or optimization levels are reported as incompatible.
	compare : Str, Str -> Try(List(Str), [InvalidSamples(Str)])
	compare = |baseline, candidate| {
		left = latest_ok(baseline)?
		right = latest_ok(candidate)?
		ids = unique(left.map(|(id, _)| id)).keep_if(|id| right.any(|(other, _)| other == id))
		Ok(
			ids.map(
				|id| {
					x = left.keep_if(|(other, _)| other == id).last().map_ok(|(_, row)| row) ?? Null
					y = right.keep_if(|(other, _)| other == id).last().map_ok(|(_, row)| row) ?? Null
					compatible = ["os", "arch", "roc_version", "opt"].all(|key| BenchJson.get(x, key) == BenchJson.get(y, key))
					if compatible {
						time = 100.0 * (number(y, "elapsed_ns") / number(x, "elapsed_ns") - 1.0)
						requested = 100.0 * (number(y, "bytes_requested") / number(x, "bytes_requested").max(1.0) - 1.0)
						"${id}: time ${BenchFormat.signed(time, 1)}%, requested ${BenchFormat.signed(requested, 1)}%"
					} else {
						"${id}: incompatible environments"
					}
				},
			),
		)
	}
}

Summary : {
	case_id : Str,
	family : Str,
	operation : Str,
	fixture : Str,
	n : U64,
	n_text : Str,
	m_text : Str,
	series : BenchJson.Value,
	samples : U64,
	median_ns : U64,
	min_ns : U64,
	median_peak : U64,
	median_requested : U64,
	growth : Str,
	exponent : Str,
}

is_ok : BenchJson.Value -> Bool
is_ok = |row| BenchJson.get(row, "status") == Ok(Text("ok"))

summary_of : Str, List(BenchJson.Value) -> Try(Summary, [InvalidSamples(Str)])
summary_of = |id, group| {
	first = group.first() ?? Null
	field = |key| BenchJson.get(first, key).map_err(|_| InvalidSamples("${id}: a sample has no ${key}"))
	counts = |key| group.map_try(|row| BenchJson.count(row, key)).map_err(|_| InvalidSamples("${id}: ${key} must be a count in every sample"))
	elapsed = counts("elapsed_ns")?
	n = BenchJson.count(first, "n").map_err(|_| InvalidSamples("${id}: n must be a count"))?
	Ok({
		case_id: id,
		family: python_str(field("family")?),
		operation: python_str(field("operation")?),
		fixture: python_str(field("fixture")?),
		n,
		n_text: python_str(field("n")?),
		m_text: python_str(field("m")?),
		series: BenchJson.get(first, "series") ?? Null,
		samples: group.len(),
		median_ns: BenchFormat.median(elapsed),
		min_ns: elapsed.min() ?? 0,
		median_peak: BenchFormat.median(counts("peak_extra_bytes")?),
		median_requested: BenchFormat.median(counts("bytes_requested")?),
		growth: "",
		exponent: "",
	})
}

# Within each series, ordered by n, each case gets its growth over the one before.
with_growth : List(Summary) -> List(Summary)
with_growth = |summaries| {
	var $result = summaries
	indexed = summaries.map_with_index(|s, index| (index, s))
	for series in unique_values(summaries.map(|s| s.series)) {
		ordered = List.sort_with(
			indexed.keep_if(|(_, s)| s.series == series),
			|(i, a), (j, b)| if (a.n < b.n) Before else if (a.n > b.n) After else if (i < j) Before else if (i > j) After else Same,
		)
		for (index, (_, a)) in ordered.map_with_index(|entry, at| (at, entry)) {
			match ordered.get(index + 1) {
				Ok((target, b)) => {
					ratio = b.median_ns.to_f64() / a.median_ns.max(1).to_f64()
					size = b.n.to_f64() / a.n.max(1).to_f64()
					exponent = if (size > 1.0 and ratio > 0.0) BenchFormat.fixed(BenchFormat.ln(ratio) / BenchFormat.ln(size), 3) else ""
					$result = $result.set(target, { ..b, growth: BenchFormat.fixed(ratio, 3), exponent }) ?? []
				}
				Err(_) => {}
			}
		}
	}
	$result
}

# What Python's `str` prints for a JSON value read into Python.
python_str : BenchJson.Value -> Str
python_str = |value|
	match value {
		Text(s) => s
		Num(raw) => raw
		Bool(b) => if (b) "True" else "False"
		Null => ""
		other => BenchJson.render(other)
	}

number : BenchJson.Value, Str -> F64
number = |row, key|
	match BenchJson.get(row, key) {
		Ok(Num(raw)) => F64.from_str(raw) ?? F64.nan
		_ => F64.nan
	}

# (case_id, row) for every successful sample, in file order.
latest_ok : Str -> Try(List((Str, BenchJson.Value)), [InvalidSamples(Str)])
latest_ok = |text| {
	lines = Str.split_on(text, "\n")
	content = match lines.last() {
		Ok("") => lines.drop_last(1)
		_ => lines
	}
	rows = content.map_try(|line| BenchJson.parse(line.drop_suffix("\r")).map_err(|InvalidJson(problem)| InvalidSamples("invalid sample: ${problem}")))?
	Ok(rows.keep_if(is_ok).keep_oks(|row| BenchJson.text(row, "case_id").map_ok(|id| (id, row))))
}

# Distinct values, sorted by their bytes.
unique : List(Str) -> List(Str)
unique = |values| {
	sorted = List.sort_with(values, |a, b| compare_bytes(Str.to_utf8(a), Str.to_utf8(b)))
	sorted.fold([], |out, value| if (out.last() == Ok(value)) out else out.append(value))
}

unique_values : List(BenchJson.Value) -> List(BenchJson.Value)
unique_values = |values| values.fold([], |out, value| if (out.contains(value)) out else out.append(value))

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if (a < b) Before else if (a > b) After else compare_bytes(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

row = |id, series, n, elapsed| Obj([("case_id", Text(id)), ("series", Text(series)), ("status", Text("ok")), ("family", Text("tree_tidy")), ("operation", Text("one_call")), ("fixture", Text("star")), ("n", Num(n)), ("m", Num("0")), ("elapsed_ns", Num(elapsed)), ("peak_extra_bytes", Num("1048576")), ("bytes_requested", Num("10"))])

expect {
	rows = [row("b", "s", "200", "4000"), row("a", "s", "100", "1000"), row("a", "s", "100", "3000"), Obj([("case_id", Text("c")), ("status", Text("timeout"))])]
	BenchReport.summarize(rows)
		== Ok({
			csv: "case_id,family,operation,fixture,n,m,samples,median_ns,min_ns,median_peak_extra_bytes,median_bytes_requested,growth_ratio,empirical_exponent\r\na,tree_tidy,one_call,star,100,0,2,2000,1000,1048576,10,,\r\nb,tree_tidy,one_call,star,200,0,1,4000,4000,1048576,10,2.000,1.000\r\n",
			markdown: "# Benchmark summary\n\n| Case | n | median ms | peak extra MiB | growth | exponent |\n|---|---:|---:|---:|---:|---:|\n| a | 100 | 0.002 | 1.000 |  |  |\n| b | 200 | 0.004 | 1.000 | 2.000 | 1.000 |\n",
		})
}

expect {
	case = { id: "a", series: "s", tier: "smoke", family: "tree_tidy", operation: "one_call", source: "generated", fixture: "star", size: "1", seed: "0", warmups: 0, samples: 2, timeout_ms: 1 }
	same = row("a", "s", "1", "5")
	BenchReport.smoke_problem([case], [same, same]) == Ok({})
		and BenchReport.smoke_problem([case], [same, BenchJson.set(same, "bytes_requested", Num("11"))]) == Err(SmokeFailed("nondeterministic telemetry: a"))
		and BenchReport.smoke_problem([case], []) == Err(SmokeFailed("smoke failure: a"))
}

expect {
	baseline = "{\"case_id\": \"a\", \"status\": \"ok\", \"elapsed_ns\": 100, \"bytes_requested\": 0, \"os\": \"linux\"}\n{\"case_id\": \"b\", \"status\": \"ok\", \"elapsed_ns\": 100, \"bytes_requested\": 10, \"os\": \"linux\"}\n"
	candidate = "{\"case_id\": \"b\", \"status\": \"ok\", \"elapsed_ns\": 150, \"bytes_requested\": 5, \"os\": \"linux\"}\n{\"case_id\": \"a\", \"status\": \"ok\", \"elapsed_ns\": 90, \"bytes_requested\": 0, \"os\": \"darwin\"}\n"
	BenchReport.compare(baseline, candidate) == Ok(["a: incompatible environments", "b: time +50.0%, requested -50.0%"])
}
