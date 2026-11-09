"""Exercise the archived launcher's process and working-directory boundary."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ArchiveRunnerTests(unittest.TestCase):
    def test_application_directory_launch_preserves_arguments_streams_and_exit(self):
        launcher = Path("scripts/archive_runner.py").resolve()
        with tempfile.TemporaryDirectory(prefix="archive suite '") as temporary:
            suite = Path(temporary)
            application = suite / "examples" / "sample"
            application.mkdir(parents=True)
            argument = "spaces ' quotes $() and ; remain data"
            program = "import json,os,sys; print(json.dumps([os.getcwd(),sys.argv[1:],sys.stdin.read()])); print('diagnostic',file=sys.stderr); sys.exit(23)"
            result = subprocess.run(
                [sys.executable, str(launcher), str(suite), sys.executable, "-c", program, argument],
                cwd=application, input="standard input\n", capture_output=True, text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 23)
            self.assertEqual(json.loads(result.stdout), [str(suite.resolve()), [argument], "standard input\n"])
            self.assertEqual(result.stderr, "diagnostic\n")

    def test_directory_alias_preserves_physical_cwd_and_process_io(self):
        launcher = Path("scripts/archive_runner.py").resolve()
        with tempfile.TemporaryDirectory(prefix="archive alias '") as temporary:
            root = Path(temporary)
            suite = root / "physical suite"
            application = suite / "examples" / "sample"
            application.mkdir(parents=True)
            alias = root / "suite alias"
            alias.symlink_to(suite, target_is_directory=True)
            argument = "spaces ' quotes $() and ; remain data"
            program = "import json,os,sys; print(json.dumps([os.getcwd(),sys.argv[1:],sys.stdin.read()])); print('diagnostic',file=sys.stderr); sys.exit(23)"
            result = subprocess.run(
                [sys.executable, str(launcher), str(alias), sys.executable, "-c", program, argument],
                cwd=application, input="standard input\n", capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 23)
            self.assertEqual(json.loads(result.stdout), [str(suite.resolve()), [argument], "standard input\n"])
            self.assertEqual(result.stderr, "diagnostic\n")

    def test_missing_executable_fails(self):
        result = subprocess.run(
            [sys.executable, "scripts/archive_runner.py"], capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
