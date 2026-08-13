#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
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
