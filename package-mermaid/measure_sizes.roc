app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc1/Htk86c6Rt21oHN9zroWfqBEwtTuQ1EVgkMPMrgernGWA.tar.zst",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import Flowchart
import FlowGeometry
import FlowSize

## Prints, for each Mermaid file given, one JSON line with the sizes
## `FlowSize` computes, for comparison with oracle records by
## `tools/mermaid-oracle/measure_compare.mjs`.
##
##     roc build package-mermaid/measure_sizes.roc --output=measure_sizes
##     ./measure_sizes file.mmd ...
main! = |args| {
	for arg in args {
		path = Path.utf8(OsStr.display(arg))
		bytes = Path.read_bytes!(path)?
		body = match Str.from_utf8(bytes) {
			Err(_) => "\"accepted\":false"
			Ok(text) =>
				match Flowchart.parse(text) {
					Err(_) => "\"accepted\":false"
					Ok(diagram) => {
						sizes = FlowSize.sizes(diagram, FlowSize.mermaid)
						nodes = diagram.nodes.map2(sizes.nodes, |n, s| "{\"id\":${json(n.id)},\"shape\":${json(Str.inspect(n.shape))},\"width\":${s.width.to_str()},\"height\":${s.height.to_str()},\"label\":${block(s.label)}}")
						edges = diagram.edges.map2(
							sizes.edge_labels,
							|e, l|
								match l {
									None => "{\"id\":${json(e.id)},\"label\":null}"
									Some(b) => "{\"id\":${json(e.id)},\"label\":${block(b)}}"
								},
						)
						groups = diagram.groups.map2(sizes.group_titles, |g, t| "{\"id\":${json(g.id)},\"title\":${block(t)}}")
						"\"accepted\":true,\"nodes\":[${Str.join_with(nodes, ",")}],\"edges\":[${Str.join_with(edges, ",")}],\"groups\":[${Str.join_with(groups, ",")}]"
					}
				}
		}
		Stdout.line!("{\"file\":${json(OsStr.display(arg))},${body}}")?
	}
	Ok({})
}

block : FlowGeometry.TextBlock -> Str
block = |b| "{\"lines\":[${Str.join_with(b.lines.map(json), ",")}],\"width\":${b.width.to_str()},\"height\":${b.height.to_str()}}"

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
