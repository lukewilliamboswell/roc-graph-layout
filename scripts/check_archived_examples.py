"""Check the candidate's declared argv from application directories, as shared 0ad does."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    root, compiler, base = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3]
    spec = json.loads((root / "spec.json").read_text())
    expected_run = ["python3", "{suite}/run-example.py", "{suite}", "{executable}"]
    assert (root / "run-example.py").read_bytes() == Path("scripts/archive_runner.py").read_bytes()
    assert spec["apps"] and all(app["run"] == expected_run for app in spec["apps"])
    checks = builds = cases = 0
    with tempfile.TemporaryDirectory(prefix="canonical-archive-") as temporary:
        environment = {**os.environ, "XDG_CACHE_HOME": str(Path(temporary) / "cache")}
        for index, app in enumerate(spec["apps"]):
            source = (root / app["path"]).read_text()
            replacements = []
            # Mermaid transitively imports the layout package; no other source changes.
            for dependency in spec["dependencies"]:
                if dependency in source or 'mermaid:' in source:
                    replacements += ["--replace-dep", dependency, base + "/" + dependency.rsplit("/", 1)[1]]
            executable = str(Path(temporary) / f"example-{index}")
            for command in [
                [compiler, "check", app["path"], "--no-cache", *replacements],
                [compiler, "build", app["path"], "--no-cache", "--opt=dev", f"--output={executable}", *replacements],
            ]:
                result = subprocess.run(command, cwd=root, env=environment, capture_output=True, timeout=300)
                if result.returncode:
                    sys.stdout.buffer.write(result.stdout)
                    sys.stderr.buffer.write(result.stderr)
                    raise RuntimeError(f"cold {command[1]} failed: {app['path']}")
            checks += 1
            builds += 1
            for case in app["cases"]:
                assert not case.get("skip"), "every archived case must execute"
                argv = [arg.replace("{suite}", str(root)).replace("{executable}", executable) for arg in app["run"]]
                result = subprocess.run(
                    argv + case["args"], cwd=(root / app["path"]).parent,
                    env=environment, input=case["stdin"].encode(), capture_output=True, timeout=10,
                )
                assert result.returncode == case["exit_code"], (app["path"], result.stderr)
                assert result.stdout == case["stdout"].encode(), app["path"]
                assert result.stderr == case["stderr"].encode(), app["path"]
                cases += 1
    print(f"PASS canonical application-directory archive contract: {checks} cold checks, {builds} cold builds, {cases} exact runtime cases")


if __name__ == "__main__":
    main()
