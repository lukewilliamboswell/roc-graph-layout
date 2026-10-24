app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	mermaid: "../../package-mermaid/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import mermaid.Flowchart

## Prints, for each source file given, one JSON line with what the Roc
## flowchart reader made of it, for comparison with oracle records by
## `triage.mjs`. Files that are not UTF-8 are reported as such.
##
##     roc tools/mermaid-oracle/inspect.roc -- file.mmd ...
main! = |args| {
	for arg in args {
		path = Path.utf8(OsStr.display(arg))
		bytes = Path.read_bytes!(path)?
		line = match Str.from_utf8(bytes) {
			Err(_) => "{\"file\":${json(OsStr.display(arg))},\"utf8\":false}"
			Ok(text) => "{\"file\":${json(OsStr.display(arg))},\"utf8\":true,\"result\":${result(Flowchart.parse(text))}}"
		}
		Stdout.line!(line)?
	}
	Ok({})
}

result : [Ok(Flowchart.Diagram), Err(List(Flowchart.Problem))] -> Str
result = |parsed|
	match parsed {
		Ok(diagram) => "{\"accepted\":true,\"diagram\":${diagram_json(diagram)}}"
		Err(problems) => "{\"accepted\":false,\"problems\":${array(problems.map(|p| json(Str.inspect(p))))}}"
	}

diagram_json : Flowchart.Diagram -> Str
diagram_json = |d|
	object([
		("direction", json(Str.inspect(d.direction))),
		("nodes", array(d.nodes.map(|n| object([("id", json(n.id)), ("label", json(n.label)), ("shape", json(Str.inspect(n.shape))), ("container", json(Str.inspect(n.container))), ("classes", strings(n.classes)), ("styles", strings(n.styles))])))),
		(
			"edges",
			array(
				d.edges.map(
					|e|
						object([
							("id", json(e.id)),
							("from", json(Str.inspect(e.from))),
							("to", json(Str.inspect(e.to))),
							("label", json(e.label)),
							("line", json(Str.inspect(e.line))),
							("start", json(Str.inspect(e.start))),
							("end", json(Str.inspect(e.end))),
							("length", e.length.to_str()),
							("classes", strings(e.classes)),
							("styles", strings(e.styles)),
						]),
				),
			),
		),
		("groups", array(d.groups.map(|g| object([("id", json(g.id)), ("title", json(g.title)), ("container", json(Str.inspect(g.container))), ("direction", json(Str.inspect(g.direction))), ("classes", strings(g.classes))])))),
		("classes", array(d.classes.map(|c| object([("name", json(c.name)), ("styles", strings(c.styles))])))),
	])

object : List((Str, Str)) -> Str
object = |fields| "{${Str.join_with(fields.map(|(k, v)| "${json(k)}:${v}"), ",")}}"

array : List(Str) -> Str
array = |items| "[${Str.join_with(items, ",")}]"

strings : List(Str) -> Str
strings = |items| array(items.map(json))

## A JSON string literal.
json : Str -> Str
json = |text| {
	var $out = ['"']
	for b in text.to_utf8() {
		$out = if b == '"' {
			$out.concat(['\\', '"'])
		} else if b == '\\' {
			$out.concat(['\\', '\\'])
		} else if b == '\n' {
			$out.concat(['\\', 'n'])
		} else if b < 0x20 {
			hex = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f']
			$out.concat(['\\', 'u', '0', '0', hex.get((b / 16).to_u64()) ?? '0', hex.get((b % 16).to_u64()) ?? '0'])
		} else {
			$out.append(b)
		}
	}
	Str.from_utf8_lossy($out.append('"'))
}
