app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	font: "../vendor/roc-font/main.roc",
	layout: "../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import Flowchart
import FlowDraw
import FlowLayout
import FlowSize
import Svg

## Draws flowcharts through the whole pipeline (sizing, layout, drawing),
## for `tools/mermaid-oracle/layout_visual.mjs` to set beside Mermaid's own
## rendering.
##
##     layout_draw <font family> <case.mmd> <out.svg> ...
main! = |args| {
	strings = args.map(OsStr.display)
	family = strings.get(0) ?? "sans-serif"
	rest = strings.drop_first(1)
	var $i = 0
	while $i + 1 < rest.len() {
		source_path = rest.get($i) ?? ""
		out_path = rest.get($i + 1) ?? ""
		source = Str.from_utf8_lossy(Path.read_bytes!(Path.utf8(source_path))?)
		match Flowchart.parse(source) {
			Err(problems) => Stderr.line!("${source_path}: not drawn: ${Str.inspect(problems)}")?
			Ok(diagram) => {
				sizes = FlowSize.sizes(diagram, FlowSize.mermaid)
				geometry = FlowLayout.layout(diagram, sizes)
				picture = FlowDraw.draw(diagram, sizes, geometry)
				Path.write_bytes!(Path.utf8(out_path), Svg.document(picture, family).to_utf8())?
			}
		}
		$i = $i + 2
	}
	Ok({})
}
