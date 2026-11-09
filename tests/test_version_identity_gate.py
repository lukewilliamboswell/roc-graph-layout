"""Exercise identity exit handling and prerelease routing in the actual native gate."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeVersionIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="version-gate-")
        cls.root = Path(cls.temporary.name)
        cls.binary = cls.root / "gate"
        subprocess.run([os.environ.get("ROC_STABLE", "roc-stable"), "build", "scripts/check_version.roc", f"--output={cls.binary}"], check=True, capture_output=True, timeout=60)
        cls.mock = cls.root / "mock"
        cls.mock.mkdir()
        for name, content in {
            "gh": '#!/bin/sh\nprintf "%s\\n" "$METADATA"\n',
            "roc": '#!/bin/sh\nprintf "%s\\n" "$*" > "$BUMP_TRACE"\nexit 73\n',
            "python3": '#!/bin/sh\nprintf called > "$IDENTITY_TRACE"\nexit "$IDENTITY_EXIT"\n',
        }.items():
            path = cls.mock / name
            path.write_text(content)
            path.chmod(0o700)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def execute(self, version, identity_exit):
        bump = self.root / "bump"
        identity = self.root / "identity"
        for path in (bump, identity):
            path.unlink(missing_ok=True)
        env = {**os.environ, "PATH": str(self.mock) + ":" + os.environ["PATH"], "RELEASE_VERSION": version,
               "METADATA": "0.3.0\nhttps://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.3.0/layout-Abc123.tar.zst",
               "IDENTITY_EXIT": str(identity_exit), "BUMP_TRACE": str(bump), "IDENTITY_TRACE": str(identity)}
        result = subprocess.run([str(self.binary)], env=env, capture_output=True, timeout=15)
        return result, bump, identity

    def test_valid_prerelease_keeps_strict_final_api_comparison(self):
        result, bump, identity = self.execute("0.3.1-rc1", 2)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(identity.exists())
        self.assertIn("--expect 0.3.1 package/main.roc", bump.read_text())

    def test_identity_integrity_failure_cannot_fall_through(self):
        result, bump, identity = self.execute("0.3.1", 2)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(identity.exists())
        self.assertFalse(bump.exists())

    def test_changed_content_still_requires_api_comparison(self):
        result, bump, identity = self.execute("0.3.1", 3)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(identity.exists())
        self.assertTrue(bump.exists())

    def test_verified_identity_accepts_the_patch(self):
        result, bump, identity = self.execute("0.3.1", 0)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(identity.exists())
        self.assertFalse(bump.exists())


if __name__ == "__main__":
    unittest.main()
