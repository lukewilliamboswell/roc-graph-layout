import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout

## Shared subcommands and helpers for the `scripts/*.roc` task runners.
Tasks :: [].{
	roc_bin! : () => Str
	roc_bin! =
		|| match Env.var_str!(OsStr.utf8("ROC")) {
			Ok(value) => value
			Err(_) => "roc"
		}

	run! : Str, List(Str) => Try({}, _)
	run! = |program, arguments|
		Cmd.new_str(program)
			.args_str(arguments)
			.exec_cmd!()

	pinned_roc_version! : () => Try(Str, _)
	pinned_roc_version! = || {
		contents = Path.utf8(".roc-version").read_utf8!()?
		match contents.split_on("\n") {
			[first, ..] => Ok(first.trim())
			[] => Err(EmptyRocVersionFile)
		}
	}

	check! : () => Try({}, _)
	check! = || {
		Stdout.line!("Checking package...")?
		run!(roc_bin!(), ["check", "package/main.roc"])
	}

	test! : () => Try({}, _)
	test! = || {
		Stdout.line!("Running package tests...")?
		modules = Path.utf8("package").list!()?
		roc = roc_bin!()
		for entry in modules {
			path = Path.display(entry)
			if path.ends_with(".roc") and !path.ends_with("main.roc") {
				run!(roc, ["test", path])?
			}
		}
		Ok({})
	}

	bundle! : Str => Try({}, _)
	bundle! = |output_dir| {
		Stdout.line!("Bundling package...")?
		roc = roc_bin!()
		pinned = pinned_roc_version!()?
		actual = Cmd.new_str(roc).arg_str("version").exec_output!()?
		if !actual.stdout_utf8.contains(pinned) {
			Stderr.line!("ERROR: repository requires ${pinned}, got '${actual.stdout_utf8}'")?
			Err(WrongRocVersion({ pinned, actual: actual.stdout_utf8 }))
		} else {
			out = Path.utf8(output_dir)
			out.create_all!()?
			absolute_out = Path.display(Path.join(Env.cwd!()?, output_dir))
			Env.set_cwd!(Path.utf8("package"))?
			run!(roc, ["bundle", "main.roc", "--output-dir", absolute_out])
		}
	}
}
