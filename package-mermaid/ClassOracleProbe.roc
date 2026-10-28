app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
}
import cli.OsStr
import cli.Path
import ClassOracle
import EntityOracle
import Mermaid
import OracleJson
import Theme
main! = |args| {
	paths = args.map(OsStr.display)
	source = Path.read_utf8!(Path.utf8(paths.get(1) ?? ""))?
	family = paths.get(0) ?? "class"
	theme = if paths.get(3) == Ok("reference") {
		if (family == "class") ClassOracle.reference_theme else EntityOracle.reference_theme
	} else {
		Theme.Options.{}
	}
	overrides = match paths.get(4) {
		Ok(file) => OracleJson.sizes(Path.read_utf8!(Path.utf8(file))?)
		Err(_) => []
	}
	result = if (family == "class") ClassOracle.inspect_sized(source, theme, overrides) else EntityOracle.inspect_sized(source, theme, overrides)
	Path.write_utf8!(Path.utf8(paths.get(2) ?? "/tmp/mermaid-native.json"), result)?
	match Mermaid.svg_with(source, Mermaid.Options.{ theme }) {
		Ok(svg) => Path.write_utf8!(Path.utf8("${paths.get(2) ?? "/tmp/mermaid-native.json"}.svg"), svg)?
		Err(_) => {}
	}
	Ok({})
}
