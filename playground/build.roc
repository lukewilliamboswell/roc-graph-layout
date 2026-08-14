#!/usr/bin/env roc
app [main!] { pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.23.0/7NpDhuqoqGFedmVLvmm1zjq37GCmaFGzwr5sz4ch9wTK.tar.zst" }
import pf.Cmd
import pf.Env
import pf.Path
main! = |_args| {
	out = "playground/www/app.wasm"
	if Path.utf8(out).is_file!()? Path.utf8(out).delete!()? else {}
	Cmd.new_str("roc").args_str(["build", "--opt=dev", "--target=wasm32", "--no-cache", "--output=${out}", "playground/app.roc"]).exec_cmd!()?
	source = Path.utf8("playground/app.roc").read_utf8!()?
	hash = source.split_first("pf: platform \"")?.after.split_first("\"")?.before.split_last("/")?.after.drop_suffix(".tar.zst")
	home = Env.var_str!("HOME") ?? ""
	cache = Env.var_str!("XDG_CACHE_HOME") ?? "${home}/.cache"
	Cmd.new_str("cp").args_str(["${cache}/roc/packages/${hash}/www/runtime.js", "playground/www/runtime.js"]).exec_cmd!()
}
