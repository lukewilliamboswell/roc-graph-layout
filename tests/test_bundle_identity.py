import copy
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

module = importlib.util.spec_from_file_location("bundle_identity", "scripts/check_bundle_identity.py")
proof = importlib.util.module_from_spec(module)
module.loader.exec_module(proof)
OLD = proof.PREFIX + "0.3.0/layout-Abc123.tar.zst"
NEW = proof.PREFIX + "0.3.1/layout-Abc123.tar.zst"
HEADER = b'package [Mermaid] {\n\tlayout: "' + OLD.encode() + b'",\n}\n'


class BundleIdentityTests(unittest.TestCase):
    def mermaid(self, main=HEADER):
        return {"main.roc": (tarfile.REGTYPE, 0o644, main), "Mermaid.roc": (tarfile.REGTYPE, 0o644, b"unchanged")}

    def accepted(self, old=None, new=None, **kwargs):
        old = old if old is not None else self.mermaid()
        new = new if new is not None else self.mermaid(HEADER.replace(OLD.encode(), NEW.encode()))
        return proof.compare(b"layout", b"layout", old, new, OLD, NEW, **kwargs)

    def test_only_verified_layout_rebinding_passes(self):
        self.accepted()

    def test_changed_layout_requires_normal_api_gate(self):
        with self.assertRaises(proof.ContentsChanged):
            proof.compare(b"old", b"new", {}, {}, OLD, NEW)

    def test_same_name_changed_bytes_are_integrity_failure(self):
        with self.assertRaises(proof.IntegrityError):
            proof.compare(b"old", b"new", {}, {}, OLD, NEW, same_layout_name=True)
        with self.assertRaises(proof.IntegrityError):
            self.accepted(same_mermaid_name=True)

    def test_extra_mermaid_payload_change_requires_api_gate(self):
        new = self.mermaid(HEADER.replace(OLD.encode(), NEW.encode()))
        new["Mermaid.roc"] = (tarfile.REGTYPE, 0o644, b"changed")
        with self.assertRaises(proof.ContentsChanged):
            self.accepted(new=new)

    def test_added_or_missing_member_requires_api_gate(self):
        for add in (True, False):
            new = self.mermaid(HEADER.replace(OLD.encode(), NEW.encode()))
            if add:
                new["Extra.roc"] = (tarfile.REGTYPE, 0o644, b"extra")
            else:
                del new["Mermaid.roc"]
            with self.assertRaises(proof.ContentsChanged):
                self.accepted(new=new)

    def test_wrong_field_url_location_or_occurrence_is_integrity_failure(self):
        for main in [HEADER.replace(b"layout:", b"other:"), HEADER.replace(OLD.encode(), b"https://wrong"), HEADER + OLD.encode(), b"module [M]\n" + HEADER, HEADER.replace(b"\n}", b'\n\tlayout: "' + OLD.encode() + b'",\n}')]:
            with self.assertRaises(proof.IntegrityError):
                self.accepted(old=self.mermaid(main))
        with self.assertRaises(proof.IntegrityError):
            self.accepted(new=self.mermaid(HEADER))

    def test_changed_mode_is_integrity_failure(self):
        new = self.mermaid(HEADER.replace(OLD.encode(), NEW.encode()))
        new["Mermaid.roc"] = (tarfile.REGTYPE, 0o755, b"unchanged")
        with self.assertRaises(proof.IntegrityError):
            self.accepted(new=new)

    def releases(self):
        def asset(kind, number):
            name = kind + "-Abc123.tar.zst"
            return {"id": number, "name": name, "size": 4, "digest": "sha256:" + proof.sha(b"data"), "browser_download_url": proof.PREFIX + "0.3.0/" + name}
        return [{"draft": False, "prerelease": False, "immutable": True, "tag_name": "0.3.0", "assets": [asset("layout", 1), asset("mermaid", 2)]}]

    def test_actual_unique_release_assets_are_required(self):
        self.assertEqual(set(proof.selected_assets(self.releases(), "0.3.0")), {"layout", "mermaid"})
        for change in ("ambiguous", "digest", "url", "size", "release"):
            releases = self.releases()
            assets = releases[0]["assets"]
            if change == "ambiguous":
                extra = copy.deepcopy(assets[0]); extra["name"] = "layout-Xyz123.tar.zst"; extra["id"] = 3; assets.append(extra)
            elif change == "release":
                releases[0]["tag_name"] = "0.3.1"
            else:
                key, value = {"digest": ("digest", None), "url": ("browser_download_url", "https://wrong"), "size": ("size", proof.LIMIT + 1)}[change]
                assets[0][key] = value
            with self.assertRaises(proof.IntegrityError):
                proof.selected_assets(releases, "0.3.0")

    def test_download_failure_or_digest_mismatch_is_integrity_failure(self):
        asset = self.releases()[0]["assets"][0]
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "bundle"
            for code, payload in [(1, b"data"), (0, b"evil"), (0, b"too long")]:
                def download(*args, **kwargs):
                    destination.write_bytes(payload)
                    return subprocess.CompletedProcess(args, code)
                with patch.object(proof.subprocess, "run", download), self.assertRaises(proof.IntegrityError):
                    proof.admitted_download(asset, destination)

    def test_duplicate_unsafe_or_nonregular_inventory_is_rejected(self):
        for names, kind in [(["main.roc", "main.roc"], tarfile.REGTYPE), (["../main.roc"], tarfile.REGTYPE), (["main.roc"], tarfile.SYMTYPE)]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w") as archive:
                for name in names:
                    member = tarfile.TarInfo(name); member.type = kind; member.size = 0
                    archive.addfile(member, io.BytesIO())
            with patch.object(proof, "bounded_output", return_value=data.getvalue()), self.assertRaises(proof.IntegrityError):
                proof.inventory(Path("unused"))

    def test_stale_cached_candidate_cannot_match_changed_tracked_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            previous = Path.cwd()
            try:
                os.chdir(temporary)
                Path("package").mkdir(); Path("package/main.roc").write_bytes(b"current")
                snapshot = {"package/main.roc": proof.sha(b"current")}
                with self.assertRaises(proof.IntegrityError):
                    proof.verify_fresh_inventory({"main.roc": (tarfile.REGTYPE, 0o644, b"stale")}, "package", snapshot)
                with self.assertRaises(proof.IntegrityError):
                    proof.verify_fresh_inventory({"Untracked.roc": (tarfile.REGTYPE, 0o644, b"stale")}, "package", snapshot)
            finally:
                os.chdir(previous)

    def test_versions_are_canonical_full_u64(self):
        self.assertEqual(proof.version("0.3.1"), (0, 3, 1))
        for value in ["00.3.1", "0.3.18446744073709551616", "0.3.1-rc1"]:
            with self.assertRaises(proof.IntegrityError):
                proof.version(value)

    def test_untracked_source_input_is_integrity_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            previous = Path.cwd()
            try:
                os.chdir(temporary)
                Path("package").mkdir(); Path("package-mermaid").mkdir()
                Path("package/main.roc").write_bytes(b"tracked")
                Path("package/Unexpected.roc").write_bytes(b"untracked")
                with patch.object(proof.subprocess, "check_output", return_value=b"package/main.roc\0"), self.assertRaises(proof.IntegrityError):
                    proof.tracked_snapshot()
            finally:
                os.chdir(previous)

    def test_build_deadline_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "descendant-survived"
            started = Path(temporary) / "descendant-started"
            child = "import time,pathlib; pathlib.Path(" + repr(str(started)) + ").write_text('started'); time.sleep(2); pathlib.Path(" + repr(str(marker)) + ").write_text('alive')"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]); time.sleep(10)"
            with self.assertRaises(proof.IntegrityError):
                proof.fresh_build([sys.executable, "-c", parent], os.environ.copy(), timeout=1)
            self.assertTrue(started.exists())
            time.sleep(1.3)
            self.assertFalse(marker.exists())

    def test_actual_producer_bytes_source_compiler_and_versions_are_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = root / "layout-Abc123.tar.zst"
            mermaid = root / "mermaid-Xyz123.tar.zst"
            layout.write_bytes(b"layout"); mermaid.write_bytes(b"mermaid")
            receipt = {"requested": "0.3.1", "previous": "0.3.0", "source_sha256": {"package/main.roc": "source"},
                       "compiler": "expected compiler", "fresh": {kind: {"name": path.name, "size": path.stat().st_size, "sha256": proof.sha(path.read_bytes())} for kind, path in [("layout", layout), ("mermaid", mermaid)]}}
            with patch.object(proof, "tracked_snapshot", return_value=receipt["source_sha256"]), patch.object(proof.subprocess, "check_output", return_value="expected compiler\n"):
                proof.bind_actual(root, receipt, "0.3.1", "0.3.0")
                for field, value in [("requested", "0.3.2"), ("previous", "0.2.0"), ("source_sha256", {}), ("compiler", "different")]:
                    modified = {**receipt, field: value}
                    with self.assertRaises(proof.IntegrityError):
                        proof.bind_actual(root, modified, "0.3.1", "0.3.0")
                layout.write_bytes(b"cached stale layout")
                with self.assertRaises(proof.IntegrityError):
                    proof.bind_actual(root, receipt, "0.3.1", "0.3.0")
                layout.unlink()
                with self.assertRaises(proof.IntegrityError):
                    proof.bind_actual(root, receipt, "0.3.1", "0.3.0")


if __name__ == "__main__":
    unittest.main()
