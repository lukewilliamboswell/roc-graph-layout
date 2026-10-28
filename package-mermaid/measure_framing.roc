app [main!] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
	pf: platform "../benchmarks/platform/main.roc",
}

import pf.Measure
import pf.Stdout
import Drawing
import DiagramView
import Theme

# Isolates final framing from parsing, text measurement and graph layout.
main! = |args| {
	n = U64.from_str(args.get(2) ?? "100") ?? 100
	mode = args.get(1) ?? "finish"
	var $items = []
	for i in 0..<n {
		$items = $items.append(Shape({ path: Drawing.rectangle({ x: i.to_f64() * 20, y: 0, width: 16, height: 16 }), paint: { fill: Fill(Drawing.white), stroke: Stroke({ color: Drawing.black, width: 2 }) } }))
	}
	items = $items
	picture = { view: { x: 0, y: 0, width: n.to_f64() * 20, height: 32 }, items }
	_ = Measure.start!({})
	observation = if mode == "zero" {
		picture.items.len()
	} else {
		DiagramView.finish(picture, Theme.Options.{}).items.len()
	}
	measured = Measure.finish!(observation)
	Stdout.line!("${measured}}")
}
