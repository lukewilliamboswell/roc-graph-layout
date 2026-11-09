"""Prove a later patch has identical package contents with one verified dependency rebind.

Exit 3 means fresh package contents changed: the ordinary API gate must run.
Integrity, admission and freshness failures exit 2 and must stop publication.
"""

import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

REPOSITORY = "lukewilliamboswell/roc-graph-layout"
PREFIX = f"https://github.com/{REPOSITORY}/releases/download/"
LIMIT = 32_000_000
NAME = re.compile(r"(layout|mermaid)-[1-9A-HJ-NP-Za-km-z]+\.tar\.zst\Z")


class IntegrityError(Exception):
    pass


class ContentsChanged(Exception):
    pass


def require(condition, message):
    if not condition:
        raise IntegrityError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def version(value):
    require(bool(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value)), "identity requires canonical final versions")
    parts = tuple(map(int, value.split(".")))
    require(all(p <= 2**64 - 1 for p in parts), "version exceeds U64")
    return parts


def selected_assets(releases, previous):
    finals = [r for r in releases if not r["draft"] and not r["prerelease"]]
    require(bool(finals) and finals[0]["tag_name"] == previous, "latest final release changed")
    release = finals[0]
    require(release["immutable"] and release["tag_name"] == previous, "previous release must be immutable")
    assets = release["assets"]
    require(len({a["name"] for a in assets}) == len(assets), "duplicate asset names")
    require(len({a["id"] for a in assets}) == len(assets), "duplicate asset identities")
    bundles = [a for a in assets if a["name"].endswith(".tar.zst")]
    require(len(bundles) == 2, "expected exactly two source bundles")
    result = {}
    for asset in bundles:
        matched = NAME.fullmatch(asset["name"])
        require(matched is not None, "invalid source bundle name")
        kind = matched[1]
        require(kind not in result, "ambiguous source bundle")
        require(type(asset["id"]) is int and 0 < asset["id"] <= 2**64 - 1, "invalid source asset ID")
        require(asset["browser_download_url"] == PREFIX + previous + "/" + asset["name"], "wrong source URL")
        require(isinstance(asset["size"], int) and 0 < asset["size"] <= LIMIT, "source size out of bounds")
        require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", asset.get("digest") or "")), "missing or invalid digest")
        result[kind] = asset
    require(set(result) == {"layout", "mermaid"}, "missing source bundle")
    return result


def bounded_api(command, maximum, seconds=60):
    # gh obtains authentication from its environment/store, never an argv token.
    environment = os.environ.copy()
    environment.pop("GH_DEBUG", None)
    process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    streams = {"stdout": bytearray(), "stderr": bytearray()}
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    deadline, reason = time.monotonic() + seconds, "exited"
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reason = "timeout"
                break
            for key, _ in selector.select(remaining):
                limit = maximum if key.data == "stdout" else 8192
                chunk = os.read(key.fileobj.fileno(), min(65536, max(1, limit - len(streams[key.data]) + 1)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                streams[key.data].extend(chunk)
                if len(streams[key.data]) > limit:
                    reason = key.data + "-limit"
                    break
            if reason != "exited":
                break
        if reason == "exited":
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                reason = "timeout"
        if reason != "exited":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return process.returncode, bytes(streams["stdout"]), bytes(streams["stderr"]), reason
    finally:
        # A child may leave descendants after closing both inherited pipes.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        selector.close()
        process.stdout.close()
        process.stderr.close()


def safe_error(stderr):
    text = stderr.decode(errors="replace")
    for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
        token = os.environ.get(name)
        if token:
            text = text.replace(token, "[REDACTED]")
    return json.dumps(text[:4096])


def admitted_download(asset, destination):
    require(type(asset["id"]) is int and 0 < asset["id"] <= 2**64 - 1, "invalid source asset ID")
    command = ["gh", "api", "--hostname", "github.com", "--method", "GET", "-H",
               "Accept: application/octet-stream", f"repos/{REPOSITORY}/releases/assets/{asset['id']}"]
    code, data, stderr, reason = bounded_api(command, asset["size"])
    require(code == 0 and reason == "exited",
            f"source asset API download failed: asset={asset['id']} reason={reason} code={code} stderr={safe_error(stderr)}")
    require(len(data) == asset["size"] and "sha256:" + sha(data) == asset["digest"], "download size/digest mismatch")
    destination.write_bytes(data)
    return data


def bounded_output(command, maximum):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    chunks, length, deadline = [], 0, time.monotonic() + 30
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "archive decoding timed out")
            if not selector.select(remaining):
                raise IntegrityError("archive decoding timed out")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            length += len(chunk)
            require(length <= maximum, "unpacked archive exceeds bound")
            chunks.append(chunk)
        require(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0, "archive decoding failed")
        return b"".join(chunks)
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        process.stdout.close()


def inventory(path):
    unpacked = bounded_output(["zstd", "--decompress", "--stdout", "--memory=64MB", str(path)], LIMIT)
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(unpacked), mode="r:") as archive:
        for member in archive:
            p = PurePosixPath(member.name)
            require(not p.is_absolute() and all(part not in (".", "..") for part in p.parts), "unsafe member path")
            require(str(p) == member.name and bool(re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", member.name)), "unexpected member name")
            require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not member.pax_headers and not member.linkname and 0 <= member.mode <= 0o777, "unexpected member type/mode")
            require(member.name not in entries and len(entries) < 1024 and member.size <= 4_000_000, "duplicate or oversized member")
            entries[member.name] = (member.type, member.mode, archive.extractfile(member).read())
    require("main.roc" in entries, "archive lacks main module")
    return entries


def rebind(source, old, new):
    require(source.startswith(b"package"), "not a package module")
    end = re.search(rb"(?m)^[ \t]*\}[ \t]*$", source)
    require(end is not None, "missing package header end")
    header = source[:end.end()]
    fields = list(re.finditer(rb'(?m)^[ \t]+layout: "([^"\r\n]+)",$', header))
    require(len(fields) == 1 and fields[0][1] == old.encode(), "wrong layout header field/URL")
    require(source.count(old.encode()) == 1, "layout URL must occur exactly once")
    field = fields[0]
    return source[:field.start(1)] + new.encode() + source[field.end(1):]


def tracked_snapshot():
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", "package", "package-mermaid"]).decode().split("\0")[:-1]
    require(bool(tracked), "no tracked package inputs")
    actual = {str(p) for directory in (Path("package"), Path("package-mermaid")) for p in directory.rglob("*") if not p.is_dir()}
    require(actual == set(tracked), "untracked package input")
    result = {}
    for name in tracked:
        path = Path(name)
        require(stat.S_ISREG(path.lstat().st_mode), "nonregular tracked input")
        result[name] = sha(path.read_bytes())
    return result


def verify_fresh_inventory(entries, directory, source_hashes, url=None):
    for name, (_, _, data) in entries.items():
        source = str(Path(directory) / name)
        require(source in source_hashes, "candidate contains an untracked member")
        current = Path(source).read_bytes()
        require(sha(current) == source_hashes[source], "source changed during proof")
        if directory == "package-mermaid" and name == "main.roc":
            current = rebind(current, "../package/main.roc", url)
        require(data == current, "candidate is stale or differs from fresh tracked source")


def fresh_build(command, environment, timeout=300):
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise IntegrityError("fresh candidate build timed out; process group terminated")
    require(process.returncode == 0, "fresh candidate bundling failed: " + stderr.decode(errors="replace"))
    return stdout


def compare(layout_old, layout_new, mermaid_old, mermaid_new, old_url, new_url, same_layout_name=False, same_mermaid_name=False):
    if layout_old != layout_new:
        require(not same_layout_name, "same layout name has different bytes")
        raise ContentsChanged("layout contents changed")
    if mermaid_old != mermaid_new and same_mermaid_name:
        raise IntegrityError("same Mermaid name has different bytes")
    if set(mermaid_old) != set(mermaid_new):
        raise ContentsChanged("Mermaid member inventory changed")
    for name, old in mermaid_old.items():
        new = mermaid_new[name]
        require(old[:2] == new[:2], "Mermaid member type/mode changed")
        expected = rebind(old[2], old_url, new_url) if name == "main.roc" else old[2]
        if name == "main.roc":
            rebind(new[2], new_url, old_url)
        if expected != new[2]:
            raise ContentsChanged(f"Mermaid payload changed: {name}")


def bind_actual(directory, receipt, requested, previous):
    require(receipt["requested"] == requested and receipt["previous"] == previous, "wrong proof versions")
    require(tracked_snapshot() == receipt["source_sha256"], "source changed after identity proof")
    require(subprocess.check_output(["roc", "version"], text=True).strip() == receipt["compiler"], "compiler changed after identity proof")
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "missing or unsafe actual candidate directory")
    actual = list(directory.glob("*.tar.zst"))
    expected = {record["name"]: record for record in receipt["fresh"].values()}
    require(len(actual) == 2 and {p.name for p in actual} == set(expected), "actual candidate inventory differs from proven fresh bundles")
    for path in actual:
        require(stat.S_ISREG(path.lstat().st_mode) and path.stat().st_size <= LIMIT, "nonregular or oversized actual candidate")
        data = path.read_bytes()
        require(len(data) == expected[path.name]["size"] and sha(data) == expected[path.name]["sha256"], "actual candidate bytes differ from fresh proof")


def candidate_environment(directory, requested):
    environment = {**os.environ, "OUTPUT_DIR": str(directory), "RELEASE_VERSION": requested}
    for credential in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG"]:
        environment.pop(credential, None)
    return environment


def main(requested, previous, actual_directory="dist"):
    new, old = version(requested), version(previous)
    if new[:2] != old[:2] or new[2] <= old[2]:
        raise ContentsChanged("identity proof only applies to a later patch")
    releases = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/releases?per_page=100"]))
    assets = selected_assets(releases, previous)
    before = tracked_snapshot()
    with tempfile.TemporaryDirectory(prefix="fresh-bundle-proof-") as temporary:
        root = Path(temporary)
        published = root / "published"
        published.mkdir()
        previous_bytes = {kind: admitted_download(asset, published / asset["name"]) for kind, asset in assets.items()}
        previous_inventory = {kind: inventory(published / asset["name"]) for kind, asset in assets.items()}
        candidate = root / "fresh"
        require(not candidate.exists(), "candidate output must be fresh")
        # Authenticated metadata admission finishes before candidate compilation.
        fresh_build(["blueprint", "run", "bundle"], candidate_environment(candidate, requested))
        require(tracked_snapshot() == before, "source snapshot changed while building")
        paths = list(candidate.iterdir())
        require(len(paths) == 2 and all(p.is_file() and not p.is_symlink() and p.stat().st_size <= LIMIT and NAME.fullmatch(p.name) for p in paths), "ambiguous candidate inventory")
        candidates = {NAME.fullmatch(p.name)[1]: p for p in paths}
        require(set(candidates) == {"layout", "mermaid"}, "missing candidate bundle")
        old_url = assets["layout"]["browser_download_url"]
        new_url = PREFIX + requested + "/" + candidates["layout"].name
        candidate_bytes = {kind: path.read_bytes() for kind, path in candidates.items()}
        fresh_inventory = {kind: inventory(path) for kind, path in candidates.items()}
        verify_fresh_inventory(fresh_inventory["layout"], "package", before)
        verify_fresh_inventory(fresh_inventory["mermaid"], "package-mermaid", before, new_url)
        compare(previous_bytes["layout"], candidate_bytes["layout"], previous_inventory["mermaid"], fresh_inventory["mermaid"], old_url, new_url,
                candidates["layout"].name == assets["layout"]["name"], candidates["mermaid"].name == assets["mermaid"]["name"])
        receipt = {"proof": "identical layout and Mermaid contents with verified layout dependency rebinding", "previous": previous, "requested": requested,
                   "source_sha256": before, "old_layout_url": old_url, "new_layout_url": new_url,
                   "compiler": subprocess.check_output(["roc", "version"], text=True).strip(),
                   "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                   "published": {kind: {key: asset[key] for key in ["id", "name", "size", "digest", "browser_download_url"]} for kind, asset in assets.items()},
                   "fresh": {kind: {"name": path.name, "sha256": sha(candidate_bytes[kind]), "size": len(candidate_bytes[kind])} for kind, path in candidates.items()}}
        bind_actual(actual_directory, receipt, requested, previous)
        receipt["actual_candidate_bound"] = True
        receipt["actual_candidate_directory"] = str(Path(actual_directory).resolve())
        print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except ContentsChanged as error:
        print(str(error), file=sys.stderr)
        sys.exit(3)
    except Exception as error:
        print(f"bundle identity integrity failure: {error}", file=sys.stderr)
        sys.exit(2)
