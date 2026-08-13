#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
}

import Tasks

main! : List(_) => Try({}, _)
main! = |_args| {
	Tasks.check!()?
	Tasks.test!()?
	Tasks.run_examples!()?
	Tasks.bundle!("dist")
}
