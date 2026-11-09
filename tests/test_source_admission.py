"""Fault tests for fixed source bytes and the absent-to-verified cache transition."""

from dataclasses import replace
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "admit_release_sources.py"
SPEC = importlib.util.spec_from_file_location("admit_release_sources", SCRIPT)
admission = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = admission
SPEC.loader.exec_module(admission)


def archive(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as stream:
        for name, data, kind, mode in entries:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.mode = mode
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                member.linkname = "main.roc"
            member.size = len(data) if kind == tarfile.REGTYPE else 0
            stream.addfile(member, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
    return output.getvalue()


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.payloads = {"main.roc": b"package [] {}\n", "fonts/font.ttf": b"font bytes"}
        self.members = tuple((name, len(data), admission.sha(data)) for name, data in self.payloads.items())
        self.tar = archive([(name, data, tarfile.REGTYPE, 0o644) for name, data in self.payloads.items()])
        self.raw = b"raw compressed fixture"
        self.source = admission.Source("fixture", "owner/repo", "1", 1, "Abc123", len(self.raw),
                                       admission.sha(self.raw), len(self.tar), admission.sha(self.tar), self.members)

    def write_tree(self, root):
        root.mkdir(mode=0o775)
        for name, data in self.payloads.items():
            path = root / name
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o600)

    def fake_process(self, command, maximum, seconds=65, cwd=None, environment=None):
        if command[0] == "curl":
            return self.raw
        if command[0] == "zstd":
            return self.tar
        self.assertEqual(command, ["/trusted/roc", "unbundle", self.source.archive_name])
        self.write_tree(Path(cwd) / self.source.content_hash)
        return b"Extracted\n"

    def mocks(self):
        # Synthetic bytes test individual transition boundaries without network
        # or multi-megabyte fixtures. Public descriptor rejection is tested below.
        self.enterContext(mock.patch.object(admission, "checked_source", side_effect=lambda value: value))
        self.enterContext(mock.patch.object(admission, "compiler_identity", return_value={
            "path": "/trusted/roc", "version": "Roc future nightly", "sha256": "0" * 64}))
        self.process = self.enterContext(mock.patch.object(admission, "run_bounded", side_effect=self.fake_process))

    def seed(self):
        return admission.seed(self.source, self.root / "raw", self.root / "cache")

    @property
    def packages(self):
        return self.root / "cache" / "roc" / "packages"

    def assert_unpublished(self):
        self.assertFalse(os.path.lexists(self.packages / self.source.content_hash))
        self.assertFalse(os.path.lexists(self.packages / (self.source.content_hash + ".deps")))
        self.assertFalse(list(self.packages.glob(".source-admission-*")))


class DescriptorTests(unittest.TestCase):
    def test_only_exact_descriptors_are_accepted(self):
        for source in admission.SOURCES.values():
            self.assertIs(admission.checked_source(source), source)
            for field, value in (("asset_id", source.asset_id + 1), ("size", source.size + 1),
                                 ("sha256", "0" * 64), ("repository", "other/repo"),
                                 ("tag", "unreviewed"),
                                 ("content_hash", "Other"), ("members", source.members[:-1]),
                                 ("role", "unreviewed")):
                with self.subTest(source=source.key, field=field), self.assertRaises(admission.AdmissionError):
                    admission.checked_source(replace(source, **{field: value}))

    def test_wrong_descriptor_is_rejected_before_io(self):
        with mock.patch.object(admission, "safe_directory") as mkdir, self.assertRaises(admission.AdmissionError):
            admission.seed(replace(admission.SOURCES["core"], asset_id=5), "/unused", "/unused")
        mkdir.assert_not_called()

    def test_inventory_counts_and_sizes(self):
        for name, count, content in (("core", 25, 511858), ("font", 35, 6655539),
                                     ("basic-cli", 207, 82833720), ("legacy-http", 5, 5991)):
            source = admission.SOURCES[name]
            self.assertEqual(len(source.members), count)
            self.assertEqual(sum(member[1] for member in source.members), content)

    def test_published_url_and_bare_unbundle_name_bind_to_same_fixed_source(self):
        for name, prefix, repository, tag in (
                ("core", "roc-blueprint-core-", "roc-blueprint", "0.12.0"),
                ("font", "", "roc-font", "0.1.0-rc2"),
                ("basic-cli", "", "basic-cli", "0.27.0"),
                ("legacy-http", "", "http", "1.0.0")):
            source = admission.SOURCES[name]
            self.assertEqual(source.published_asset_name, prefix + source.archive_name)
            owner = "roc-lang" if name in ("basic-cli", "legacy-http") else "lukewilliamboswell"
            self.assertEqual(source.canonical_url,
                             f"https://github.com/{owner}/{repository}/releases/download/{tag}/{prefix}{source.archive_name}")
            self.assertEqual(source.archive_name, source.content_hash + ".tar.zst")

    def test_platform_caps_and_native_inventory_do_not_increase_other_source_limits(self):
        platform = admission.SOURCES["basic-cli"]
        self.assertEqual((platform.size, platform.tar_size), (23399272, 83009024))
        native = [(name, size) for name, size, _ in platform.members if name.endswith((".a", ".o", ".lib"))]
        self.assertEqual(len(native), 12)
        self.assertEqual(sum(size for _, size in native), 80176552)
        self.assertEqual(max(size for _, size in native), 17848844)
        self.assertEqual(admission.SOURCES["core"].tar_size, 531968)
        self.assertEqual(admission.SOURCES["font"].tar_size, 6683136)
        self.assertEqual(admission.SOURCES["legacy-http"].tar_size, 10752)

    def test_legacy_input_cannot_claim_immutable_authority(self):
        source = admission.SOURCES["legacy-http"]
        self.assertEqual(source.role, "legacy-transitive")
        with self.assertRaises(admission.AdmissionError):
            admission.checked_source(replace(source, role="immutable-source"))
        parent = admission.SOURCES["basic-cli"]
        self.assertEqual(parent.role, "immutable-platform")
        self.assertEqual(next(digest for name, _, digest in parent.members if name == "main.roc"),
                         admission._BASIC_CLI_MAIN_SHA256)
        self.assertIn(admission.SOURCES["legacy-http"].canonical_url.encode(), admission._HTTP_EDGE)


class TarTests(Fixture):
    def inspect(self, entries):
        return admission.inspect_tar(archive(entries), self.members)

    def test_exact_inventory(self):
        self.assertEqual(admission.inspect_tar(self.tar, self.members), {
            "file_count": 2, "content_bytes": sum(map(len, self.payloads.values()))})

    def test_unsafe_paths(self):
        for path in ("/main.roc", "../main.roc", "x/../main.roc", "x\\main.roc", "./main.roc", "x//main.roc"):
            with self.subTest(path=path), self.assertRaises(admission.AdmissionError):
                self.inspect([(path, b"x", tarfile.REGTYPE, 0o644)])

    def test_links_directories_devices_and_fifos(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE, tarfile.CHRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind), self.assertRaises(admission.AdmissionError):
                self.inspect([("main.roc", b"", kind, 0o644)])

    def test_duplicate_and_extra(self):
        entries = [(name, data, tarfile.REGTYPE, 0o644) for name, data in self.payloads.items()]
        for extra in (entries[0], ("extra.roc", b"", tarfile.REGTYPE, 0o644)):
            with self.subTest(extra=extra[0]), self.assertRaises(admission.AdmissionError):
                self.inspect(entries + [extra])

    def test_pax_metadata_is_rejected_even_for_regular_member(self):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as stream:
            member = tarfile.TarInfo("main.roc")
            member.mode = 0o644
            member.size = len(self.payloads["main.roc"])
            member.pax_headers = {"comment": "unadmitted metadata"}
            stream.addfile(member, io.BytesIO(self.payloads["main.roc"]))
        with self.assertRaises(admission.AdmissionError):
            admission.inspect_tar(output.getvalue(), self.members)

    def test_missing_size_digest_and_mode(self):
        entries = [(name, data, tarfile.REGTYPE, 0o644) for name, data in self.payloads.items()]
        bad = [entries[:-1], [("main.roc", b"x", tarfile.REGTYPE, 0o644)],
               [("main.roc", b"X" * len(self.payloads["main.roc"]), tarfile.REGTYPE, 0o644)],
               [("main.roc", self.payloads["main.roc"], tarfile.REGTYPE, 0o755)]]
        for value in bad:
            with self.subTest(entries=value), self.assertRaises(admission.AdmissionError):
                self.inspect(value)

    def test_expanded_size_and_hash_are_bound_before_inventory(self):
        self.mocks()
        for data in (self.tar + b"x", b"X" + self.tar[1:]):
            with self.subTest(size=len(data)), mock.patch.object(admission, "run_bounded", return_value=data), \
                    self.assertRaises(admission.AdmissionError):
                admission.verify_archive(self.root / "archive", self.source)


class RawTests(Fixture):
    def test_prepare_anonymous_fixed_api_and_repeat_rehash(self):
        self.mocks()
        path = admission.prepare(self.source, self.root / "raw")
        command = self.process.call_args.args[0]
        self.assertEqual(command[:2], ["curl", "--disable"])
        self.assertIn("--no-netrc", command)
        self.assertEqual(command[-1], self.source.api_url)
        self.assertFalse(any("auth" in arg.lower() for arg in command))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.process.reset_mock()
        admission.prepare(self.source, self.root / "raw")
        self.process.assert_not_called()
        path.write_bytes(b"X" * self.source.size)
        with self.assertRaises(admission.AdmissionError):
            admission.prepare(self.source, self.root / "raw")
        self.process.assert_not_called()

    def test_download_wrong_size_and_digest_leave_no_raw(self):
        self.mocks()
        for data in (b"short", b"X" * self.source.size):
            with self.subTest(size=len(data)), mock.patch.object(admission, "run_bounded", return_value=data), \
                    self.assertRaises(admission.AdmissionError):
                admission.prepare(self.source, self.root / "raw")
            self.assertFalse(list((self.root / "raw").iterdir()))

    def test_raw_symlink_fifo_and_hardlink_rejected(self):
        self.mocks()
        target = self.root / "target"
        target.write_bytes(self.raw)
        path = self.root / "raw-input"
        path.symlink_to(target)
        with self.assertRaises(admission.AdmissionError):
            admission.verified_raw(path, self.source)
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(admission.AdmissionError):
            admission.verified_raw(path, self.source)
        path.unlink()
        os.link(target, path)
        with self.assertRaises(admission.AdmissionError):
            admission.verified_raw(path, self.source)


class TreeTests(Fixture):
    def setUp(self):
        super().setUp()
        self.tree = self.root / "tree"
        self.write_tree(self.tree)
        self.tree.chmod(0o700)

    def test_exact_private_tree(self):
        admission.verify_tree(self.tree, self.members)

    def test_postextract_corruption_missing_extra_and_mode(self):
        path = self.tree / "main.roc"
        path.write_bytes(b"X" * len(self.payloads["main.roc"]))
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)
        path.write_bytes(self.payloads["main.roc"])
        path.chmod(0o644)
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)
        path.unlink()
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)
        path.write_bytes(self.payloads["main.roc"])
        path.chmod(0o600)
        (self.tree / "invented.deps").write_bytes(b"data")
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)

    def test_tree_symlink_and_extra_directory(self):
        (self.tree / "fonts" / "font.ttf").unlink()
        (self.tree / "fonts" / "font.ttf").symlink_to(self.tree / "main.roc")
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)
        (self.tree / "fonts" / "font.ttf").unlink()
        (self.tree / "fonts" / "font.ttf").write_bytes(self.payloads["fonts/font.ttf"])
        (self.tree / "fonts" / "font.ttf").chmod(0o600)
        (self.tree / "unused").mkdir(mode=0o700)
        with self.assertRaises(admission.AdmissionError):
            admission.verify_tree(self.tree, self.members)


class TransitionTests(Fixture):
    def test_fresh_seed_preserves_xdg_home_artifact_store(self):
        self.mocks()
        xdg = self.root / "cache"
        store = xdg / "blueprint"
        store.mkdir(parents=True)
        (store / "verified-provider").write_bytes(b"retained")
        environment = {"XDG_CACHE_HOME": str(xdg), "HOME": str(self.root),
                       "ROC_CACHE_DIR": str(self.root / "ir"), "GH_TOKEN": "secret"}
        with mock.patch.dict(os.environ, environment):
            before = os.environ.copy()
            receipt = self.seed()
            self.assertEqual(os.environ, before)
        self.assertEqual((store / "verified-provider").read_bytes(), b"retained")
        self.assertFalse((self.root / "ir").exists())
        self.assertEqual(receipt["file_count"], 2)
        self.assertFalse(receipt["sidecar_created"])
        admission.verify_tree(self.packages / self.source.content_hash, self.members)
        self.assertEqual(sorted(path.name for path in self.packages.iterdir()), [self.source.content_hash])

    def test_existing_destination_sidecar_symlink_or_partial_is_never_touched(self):
        self.mocks()
        self.packages.mkdir(parents=True)
        destination = self.packages / self.source.content_hash
        sidecar = self.packages / (self.source.content_hash + ".deps")
        for path, kind in ((destination, "empty"), (destination, "partial"),
                           (destination, "symlink"), (sidecar, "file"), (sidecar, "symlink")):
            with self.subTest(path=path.name, kind=kind):
                if kind in ("empty", "partial"):
                    path.mkdir()
                    if kind == "partial":
                        (path / "main.roc").write_bytes(b"partial")
                elif kind == "symlink":
                    path.symlink_to(self.root / "missing")
                else:
                    path.write_bytes(b"cached deps")
                with self.assertRaises(admission.AdmissionError):
                    self.seed()
                self.assertTrue(os.path.lexists(path))
                self.process.assert_not_called()
                if path.is_dir() and not path.is_symlink():
                    import shutil
                    shutil.rmtree(path)
                else:
                    path.unlink()

    def test_unbundle_blake3_failure_leaves_no_final_slot(self):
        self.mocks()
        def fail(command, *args, **kwargs):
            if command[0] == "/trusted/roc":
                (Path(kwargs["cwd"]) / self.source.content_hash).mkdir()
                raise admission.AdmissionError("BLAKE3 mismatch")
            return self.fake_process(command, *args, **kwargs)
        self.process.side_effect = fail
        with self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assert_unpublished()

    def test_post_unbundle_changes_or_sidecar_never_publish(self):
        self.mocks()
        def corrupt(command, *args, **kwargs):
            result = self.fake_process(command, *args, **kwargs)
            if command[0] == "/trusted/roc":
                stage = Path(kwargs["cwd"])
                (stage / (self.source.content_hash + ".deps")).write_bytes(b"fake")
            return result
        self.process.side_effect = corrupt
        with self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assert_unpublished()

    def test_post_unbundle_content_mismatch_never_publishes(self):
        self.mocks()
        def corrupt(command, *args, **kwargs):
            result = self.fake_process(command, *args, **kwargs)
            if command[0] == "/trusted/roc":
                path = Path(kwargs["cwd"]) / self.source.content_hash / "main.roc"
                path.write_bytes(b"X" * len(self.payloads["main.roc"]))
            return result
        self.process.side_effect = corrupt
        with self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assert_unpublished()

    def test_atomic_failure_cleans_private_partial_only(self):
        self.mocks()
        admission.prepare(self.source, self.root / "raw")
        with mock.patch.object(admission, "atomic_insert", side_effect=admission.AdmissionError("atomic failure")), \
                self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assert_unpublished()
        self.assertEqual((self.root / "raw" / self.source.archive_name).read_bytes(), self.raw)

    def test_racing_destination_is_preserved_and_not_replaced(self):
        self.mocks()
        admission.prepare(self.source, self.root / "raw")
        original = admission.atomic_insert
        def race(source, destination):
            destination.mkdir()
            (destination / "racing-owner").write_bytes(b"keep")
            return original(source, destination)
        with mock.patch.object(admission, "atomic_insert", side_effect=race), self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assertEqual((self.packages / self.source.content_hash / "racing-owner").read_bytes(), b"keep")
        self.assertFalse(list(self.packages.glob(".source-admission-*")))

    def test_each_fresh_cache_unbundles_again(self):
        self.mocks()
        for index in range(2):
            admission.seed(self.source, self.root / "raw", self.root / f"cache-{index}")
        commands = [call.args[0] for call in self.process.call_args_list]
        self.assertEqual(sum(command[0] == "curl" for command in commands), 1)
        self.assertEqual(sum(command[0] == "/trusted/roc" for command in commands), 2)

    def test_implicit_raw_seed_and_scoped_raw_environment(self):
        self.mocks()
        with mock.patch.dict(os.environ, {}, clear=True):
            admission.seed(self.source, explicit_cache_root=self.root / "first")
        with mock.patch.dict(os.environ, {"GRAPH_RELEASE_SOURCES_DIR": str(self.root / "prepared")}):
            admission.seed(self.source, explicit_cache_root=self.root / "second")
        self.assertTrue((self.root / "prepared" / self.source.archive_name).is_file())


class LegacyParentTests(Fixture):
    def setUp(self):
        super().setUp()
        self.source = replace(self.source, key="legacy-http", role="legacy-transitive")
        self.parent_main = b'platform ""\n' + admission._BASIC_CLI_PACKAGES_BLOCK + b"\n"
        self.parent_payloads = {"main.roc": self.parent_main, "targets/x64musl/libhost.a": b"fixed host library"}
        self.parent_members = tuple((name, len(data), admission.sha(data)) for name, data in self.parent_payloads.items())
        self.parent_tar = archive([(name, data, tarfile.REGTYPE, 0o644) for name, data in self.parent_payloads.items()])
        self.parent_raw = b"fixed parent raw archive"
        self.parent = admission.Source("basic-cli", "roc-lang/basic-cli", "0.27.0", 720815853,
                                       "Parent123", len(self.parent_raw), admission.sha(self.parent_raw),
                                       len(self.parent_tar), admission.sha(self.parent_tar),
                                       self.parent_members, "immutable-platform")
        self.mocks()
        self.enterContext(mock.patch.object(admission, "SOURCES", {"basic-cli": self.parent, "legacy-http": self.source}))
        self.enterContext(mock.patch.object(admission, "_BASIC_CLI_MAIN_SHA256", admission.sha(self.parent_main)))
        self.process.side_effect = self.legacy_process

    def legacy_process(self, command, maximum, seconds=60, cwd=None, environment=None):
        if command[0] == "curl" and command[-1] == self.parent.api_url:
            return self.parent_raw
        if command[0] == "zstd" and Path(command[-1]).name == self.parent.archive_name:
            return self.parent_tar
        if command == ["/trusted/roc", "unbundle", self.parent.archive_name]:
            tree = Path(cwd) / self.parent.content_hash
            tree.mkdir(mode=0o700)
            for name, data in self.parent_payloads.items():
                path = tree / name
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                parent_directory = path.parent
                while parent_directory != tree:
                    parent_directory.chmod(0o700)
                    parent_directory = parent_directory.parent
                path.write_bytes(data)
                path.chmod(0o600)
            return b"Extracted parent\n"
        return self.fake_process(command, maximum, seconds, cwd, environment)

    def test_parent_bound_legacy_admission_and_no_cached_parent_tree_trust(self):
        self.packages.mkdir(parents=True)
        restored = self.packages / self.parent.content_hash
        restored.mkdir()
        (restored / "main.roc").write_bytes(b"untrusted restored parent")
        (self.packages / (self.parent.content_hash + ".deps")).write_bytes(b"untrusted sidecar")
        result = self.seed()
        self.assertEqual(result["authorization"], "legacy-transitive")
        self.assertFalse(result["upstream_release_immutable"])
        self.assertTrue(result["parent_edge_revalidated"])
        self.assertEqual((restored / "main.roc").read_bytes(), b"untrusted restored parent")
        commands = [call.args[0] for call in self.process.call_args_list]
        self.assertTrue(any(command[0] == "zstd" and Path(command[-1]).name == self.parent.archive_name for command in commands))

    def test_mutable_or_forged_immutable_metadata_cannot_replace_parent_raw(self):
        directory = self.root / "raw"
        directory.mkdir()
        for immutable in (False, True):
            (directory / "receipt.json").write_text(json.dumps({"immutable": immutable, "digest": self.parent.sha256}))
            (directory / self.parent.archive_name).write_bytes(b"X" * self.parent.size)
            with self.subTest(immutable=immutable), self.assertRaises(admission.AdmissionError):
                self.seed()
        self.process.assert_not_called()
        self.assert_unpublished()

    def test_missing_parent_cannot_be_satisfied_by_child_or_cached_receipt(self):
        directory = self.root / "raw"
        directory.mkdir()
        (directory / self.source.archive_name).write_bytes(self.raw)
        (directory / "receipt.json").write_text('{"immutable":true}')
        def fail(command, *args, **kwargs):
            if command[0] == "curl" and command[-1] == self.parent.api_url:
                raise admission.AdmissionError("parent unavailable")
            return self.legacy_process(command, *args, **kwargs)
        self.process.side_effect = fail
        with self.assertRaises(admission.AdmissionError):
            self.seed()
        self.assert_unpublished()

    def test_wrong_or_truncated_child_body_is_rejected_after_parent_check(self):
        directory = self.root / "raw"
        admission.prepare(self.parent, directory)
        for data in (b"X" * self.source.size, self.raw[:-1]):
            (directory / self.source.archive_name).write_bytes(data)
            with self.subTest(size=len(data)), self.assertRaises(admission.AdmissionError):
                self.seed()
        self.assert_unpublished()

    def test_parent_member_digest_missing_changed_or_unrelated_edge_rejected(self):
        candidates = [b"", self.parent_main.replace(admission._HTTP_EDGE, b""),
                      self.parent_main.replace(b"/1.0.0/", b"/2.0.0/"),
                      self.parent_main + b"# unrelated parent\n"]
        for main in candidates:
            with self.subTest(main=main), self.assertRaises(admission.AdmissionError):
                admission.check_legacy_parent_header(main)

    def test_sole_exact_edge_is_required_independently_of_member_digest(self):
        candidates = [self.parent_main.replace(b"/1.0.0/", b"/2.0.0/"),
                      self.parent_main + admission._BASIC_CLI_PACKAGES_BLOCK,
                      self.parent_main.replace(admission._HTTP_EDGE, admission._HTTP_EDGE + admission._HTTP_EDGE)]
        for main in candidates:
            with self.subTest(main=main), mock.patch.object(admission, "_BASIC_CLI_MAIN_SHA256", admission.sha(main)), \
                    self.assertRaises(admission.AdmissionError):
                admission.check_legacy_parent_header(main)

    def test_native_parent_swapped_oversized_missing_and_extra_target_rejected(self):
        entries = [(name, data, tarfile.REGTYPE, 0o644) for name, data in self.parent_payloads.items()]
        bad = [
            [entries[0], (entries[1][0], b"X" * len(entries[1][1]), tarfile.REGTYPE, 0o644)],
            [entries[0], (entries[1][0], entries[1][1] + b"x", tarfile.REGTYPE, 0o644)],
            entries[:-1],
            entries + [("targets/evil/libhost.a", b"new", tarfile.REGTYPE, 0o644)],
            [entries[0], (entries[1][0], b"", tarfile.SYMTYPE, 0o644)],
        ]
        for value in bad:
            with self.subTest(paths=[item[0] for item in value]), self.assertRaises(admission.AdmissionError):
                admission.inspect_tar(archive(value), self.parent_members)

    def test_parent_raw_is_rehashed_for_every_fresh_http_cache(self):
        self.seed()
        (self.root / "raw" / self.parent.archive_name).write_bytes(b"X" * self.parent.size)
        with self.assertRaises(admission.AdmissionError):
            admission.seed(self.source, self.root / "raw", self.root / "other-cache")
        self.assertFalse((self.root / "other-cache" / "roc" / "packages" / self.source.content_hash).exists())

    def test_multi_source_cli_shares_raw_bytes_but_unbundles_each_source(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("sys.stdout", new=io.StringIO()) as output:
            admission.main(["seed", "--source", "basic-cli", "--source", "legacy-http",
                            "--cache-root", str(self.root / "shared-cache")])
        receipts = json.loads(output.getvalue())["admitted_sources"]
        self.assertEqual([receipt["source"] for receipt in receipts], ["basic-cli", "legacy-http"])
        commands = [call.args[0] for call in self.process.call_args_list]
        self.assertEqual(sum(command[0] == "curl" and command[-1] == self.parent.api_url for command in commands), 1)


class ProcessAndPathTests(Fixture):
    def test_cache_path_matches_roc_and_ignores_ir_override(self):
        self.assertEqual(admission.cache_root(environment={"XDG_CACHE_HOME": "/cache", "ROC_CACHE_DIR": "/ir"}), Path("/cache"))
        self.assertEqual(admission.cache_root(environment={"HOME": "/home/user"}), Path("/home/user/.cache"))
        self.assertEqual(admission.cache_root("/explicit", {"XDG_CACHE_HOME": "/other"}), Path("/explicit"))
        for environment in ({}, {"XDG_CACHE_HOME": ""}, {"XDG_CACHE_HOME": "relative"}, {"HOME": "relative"}):
            with self.subTest(environment=environment), self.assertRaises(admission.AdmissionError):
                admission.cache_root(environment=environment)

    def test_cache_parent_symlink_fails(self):
        (self.root / "link").symlink_to(self.root)
        with self.assertRaises(admission.AdmissionError):
            admission.safe_directory(self.root / "link" / "cache")

    def test_only_exact_leading_darwin_system_alias_maps_to_same_physical_cache(self):
        physical = self.root / "private" / "var"
        physical.mkdir(parents=True)
        alias = self.root / "var"
        alias.symlink_to("private/var")
        aliases = ((alias, physical),)
        environment = {"XDG_CACHE_HOME": str(alias / "cache"), "HOME": str(self.root)}
        with mock.patch.object(admission.sys, "platform", "darwin"), \
                mock.patch.object(admission, "_DARWIN_ROOT_ALIASES", aliases), \
                mock.patch.dict(os.environ, environment):
            before = os.environ.copy()
            result = admission.safe_directory(admission.cache_root())
            self.assertEqual(result, physical / "cache")
            self.assertEqual(os.environ, before)
            self.assertTrue((alias / "cache").samefile(result))
            (physical / "cache" / "child").symlink_to(self.root)
            with self.assertRaises(admission.AdmissionError):
                admission.safe_directory(alias / "cache" / "child" / "new")
        # The same arbitrary alias is forbidden on Linux.
        with mock.patch.object(admission.sys, "platform", "linux"), self.assertRaises(admission.AdmissionError):
            admission.safe_directory(alias / "cache")

    def test_darwin_wrong_system_target_or_deep_alias_is_rejected(self):
        physical = self.root / "private" / "var"
        physical.mkdir(parents=True)
        alias = self.root / "var"
        alias.symlink_to(self.root)
        with mock.patch.object(admission.sys, "platform", "darwin"), \
                mock.patch.object(admission, "_DARWIN_ROOT_ALIASES", ((alias, physical),)):
            with self.assertRaises(admission.AdmissionError):
                admission.safe_directory(alias / "cache")
            alias.unlink()
            alias.mkdir()
            nested = alias / "nested"
            nested.symlink_to(physical)
            with self.assertRaises(admission.AdmissionError):
                admission.safe_directory(nested / "cache")

    def test_token_free_child_environment_preserves_cache_compiler(self):
        environment = {"GH_TOKEN": "secret", "GITHUB_TOKEN": "secret2", "GH_DEBUG": "api",
                       "GH_HOST": "evil", "GITHUB_ENTERPRISE_TOKEN": "secret3", "HOME": str(self.root),
                       "XDG_CACHE_HOME": "/cache", "ROC_CACHE_DIR": "/ir", "RA_COMPILER": "/compiler"}
        result = admission.run_bounded([sys.executable, "-c", "import os,json; print(json.dumps(dict(os.environ)))"],
                                       4096, environment=environment)
        child = json.loads(result)
        self.assertFalse(any(key.startswith(("GH_", "GITHUB_")) for key in child))
        for key in ("HOME", "XDG_CACHE_HOME", "ROC_CACHE_DIR", "RA_COMPILER"):
            self.assertEqual(child[key], environment[key])

    def test_real_child_stdout_stderr_bounds_and_timeout(self):
        commands = [("import os; os.write(1,b'x'*100)", 10, 2),
                    ("import os; os.write(2,b'x'*9000)", 10, 2),
                    ("import time; time.sleep(5)", 10, .05)]
        for code, maximum, seconds in commands:
            with self.subTest(code=code), self.assertRaises(admission.AdmissionError):
                admission.run_bounded([sys.executable, "-c", code], maximum, seconds)

    def test_failed_child_has_bounded_escaped_redacted_diagnostic(self):
        environment = {"GH_TOKEN": "never-print", "GITHUB_ENTERPRISE_TOKEN": "also-private"}
        code = "import os,sys; os.write(2,b'never-print\\nalso-private\\nfailed');sys.exit(22)"
        with self.assertRaises(admission.AdmissionError) as failure:
            admission.run_bounded([sys.executable, "-c", code], 10, environment=environment)
        message = str(failure.exception)
        self.assertIn("reason=exit code=22", message)
        self.assertIn("[REDACTED]\\n[REDACTED]\\nfailed", message)
        self.assertNotIn("never-print", message)
        self.assertNotIn("also-private", message)
        self.assertNotIn("\n", message)
        self.assertLess(len(admission.safe_diagnostic(b"x" * 9000)), 2100)

    def test_atomic_insert_does_not_replace_existing_empty_directory(self):
        source, destination = self.root / "source", self.root / "destination"
        source.mkdir()
        destination.mkdir()
        with self.assertRaises(admission.AdmissionError):
            admission.atomic_insert(source, destination)
        self.assertTrue(source.is_dir())
        self.assertTrue(destination.is_dir())

    def test_current_hook_compiler_is_recorded_without_fixed_nightly_guard(self):
        with mock.patch.object(admission, "run_bounded", return_value=b"Roc compiler version future-latest\n") as run:
            identity = admission.compiler_identity({"RA_COMPILER": sys.executable, "PATH": "/unused"})
        self.assertEqual(identity["path"], str(Path(sys.executable).resolve()))
        self.assertEqual(identity["version"], "Roc compiler version future-latest")
        self.assertEqual(len(identity["sha256"]), 64)
        self.assertEqual(run.call_args.args[0], [identity["path"], "version"])


if __name__ == "__main__":
    unittest.main()
