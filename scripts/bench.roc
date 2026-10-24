#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Cmd
import cli.Duration
import cli.OsStr
import cli.Path
import cli.Stdout
import cli.System
import src/BenchCases
import src/BenchJson
import src/BenchReport
import src/Script

## Native optimized benchmarks of the package.
##
##     blueprint run bench -- smoke [--output DIR]
##     blueprint run bench -- scale [--output DIR]
##     blueprint run bench -- compare BASELINE CANDIDATE
##
## `smoke` and `scale` build `benchmarks/main.roc` once with `--opt=speed`
## against the vendored Zig platform, run every case of
## `benchmarks/cases/<tier>.jsonl` in a fresh process per sample, and write
## `samples.jsonl`, `summary.csv` and `summary.md` to DIR, by default
## `benchmarks/results/<tier>`. After a sample times out or fails, the later
## cases of its series are skipped. The smoke tier also fails unless every
## sample succeeded and each case's telemetry is identical across samples.
##
## `compare` prints the change in time and in bytes requested for each case
## that two sample files, or directories holding `samples.jsonl`, both
## completed.
main! = |args| {
	match args.map(OsStr.display) {
		["compare", baseline, candidate] => compare!(baseline, candidate)
		[tier, .. as rest] if tier == "smoke" or tier == "scale" =>
			match rest {
				[] => execute!(tier, "benchmarks/results/${tier}")
				["--output", output] => execute!(tier, output)
				[option] if option.starts_with("--output=") => execute!(tier, option.drop_prefix("--output="))
				_ => usage!()
			}
		_ => usage!()
	}
}

usage! = || Script.fail!("usage: bench (smoke|scale) [--output DIR] | bench compare BASELINE CANDIDATE")

benchmarks : Path
benchmarks = Path.utf8("benchmarks")

build_timeout_seconds : U64
build_timeout_seconds = 600

execute! = |tier, output| {
	if !Path.is_dir!(Path.join(benchmarks, "cases"))? {
		return Script.fail!("benchmarks/cases does not exist: run from the repository root")
	}
	cases_path = "benchmarks/cases/${tier}.jsonl"
	cases = match BenchCases.parse(cases_path, Path.read_utf8!(Path.utf8(cases_path))?) {
		Ok(parsed) => parsed
		Err(InvalidCases(problem)) => return Script.fail!(problem)
	}
	binary = build!()?
	meta = metadata!()?
	var $rows = []
	var $stopped = []
	for case in cases {
		if $stopped.contains(case.series) {
			$rows = $rows.append(with_meta(Obj([("case_id", Text(case.id)), ("series", Text(case.series)), ("status", Text("skipped_after_failure"))]), meta))
		} else {
			for warmup in 0.U64..<case.warmups {
				warm = sample!(binary, case, -1 - warmup.to_i64_wrap())?
				if status(warm) != "ok" {
					return Script.fail!("warmup failed: ${BenchJson.render(warm)}")
				}
			}
			var $case_rows = []
			for index in 0.U64..<case.samples {
				row = sample!(binary, case, index.to_i64_wrap())?
				$case_rows = $case_rows.append(with_meta(row, meta))
			}
			$rows = $rows.concat($case_rows)
			if $case_rows.any(|row| status(row) == "timeout" or status(row) == "error") {
				$stopped = $stopped.append(case.series)
			}
			Stdout.line!("${case.id}: ${Str.join_with($case_rows.map(status), ", ")}")?
		}
	}
	rows = $rows

	directory = Path.utf8(output)
	Path.create_all!(directory)?
	Path.write_utf8!(Path.join(directory, "samples.jsonl"), Str.join_with(rows.map(|row| "${BenchJson.render(row)}\n"), ""))?
	summary = match BenchReport.summarize(rows) {
		Ok(value) => value
		Err(InvalidSamples(problem)) => return Script.fail!(problem)
	}
	Path.write_utf8!(Path.join(directory, "summary.csv"), summary.csv)?
	Path.write_utf8!(Path.join(directory, "summary.md"), summary.markdown)?
	if tier == "smoke" {
		match BenchReport.smoke_problem(cases, rows) {
			Ok({}) => {}
			Err(SmokeFailed(problem)) => return Script.fail!(problem)
		}
	}
	Ok({})
}

# Build the platform host, then the optimized benchmark executable.
build! = || {
	zig = Script.command("zig").cmd(["build", "-Doptimize=ReleaseFast"]).cwd(Path.join(benchmarks, "platform")).run!()?
	if zig.status != Exited(0) {
		return Script.fail!("${zig.stdout_utf8_lossy()}${zig.stderr_utf8_lossy()}")
	}
	cache = Path.join(benchmarks, ".cache")
	Path.create_all!(cache)?
	binary = Path.join(Path.absolute!(cache)?, "layout-bench")
	roc = Script.roc!()?
	built = roc
		.cmd(["build", "main.roc", OsStr.from_str("--output=${Path.display(binary)}"), "--opt=speed", "--no-cache"])
		.cwd(benchmarks)
		.timeout(Duration.seconds(build_timeout_seconds))
		.run!()
	match built {
		Ok(output) if output.status == Exited(0) => Ok(binary)
		Ok(output) => Script.fail!("${output.stdout_utf8_lossy()}${output.stderr_utf8_lossy()}")
		Err(CmdErr(TimedOut(_))) => Script.fail!("optimized benchmark build timed out after ${build_timeout_seconds.to_str()} seconds")
		Err(err) => Err(err)
	}
}

# What every row records about the machine, compilers and revision.
metadata! = || {
	roc = Script.roc!()?
	roc_version = stdout!(roc.cmd(["version"]))?
	zig_version = stdout!(Script.command("zig").cmd(["version"]))?
	revision = stdout!(Script.command("git").cmd(["rev-parse", "HEAD"]))?
	changes = stdout!(Script.command("git").cmd(["status", "--porcelain"]))?
	target = System.target!()
	{ os, arch } = match (target.os(), target.arch()) {
		(Linux(_), X64) => { os: "linux", arch: "x86_64" }
		(Linux(_), Arm64) => { os: "linux", arch: "aarch64" }
		(MacOS(_), X64) => { os: "darwin", arch: "x86_64" }
		(MacOS(_), Arm64) => { os: "darwin", arch: "arm64" }
		(Windows(_), X64) => { os: "windows", arch: "AMD64" }
		(Windows(_), Arm64) => { os: "windows", arch: "ARM64" }
	}
	Ok([
		("roc_version", Text(roc_version)),
		("zig_version", Text(zig_version)),
		("os", Text(os)),
		("arch", Text(arch)),
		("revision", Text(revision)),
		("dirty", Bool(changes != "")),
		("opt", Text("speed")),
	])
}

# Standard output of a command, trimmed, whatever its exit status.
stdout! = |command| {
	output = command.run!()?
	Ok(output.stdout_utf8_lossy().trim())
}

# One sample of `case` in a fresh process, as the row to record.
sample! = |binary, case, index| {
	at = [("case_id", Text(case.id)), ("sample", Num(index.to_str()))]
	args = [case.family, case.operation, case.source, case.fixture, case.size, case.seed].map(OsStr.from_str)
	ran = Cmd.new(Path.to_os_str(binary))
		.args(args)
		.cwd(benchmarks)
		.timeout(Duration.millis(case.timeout_ms))
		.run!()
	output = match ran {
		Ok(value) => value
		Err(CmdErr(TimedOut(_))) => return Ok(Obj(at.append(("status", Text("timeout")))))
		Err(err) => return Err(err)
	}
	code = match output.status {
		Exited(0) => 0
		Exited(value) => value
		Signaled(signal) => -signal
	}
	if code != 0 {
		return Ok(Obj(at.concat([("status", Text("error")), ("exit_code", Num(code.to_str())), ("stderr", Text(tail(output.stderr_utf8_lossy())))])))
	}
	stdout = output.stdout_utf8_lossy()
	malformed = |detail| Ok(Obj(at.concat([("status", Text("malformed")), ("detail", Text(detail)), ("stdout", Text(tail(stdout)))])))
	last = Str.split_on(stdout.trim(), "\n").last() ?? ""
	measured = match BenchJson.parse(last.drop_suffix("\r")) {
		Ok(Obj(fields)) => Obj(fields)
		Ok(_) => return malformed("the last line of output is not a JSON object")
		Err(InvalidJson(problem)) => return malformed(problem)
	}
	observation = match BenchJson.get(measured, "observation") {
		Ok(value) => value
		Err(Missing) => return malformed("the measurement has no observation")
	}
	# The observation is computed from the complete result after the timed
	# operation; it is also recorded as `digest`, the field comparisons use.
	Ok(
		[
			("digest", observation),
			("case_id", Text(case.id)),
			("series", Text(case.series)),
			("tier", Text(case.tier)),
			("sample", Num(index.to_str())),
			("status", Text("ok")),
		].fold(measured, |row, (key, value)| BenchJson.set(row, key, value)),
	)
}

with_meta = |row, meta| meta.fold(row, |acc, (key, value)| BenchJson.set(acc, key, value))

status = |row| BenchJson.text(row, "status") ?? ""

# The last 2000 bytes of `text`, starting at a character boundary.
tail = |text| {
	bytes = Str.to_utf8(text)
	start = bytes.len() - bytes.len().min(2000)
	kept = bytes.drop_first(start)
	var $skip = 0
	for byte in kept {
		if byte >= 0x80 and byte < 0xC0 {
			$skip = $skip + 1
		} else {
			break
		}
	}
	Str.from_utf8_lossy(kept.drop_first($skip))
}

compare! = |baseline, candidate| {
	left = Path.read_utf8!(samples_file!(baseline)?)?
	right = Path.read_utf8!(samples_file!(candidate)?)?
	match BenchReport.compare(left, right) {
		Ok(lines) => {
			for line in lines {
				Stdout.line!(line)?
			}
			Ok({})
		}
		Err(InvalidSamples(problem)) => Script.fail!(problem)
	}
}

# A sample file, or the `samples.jsonl` inside a results directory.
samples_file! = |name| {
	path = Path.utf8(name)
	if (Path.is_dir!(path)?) Ok(Path.join(path, "samples.jsonl")) else Ok(path)
}
