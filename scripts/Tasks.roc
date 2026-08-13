import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
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

	check! : () => Try({}, _)
	check! = || {
		Stdout.line!("Checking package...")?
		run!(roc_bin!(), ["check", "package/main.roc"])
	}

	## Recursively collects every `.roc` file under `dir`, except ones named
	## `main.roc` — those are package manifests or app entry points, not
	## modules with `expect` tests of their own.
	testable_files! : Path => Try(List(Path), _)
	testable_files! = |dir| {
		entries = dir.list!()?
		var $collected = []

		for entry in entries {
			if entry.is_dir!()? {
				nested = testable_files!(entry)?
				$collected = $collected.concat(nested)
			} else {
				name = Path.display(entry)
				if name.ends_with(".roc") and !name.ends_with("main.roc") {
					$collected = $collected.append(entry)
				}
			}
		}

		Ok($collected)
	}

	test! : () => Try({}, _)
	test! = || {
		Stdout.line!("Running tests...")?
		roc = roc_bin!()
		package_files = testable_files!(Path.utf8("package"))?
		example_files = testable_files!(Path.utf8("examples"))?

		for entry in package_files.concat(example_files) {
			run!(roc, ["test", Path.display(entry)])?
		}

		Ok({})
	}

	## Runs every runnable example app under `examples/` (any `main.roc` whose
	## header starts with `app`, as opposed to a helper `package` manifest
	## like `examples/svg/main.roc`). Each app is expected to regenerate its
	## own golden output file(s) in place, so a subsequent `git diff` can
	## catch any unintended change.
	run_examples! : () => Try({}, _)
	run_examples! = || {
		Stdout.line!("Running examples...")?
		roc = roc_bin!()
		dirs = Path.utf8("examples").list!()?

		for dir in dirs {
			if dir.is_dir!()? {
				main_path = Path.join(dir, "main.roc")
				is_app = match main_path.read_utf8!() {
					Ok(contents) => {
						first_code_line = contents.split_on("\n").keep_if(|line| !line.starts_with("#") and !line.is_empty()).first() ?? ""
						first_code_line.starts_with("app")
					}
					Err(_) => Bool.False
				}
				if is_app {
					run!(roc, [Path.display(main_path)])?
				}
			}
		}

		Ok({})
	}

	bundle! : Str => Try({}, _)
	bundle! = |output_dir| {
		Stdout.line!("Bundling package...")?
		roc = roc_bin!()
		out = Path.utf8(output_dir)
		out.create_all!()?
		absolute_out = Path.display(Path.join(Env.cwd!()?, output_dir))
		Env.set_cwd!(Path.utf8("package"))?
		run!(roc, ["bundle", "main.roc", "--output-dir", absolute_out])
	}
}
