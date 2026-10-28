app [main!] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	pf: platform "../benchmarks/platform/main.roc",
}
import pf.Measure
import pf.Stdout
import TextMeasure
main! = |args| {
	operation = args.get(1) ?? "block"
	count = U64.from_str(args.get(2) ?? "100") ?? 100
	labels = List.repeat(0, count).map_with_index(|_, i| "+capture${i.to_str()}() : Receipt")
	style = { font: TextMeasure.inter, size: 14, line_height: 1.1, wrap: NoWrap, align: Start }
	_ = Measure.start!({})
	observation = if operation == "zero" {
		labels.len()
	} else {
		width = labels.fold(0.0, |sum, label| sum + (if (operation == "advance") TextMeasure.block_advance(label, style).width else TextMeasure.block(label, style).width))
		width.to_u64_try() ?? 0
	}
	measurement = Measure.finish!(observation)
	Stdout.line!("${measurement}}")
}
