"""Require verified fixed dependency admission before any cold candidate operation."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

module = importlib.util.spec_from_file_location("archived_examples", "scripts/check_archived_examples.py")
checker = importlib.util.module_from_spec(module)
module.loader.exec_module(checker)


class ArchiveSourceAdmissionTests(unittest.TestCase):
    def suite(self, root):
        (root / "bin").mkdir()
        compiler = root / "bin/roc"
        compiler.write_text("#!/bin/sh\nexit 0\n")
        compiler.chmod(0o700)
        self.compiler = str(compiler.resolve())
        (root / "app").mkdir()
        (root / "app/main.roc").write_text("app [main!] {}")
        (root / "run-example.py").write_bytes(Path("scripts/archive_runner.py").read_bytes())
        (root / "spec.json").write_text(json.dumps({"dependencies": [], "apps": [{
            "path": "app/main.roc", "run": ["python3", "{suite}/run-example.py", "{suite}", "{executable}"],
            "cases": [{"args": ["a b"], "stdin": "input", "stdout": "ok", "stderr": "", "exit_code": 0}],
        }]}))

    def test_admission_is_mandatory_before_cold_check_and_uses_same_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.suite(root)
            calls = []
            def execute(argv, **kwargs):
                calls.append((argv, kwargs))
                return subprocess.CompletedProcess(argv, 0, b"ok" if len(calls) == 4 else b"", b"")
            with patch.object(sys, "argv", ["check", str(root), "roc", "http://127.0.0.1:1"]), patch.object(checker.subprocess, "run", side_effect=execute), patch.dict(os.environ, {"XDG_CACHE_HOME": "/caller/cache", "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]}):
                checker.main()
                self.assertEqual(os.environ["XDG_CACHE_HOME"], "/caller/cache")
            self.assertEqual(len(calls), 4)
            self.assertEqual(calls[0][0], [sys.executable, "scripts/admit_release_sources.py", "seed", "--source", "font", "--source", "basic-cli", "--source", "legacy-http"])
            self.assertTrue(calls[0][1]["check"])
            # The helper must retain control of its bounded child groups.
            self.assertNotIn("timeout", calls[0][1])
            self.assertTrue(all(call[1]["timeout"] == 300 for call in calls[1:3]))
            self.assertEqual(calls[-1][1]["timeout"], 10)
            self.assertEqual(calls[0][1]["env"]["RA_COMPILER"], self.compiler)
            self.assertEqual(calls[1][0][0], "roc")
            self.assertEqual(calls[2][0][0], "roc")
            cache = calls[0][1]["env"]["XDG_CACHE_HOME"]
            self.assertNotEqual(cache, "/caller/cache")
            self.assertTrue(all(call[1]["env"]["XDG_CACHE_HOME"] == cache for call in calls))
            self.assertEqual([call[0][1] for call in calls[1:3]], ["check", "build"])
            self.assertTrue(all("--no-cache" in call[0] for call in calls[1:3]))
            self.assertEqual(calls[-1][1]["cwd"], root / "app")
            self.assertEqual(calls[-1][1]["input"], b"input")

    def test_missing_compiler_prevents_admission_and_candidate_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.suite(root)
            with patch.object(sys, "argv", ["check", str(root), "missing-roc", "http://127.0.0.1:1"]), patch.dict(os.environ, {"PATH": str(root / "bin")}), patch.object(checker.subprocess, "run") as execute:
                with self.assertRaisesRegex(RuntimeError, "archive compiler is unavailable"):
                    checker.main()
            execute.assert_not_called()

    def test_failed_admission_prevents_all_candidate_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.suite(root)
            with patch.object(sys, "argv", ["check", str(root), "roc", "http://127.0.0.1:1"]), patch.dict(os.environ, {"PATH": str(root / "bin")}), patch.object(checker.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "seed")) as execute:
                with self.assertRaises(subprocess.CalledProcessError):
                    checker.main()
            self.assertEqual(execute.call_count, 1)


if __name__ == "__main__":
    unittest.main()
