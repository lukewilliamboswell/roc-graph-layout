## What the examples are expected to do, `tests/examples.json`.
##
## It lists every runnable example with the cases to run it with: the
## arguments, the standard input, and the exact standard output, standard
## error and exit code expected. The release's examples archive carries the
## same cases as its `spec.json`, in the form the shared nightly runner of
## roc-automation reads, so a release is always held to what it printed when
## it was published.
Spec := [].{

	## Why a case is not run. Both fields are required, so a skip always says
	## what is broken and where that is tracked.
	Skip : { reason : Str, issue : Str }

	## One run of an example, from the directory that holds `examples/`.
	Case : {
		name : Str,
		args : List(Str),
		stdin : Str,
		stdout : Str,
		stderr : Str,
		exit_code : I32,
		skip : Try(Skip, [Missing]),
	}

	## An example, by the path of its application from the directory that
	## holds `examples/`, and its cases.
	App : { path : Str, cases : List(Case) }

	## The archived form: the cases, the release they belong to, and the
	## bundle URLs the archived examples depend on.
	Suite : { schema_version : U64, release : Str, dependencies : List(Str), apps : List(App) }

	## Read the cases from the text of `tests/examples.json`.
	parse : Str -> Try(List(App), [InvalidSpec])
	parse = |text| {
		spec : Try({ apps : List(App) }, _)
		spec = Json.parse(text)
		match spec {
			Ok({ apps }) => Ok(apps)
			Err(_) => Err(InvalidSpec)
		}
	}

	## Read an archived `spec.json`.
	parse_suite : Str -> Try(Suite, [InvalidSpec])
	parse_suite = |text| {
		suite : Try(Suite, _)
		suite = Json.parse(text)
		suite.map_err(|_| InvalidSpec)
	}

	## Everything wrong with `apps` as the cases of the examples at `paths`.
	## An empty list means they can be run.
	problems : List(App), List(Str) -> List(Str)
	problems = |apps, paths| {
		specified = apps.map(|example| example.path)
		missing = paths.keep_if(|path| !specified.contains(path)).map(|path| "${path}: no cases are recorded for this example")
		extra = specified.keep_if(|path| !paths.contains(path)).map(|path| "${path}: cases are recorded for an example that does not exist")
		repeated = specified.keep_if(|path| specified.count_if(|other| other == path) != 1).map(|path| "${path}: listed more than once")
		missing.concat(extra).concat(repeated).concat(apps.join_map(app_problems))
	}

	## The cases as the text of `tests/examples.json`: one line per value, so
	## a change in expected output is a diff a reviewer can read.
	render : List(App) -> Str
	render = |apps| pretty(Json.to_str({ apps: apps }))

	## The archived `spec.json` of the release `version`, whose examples
	## depend on the bundles at `dependencies`.
	render_suite : List(App), Str, List(Str) -> Str
	render_suite = |apps, version, dependencies| {
		suite : Suite
		suite = { schema_version: 1, release: version, dependencies, apps }
		pretty(Json.to_str(suite))
	}

	## The label a case is reported under.
	label : App, Case -> Str
	label = |example, case| {
		stem = example.path.drop_prefix("examples/").drop_suffix("/main.roc")
		if (example.cases.len() == 1) stem else "${stem} [${case.name}]"
	}
}

app_problems : Spec.App -> List(Str)
app_problems = |example|
	(if (example.cases.is_empty()) ["${example.path}: at least one case is required"] else [])
		.concat(example.cases.join_map(|case| case_problems(example, case)))

case_problems : Spec.App, Spec.Case -> List(Str)
case_problems = |example, case| {
	at = "${example.path} [${case.name}]"
	name = if (case.name == "" or example.cases.count_if(|other| other.name == case.name) != 1) ["${at}: every case needs a unique, non-empty name"] else []
	skip = match case.skip {
		Ok({ reason, issue }) =>
			(if (reason == "") ["${at}: a skip needs a reason"] else [])
				.concat(if (issue.starts_with("https://")) [] else ["${at}: a skip needs a link to the issue that tracks it"])
		Err(Missing) => []
	}
	name.concat(skip)
}

pretty = |compact| "${Str.from_utf8_lossy(indent(Str.to_utf8(compact), 0, Outside, []))}\n"

# Json.to_str writes everything on one line. Break after each `{`, `[` and `,`
# and before each `}` and `]` that are not inside a string, indenting by depth.
indent : List(U8), U64, [Inside, Outside], List(U8) -> List(U8)
indent = |bytes, depth, state, out|
	match (state, bytes) {
		(_, []) => out
		(Inside, ['\\', escaped, .. as rest]) => indent(rest, depth, Inside, out.append('\\').append(escaped))
		(Inside, ['"', .. as rest]) => indent(rest, depth, Outside, out.append('"'))
		(Inside, [byte, .. as rest]) => indent(rest, depth, Inside, out.append(byte))
		(Outside, ['"', .. as rest]) => indent(rest, depth, Inside, out.append('"'))
		(Outside, ['{', '}', .. as rest]) => indent(rest, depth, Outside, out.concat(['{', '}']))
		(Outside, ['[', ']', .. as rest]) => indent(rest, depth, Outside, out.concat(['[', ']']))
		(Outside, ['{', .. as rest]) => indent(rest, depth + 1, Outside, new_line(out.append('{'), depth + 1))
		(Outside, ['[', .. as rest]) => indent(rest, depth + 1, Outside, new_line(out.append('['), depth + 1))
		(Outside, ['}', .. as rest]) => indent(rest, depth - 1, Outside, new_line(out, depth - 1).append('}'))
		(Outside, [']', .. as rest]) => indent(rest, depth - 1, Outside, new_line(out, depth - 1).append(']'))
		(Outside, [',', .. as rest]) => indent(rest, depth, Outside, new_line(out.append(','), depth))
		(Outside, [':', .. as rest]) => indent(rest, depth, Outside, out.concat([':', ' ']))
		(Outside, [byte, .. as rest]) => indent(rest, depth, Outside, out.append(byte))
	}

new_line = |out, depth| out.append('\n').concat(List.repeat(' ', depth * 2))

case : Spec.Case
case = { name: "default", args: [], stdin: "", stdout: "Laid out 3 nodes\n", stderr: "", exit_code: 0, skip: Err(Missing) }

org_chart : Spec.App
org_chart = { path: "examples/org_chart/main.roc", cases: [case] }

expect Spec.parse(Spec.render([org_chart])) == Ok([org_chart])
expect Spec.render([org_chart]).starts_with("{\n  \"apps\": [\n")
expect Spec.parse("{\"apps\": 3}") == Err(InvalidSpec)
expect Spec.problems([org_chart], ["examples/org_chart/main.roc"]) == []
expect Spec.problems([org_chart], ["examples/org_chart/main.roc", "examples/mind_map/main.roc"]) == ["examples/mind_map/main.roc: no cases are recorded for this example"]
expect Spec.problems([org_chart, org_chart], ["examples/org_chart/main.roc"]).len() == 2
expect Spec.problems([{ ..org_chart, cases: [] }], ["examples/org_chart/main.roc"]) == ["examples/org_chart/main.roc: at least one case is required"]
expect Spec.problems([{ ..org_chart, cases: [{ ..case, skip: Ok({ reason: "", issue: "x" }) }] }], ["examples/org_chart/main.roc"]).len() == 2
expect Spec.label(org_chart, case) == "org_chart"
expect {
	text = Spec.render_suite([org_chart], "0.2.0", ["https://example.com/A.tar.zst", "https://example.com/M.tar.zst"])
	Spec.parse_suite(text) == Ok({ schema_version: 1, release: "0.2.0", dependencies: ["https://example.com/A.tar.zst", "https://example.com/M.tar.zst"], apps: [org_chart] })
}
