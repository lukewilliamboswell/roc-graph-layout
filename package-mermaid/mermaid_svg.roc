app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import Mermaid

## Turns supported Mermaid diagram files into SVG through `Mermaid.svg`, the public
## API, so the whole pipeline can be compared with Mermaid's own rendering
## (see `tools/mermaid-oracle/e2e.mjs`).
##
##     mermaid_svg <in.mmd> <out.svg> [<in.mmd> <out.svg> ...]
##
## A file that cannot be drawn is reported on standard error with its
## problems; the others are still written, and the exit code is then 1.
main! = |args| {
	paths = args.map(OsStr.display)
	if paths.is_empty() or paths.len() % 2 != 0 {
		Stderr.line!("usage: mermaid_svg <in.mmd> <out.svg> [<in.mmd> <out.svg> ...]")?
		Err(Exit(2))
	} else {
		var $failed = 0
		var $i = 0
		while $i + 1 < paths.len() {
			in_path = paths.get($i) ?? ""
			out_path = paths.get($i + 1) ?? ""
			match Path.read_bytes!(Path.utf8(in_path)) {
				Err(err) => {
					Stderr.line!("${in_path}: cannot read: ${Str.inspect(err)}")?
					$failed = $failed + 1
				}
				Ok(bytes) =>
					match Mermaid.svg(Str.from_utf8_lossy(bytes)) {
						Err(problems) => {
							Stderr.line!("${in_path}: not drawn: ${Str.inspect(problems)}")?
							$failed = $failed + 1
						}
						Ok(svg) =>
							match Path.write_bytes!(Path.utf8(out_path), svg.to_utf8()) {
								Ok({}) => {}
								Err(err) => {
									Stderr.line!("${out_path}: cannot write: ${Str.inspect(err)}")?
									$failed = $failed + 1
								}
							}
					}
			}
			$i = $i + 2
		}
		if ($failed == 0) Ok({}) else Err(Exit(1))
	}
}
