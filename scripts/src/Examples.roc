import cli.Cmd
import cli.Duration
import cli.Env
import cli.Monotonic
import cli.OsStr
import cli.Path
import cli.Stdout
import Files
import Headers
import Loopback
import Report
import Script
import Spec

## The driver for the examples: one build of each, then every recorded case.
##
## It runs the working tree's examples, a candidate bundle's and a published
## archive's alike, so all three are held to the same recorded output. It
## builds and runs them as the shared nightly runner does: from the directory
## that holds `examples/`, with `--opt=dev`.
Examples := [].{

	## How the examples reach their packages. `Direct` leaves Roc to resolve
	## the dependencies declared in each header. `Served(server)` also answers
	## their requests from a `Loopback` server while each command runs.
	Source : [Direct, Served(Loopback.Server)]

	## What to do with the examples beneath `root`.
	##
	## `spec` is the file of cases to compare with. `Update` rewrites it from
	## what the examples print, in place of comparing. `roc_args` gives, from
	## the source of an example's application, the arguments added to its
	## `roc check` and `roc build`.
	Options : {
		root : Path,
		source : Source,
		spec : Path,
		mode : [Compare, Update],
		roc_args : Str -> List(OsStr),
	}

	## The runnable examples beneath `root`: each `examples/<dir>/main.roc`
	## with an `app` header, except interactive services, which say
	## `## scripts: service`. Paths are relative to `root`, sorted.
	discover! : Path => Try(List(Str), _)
	discover! = |root| {
		directories = Files.sort_paths(Path.list!(Path.join(root, "examples"))?)
		var $found = []
		for directory in directories {
			main = Path.join(directory, "main.roc")
			if Path.is_file!(main)? {
				source = Path.read_utf8!(main)?
				if Headers.is_app(source) and !source.contains("## scripts: service") {
					$found = $found.append("examples/${Script.file_name(directory)?}/main.roc")
				}
			}
		}
		Ok($found)
	}

	## Check and build every example once, run each case against the built
	## executable, and report every step. Fails after the summary if any step
	## failed, so one run shows everything that is wrong.
	run! : Script.Command, Options => Try({}, _)
	run! = |roc, options| {
		started = Monotonic.now!()
		colour = colour!()?
		examples = load!(options, Examples.discover!(options.root)?)?
		if examples.is_empty() {
			return Script.fail!("${Path.display(options.root)} must hold at least one example application")
		}

		done = Env.with_temp_dir!(|build| execute!(roc, options, examples, colour, build))?

		Stdout.line!("")?
		if !done.failures.is_empty() {
			Stdout.line!("Failed\n${Str.join_with(done.failures, "\n")}\n")?
		}
		Stdout.line!(Report.summary(done.steps, started.elapsed!().to_millis()))?
		if !Report.passed(done.steps) {
			return Script.fail!("${done.failures.len().to_str()} steps failed in ${Path.display(options.root)}")
		}
		match options.mode {
			Update => {
				rendered = Spec.render(done.updated)
				if Path.read_utf8!(options.spec)? == rendered {
					Script.info!("UNCHANGED", Path.display(options.spec))
				} else {
					Path.write_utf8!(options.spec, rendered)?
					Script.info!("UPDATED", Path.display(options.spec))
				}
			}
			Compare => Ok({})
		}
	}
}

# Build every example into `build`, then run every case. Each step is printed
# as it finishes and returned for the summary.
execute! : Script.Command, Examples.Options, List(Spec.App), Bool, Path => Try({ steps : List(Report.Step), failures : List(Str), updated : List(Spec.App) }, _)
execute! = |roc, options, examples, colour, build| {
	var $steps = []
	var $failures = []
	var $updated = []
	Stdout.line!("Building ${examples.len().to_str()} examples with --opt=dev")?
	labels = examples.map(|example| "build ${name_of(example.path)}")
	var $built = []
	var $index = 0
	for example in examples {
		$index = $index + 1
		executable = Path.join(build, name_of(example.path))
		begun = Monotonic.now!()
		problem = build!(roc, options, example.path, executable)?
		step = { name: "build ${name_of(example.path)}", outcome: if (problem == "") Pass else Fail, ms: begun.elapsed!().to_millis() }
		Stdout.line!(Report.line({ index: $index, total: examples.len(), width: width(labels), colour }, step))?
		$steps = $steps.append(step)
		if problem == "" {
			$built = $built.append(example.path)
		} else {
			$failures = $failures.append("  ${step.name}: ${problem}")
		}
	}

	total = examples.map(|example| example.cases.len()).sum()
	case_labels = examples.join_map(|example| example.cases.map(|case| Spec.label(example, case)))
	Stdout.line!("\nRunning ${total.to_str()} cases")?
	$index = 0
	for example in examples {
		executable = Path.join(build, name_of(example.path))
		var $cases = []
		for case in example.cases {
			$index = $index + 1
			begun = Monotonic.now!()
			result = if $built.contains(example.path) {
				case!(options, executable, case)?
			} else {
				{ case, outcome: Fail, problem: "its example did not build" }
			}
			step = { name: Spec.label(example, case), outcome: result.outcome, ms: begun.elapsed!().to_millis() }
			Stdout.line!(Report.line({ index: $index, total, width: width(case_labels), colour }, step))?
			$steps = $steps.append(step)
			$cases = $cases.append(result.case)
			if result.outcome == Fail {
				$failures = $failures.append("  ${step.name}: ${result.problem}")
			}
		}
		$updated = $updated.append({ path: example.path, cases: $cases })
	}
	Ok({ steps: $steps, failures: $failures, updated: $updated })
}

# The recorded cases, checked against the examples that exist. When updating,
# an example without cases gets one default case to record.
load! : Examples.Options, List(Str) => Try(List(Spec.App), _)
load! = |options, paths| {
	recorded = match Spec.parse(Path.read_utf8!(options.spec)?) {
		Ok(parsed) => parsed
		Err(InvalidSpec) => return Script.fail!("${Path.display(options.spec)} does not list the cases of the examples")
	}
	examples = match options.mode {
		Compare => recorded
		Update => {
			kept = recorded.keep_if(|example| paths.contains(example.path))
			added = paths
				.keep_if(|path| !kept.any(|example| example.path == path))
				.map(|path| { path, cases: [{ name: "default", args: [], stdin: "", stdout: "", stderr: "", exit_code: 0, skip: Err(Missing) }] })
			kept.concat(added)
		}
	}
	problems = Spec.problems(examples, paths)
	if problems.is_empty() {
		Ok(examples)
	} else {
		Script.fail!("${Path.display(options.spec)} does not describe the examples in ${Path.display(options.root)}:\n${Str.join_with(problems, "\n")}")
	}
}

# Check an example and build it once, for every case to run. Returns what went
# wrong, or "" when the executable is ready.
build! : Script.Command, Examples.Options, Str, Path => Try(Str, _)
build! = |roc, options, path, executable| {
	source = OsStr.from_str(path)
	roc_args = (options.roc_args)(Path.read_utf8!(Path.join(options.root, path))?)
	steps = [
		["check", source],
		["build", source, "--opt=dev", OsStr.from_str("--output=${Path.display(executable)}")],
	]
	var $problem = ""
	for args in steps {
		if $problem == "" {
			command = roc.cmd(args.concat(roc_args)).cwd(options.root)
			label = Str.join_with([roc.program].concat(args).concat(roc_args).map(OsStr.display), " ")
			output = match options.source {
				Direct => captured!(label, command)?
				Served(server) => Loopback.run!(server, command)?
			}
			$problem = match output.status {
				Exited(0) => ""
				_ => "${label} failed\n${Str.from_utf8_lossy(output.stdout_bytes)}${Str.from_utf8_lossy(output.stderr_bytes)}"
			}
		}
	}
	Ok($problem)
}

# Run one case against a built example. The case comes back as it should be
# recorded, which differs from the given one only when updating.
case! : Examples.Options, Path, Spec.Case => Try({ case : Spec.Case, outcome : Report.Outcome, problem : Str }, _)
case! = |options, executable, case| {
	match case.skip {
		Ok({ reason, issue }) => return Ok({ case, outcome: Skip("${reason}, ${issue}"), problem: "" })
		Err(Missing) => {}
	}
	command = Cmd.new(Path.to_os_str(executable))
		.args(case.args.map(OsStr.from_str))
		.cwd(options.root)
		.stdin(Bytes(Str.to_utf8(case.stdin)))
		.stdout(Capture)
		.stderr(Capture)
		.timeout(Duration.seconds(10))
	output = match command.run!() {
		Ok(finished) => finished
		Err(CmdErr(TimedOut(_))) => return Ok({ case, outcome: Fail, problem: "still running after 10_000ms" })
		Err(err) => return Err(CommandRunFailed(Path.display(executable), err))
	}
	code = match output.status {
		Exited(value) => value
		Signaled(signal) => return Ok({ case, outcome: Fail, problem: "terminated by signal ${signal.to_str()}" })
	}
	stdout = match Str.from_utf8(output.stdout_bytes) {
		Ok(text) => text
		Err(_) => return Ok({ case, outcome: Fail, problem: "stdout is not UTF-8" })
	}
	stderr = match Str.from_utf8(output.stderr_bytes) {
		Ok(text) => text
		Err(_) => return Ok({ case, outcome: Fail, problem: "stderr is not UTF-8" })
	}
	match options.mode {
		Update => Ok({ case: { ..case, stdout, stderr, exit_code: code }, outcome: Pass, problem: "" })
		Compare => {
			problem = if code != case.exit_code {
				"expected exit code ${case.exit_code.to_str()}, got ${code.to_str()}\n${stderr}"
			} else if stdout != case.stdout {
				"unexpected stdout\n    expected ${Str.inspect(case.stdout)}\n    actual   ${Str.inspect(stdout)}"
			} else if stderr != case.stderr {
				"unexpected stderr\n    expected ${Str.inspect(case.stderr)}\n    actual   ${Str.inspect(stderr)}"
			} else {
				""
			}
			Ok({ case, outcome: if (problem == "") Pass else Fail, problem })
		}
	}
}

# `examples/org_chart/main.roc` is reported, and built, as `org_chart`.
name_of = |path| path.drop_prefix("examples/").drop_suffix("/main.roc")

# Colour is an aid, never the only signal, and is left out when nobody is
# looking at a terminal or `NO_COLOR` asks for that.
colour! = || {
	if Script.env_or!("NO_COLOR", "")? != "" {
		return Ok(Bool.False)
	}
	# `test` inherits this script's standard output, and -t asks whether it is a terminal.
	output = Cmd.new("test").args(["-t", "1"]).stdout(Inherit).run!().map_err(|_| CommandRunFailed("test -t 1", Unavailable))?
	Ok(output.status == Exited(0))
}

width : List(Str) -> U64
width = |labels| labels.map(|label| Str.to_utf8(label).len()).max() ?? 0

captured! = |label, command|
	command
		.stdout(Capture)
		.stderr(Capture)
		.run!()
		.map_err(|err| CommandRunFailed(label, err))
