#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import pf.OsStr
import Tasks

main! : List(OsStr) => Try({}, _)
main! = |args|
	match args.drop_first(1).map(OsStr.display) {
		[output_dir] => Tasks.bundle!(output_dir)
		[] => Tasks.bundle!("dist")
		_ => Err(TooManyArguments)
	}
