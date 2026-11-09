import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RELEASE = Path(".github/workflows/release.yml")
DOCS = Path(".github/workflows/docs.yml")
NOV7 = "nightly-2026-11-07-ad3a5d2"
NOV9 = "nightly-2026-11-09-9e85de7"
GH_ARGS = ["api", "--hostname", "github.com", "repos/roc-lang/nightlies/releases/latest", "--jq", ".tag_name | tojson"]


def resolver_shell():
    lines = RELEASE.read_text().splitlines()
    start = lines.index("      - name: Resolve the release compiler")
    start = lines.index("        run: |", start) + 1
    body = []
    for line in lines[start:]:
        if line and not line.startswith("          "):
            break
        body.append(line[10:] if line else "")
    return "\n".join(body) + "\n"


class ReleaseNightlySelectionTests(unittest.TestCase):
    def run_selection(self, requested, latest=NOV9, raw_output=None, gh_code=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls, output, marker = root / "calls.json", root / "output", root / "executed"
            output.write_text("existing=preserved\n")
            gh = root / "gh"
            gh.write_text("#!" + sys.executable + "\n" +
                          "import json,os,pathlib,sys\n"
                          "with open(os.environ['GH_CALLS'],'a') as calls: calls.write(json.dumps(sys.argv[1:])+'\\n')\n"
                          "sys.stdout.write(os.environ['GH_STUB_OUTPUT'])\n"
                          "raise SystemExit(int(os.environ['GH_STUB_CODE']))\n")
            gh.chmod(0o755)
            environment = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                           "REQUESTED_NIGHTLY": requested, "GITHUB_OUTPUT": str(output),
                           "GH_CALLS": str(calls), "GH_STUB_CODE": str(gh_code),
                           "GH_STUB_OUTPUT": json.dumps(latest) + "\n" if raw_output is None else raw_output,
                           "INJECTION_MARKER": str(marker), "PYTHONDONTWRITEBYTECODE": "1"}
            result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"],
                                    input=resolver_shell(), env=environment, text=True,
                                    capture_output=True, timeout=5)
            return result, output.read_text(), [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else None, marker.exists()

    def test_empty_selects_official_latest_once(self):
        result, output, calls, executed = self.run_selection("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [GH_ARGS])
        self.assertEqual(output, "existing=preserved\ntag=" + NOV9 + "\n")
        self.assertFalse(executed)

    def test_explicit_canonical_tags_never_query_latest(self):
        for tag in (NOV7, NOV9, "nightly-2024-02-29-" + "a" * 40):
            with self.subTest(tag=tag):
                result, output, calls, executed = self.run_selection(tag, gh_code=99)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(calls)
                self.assertEqual(output, "existing=preserved\ntag=" + tag + "\n")
                self.assertFalse(executed)

    def test_malformed_explicit_tags_leave_outputs_untouched(self):
        invalid = ["latest", " " + NOV7, NOV7 + " ", "nightly-2026-11-07-abcdef",
                   "nightly-2026-11-07-" + "a" * 41, "nightly-2026-11-07-ABCDEF0",
                   "nightly-0000-11-07-abcdef0", "nightly-2026-13-07-abcdef0",
                   "nightly-2026-04-31-abcdef0", "nightly-2025-02-29-abcdef0",
                   "nightly-2026-1-07-abcdef0", "nightly-2026-11-7-abcdef0",
                   NOV7 + "\n", NOV7 + "\r", "\n" + NOV7, NOV7 + "\ntag=forged",
                   '$(touch "$INJECTION_MARKER")', '`touch "$INJECTION_MARKER"`',
                   NOV7 + ';touch "$INJECTION_MARKER"', NOV7 + '";touch "$INJECTION_MARKER";#']
        for tag in invalid:
            with self.subTest(tag=repr(tag)):
                result, output, calls, executed = self.run_selection(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "existing=preserved\n")
                self.assertIsNone(calls)
                self.assertFalse(executed)

    def test_malformed_latest_metadata_cannot_become_output(self):
        for latest in (NOV9 + "\n", NOV9 + "\ntag=forged", "nightly-2026-02-30-abcdef0",
                       '$(touch "$INJECTION_MARKER")', None, [], 7):
            with self.subTest(latest=latest):
                result, output, calls, executed = self.run_selection("", latest=latest)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "existing=preserved\n")
                self.assertEqual(calls, [GH_ARGS])
                self.assertFalse(executed)
        result, output, calls, executed = self.run_selection("", raw_output="not JSON")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "existing=preserved\n")
        self.assertEqual(calls, [GH_ARGS])
        self.assertFalse(executed)

    def test_latest_request_failure_cannot_use_valid_partial_output(self):
        result, output, calls, executed = self.run_selection("", gh_code=7)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "existing=preserved\n")
        self.assertEqual(calls, [GH_ARGS])
        self.assertFalse(executed)

    def test_single_selection_is_wired_to_build_archive_test_and_site(self):
        release, docs = RELEASE.read_text(), DOCS.read_text()
        self.assertIn("REQUESTED_NIGHTLY: ${{ inputs.nightly-tag }}", release)
        self.assertNotIn("${{", resolver_shell())
        self.assertIn("nightly_tag: ${{ steps.nightly.outputs.tag }}", release)
        self.assertEqual(release.count("nightly-tag: ${{ steps.nightly.outputs.tag }}"), 1)
        self.assertEqual(release.count("nightly-tag: ${{ needs.build.outputs.nightly_tag }}"), 2)
        self.assertIn("uses: ./.github/workflows/docs.yml\n    with:\n      nightly-tag: ${{ needs.build.outputs.nightly_tag }}", release)
        self.assertIn("nightly-tag: ${{ inputs.nightly-tag }}", docs)
        self.assertIn("type: string\n        default: ''", docs)
        self.assertIn("required: false\n        type: string\n        default: ''", release)


if __name__ == "__main__":
    unittest.main()
