app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import Mermaid
import Theme
import OracleJson
import FlowchartOracle
import SequenceOracle
import EntityOracle
import ClassOracle
import StateOracle

# Authoring-only, native production-path probe. Each request has six args:
# family profile source sizes.tsv output.json output.svg.
# A rejected source still writes its observed acceptance JSON.
main! = |args| {
	paths = args.map(OsStr.display)
	if paths.is_empty() or paths.len() % 6 != 0 {
		Stderr.line!("usage: oracle_dump <family> <default|reference> <source> <sizes.tsv> <out.json> <out.svg> ...")?
		return Err(Exit(2))
	}
	var $i = 0
	while $i < paths.len() {
		family = paths.get($i) ?? ""
		profile = paths.get($i + 1) ?? ""
		if profile != "default" and profile != "reference" {
			Stderr.line!("unknown oracle profile: ${profile}")?
			return Err(Exit(2))
		}
		source_path = paths.get($i + 2) ?? ""
		sizes_path = paths.get($i + 3) ?? ""
		json_path = paths.get($i + 4) ?? ""
		svg_path = paths.get($i + 5) ?? ""
		source = match Path.read_bytes!(Path.utf8(source_path)) {
			Ok(bytes) => Str.from_utf8_lossy(bytes)
			Err(problem) => {
				Stderr.line!("cannot read ${source_path}: ${Str.inspect(problem)}")?
				return Err(Exit(1))
			}
		}
		size_text = match Path.read_bytes!(Path.utf8(sizes_path)) {
			Ok(bytes) => Str.from_utf8_lossy(bytes)
			Err(problem) => {
				Stderr.line!("cannot read ${sizes_path}: ${Str.inspect(problem)}")?
				return Err(Exit(1))
			}
		}
		sizes = OracleJson.sizes(size_text)
		theme = if profile == "default" {
			Theme.Options.{}
		} else {
			match family {
				"sequence" => SequenceOracle.reference_theme
				"entity" => EntityOracle.reference_theme
				"class" => ClassOracle.reference_theme
				"state" => StateOracle.reference_theme
				"flowchart" => FlowchartOracle.reference_theme
				_ => crash "unknown oracle family"
			}
		}
		inspected = match family {
			"sequence" => SequenceOracle.inspect_sized(source, theme, sizes)
			"entity" => EntityOracle.inspect_sized(source, theme, sizes)
			"class" => ClassOracle.inspect_sized(source, theme, sizes)
			"state" => StateOracle.inspect_sized(source, theme, sizes)
			"flowchart" => FlowchartOracle.inspect_sized(source, theme, sizes)
			_ => crash "unknown oracle family"
		}
		Path.write_bytes!(Path.utf8(json_path), inspected.to_utf8())?
		match Mermaid.svg_with(source, Mermaid.Options.{ theme }) {
			Ok(svg) => {
				Path.write_bytes!(Path.utf8(svg_path), svg.to_utf8())?
			}
			Err(_) => {}
		}
		$i = $i + 6
	}
	Ok({})
}
