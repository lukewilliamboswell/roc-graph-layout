#!/usr/bin/env python3
"""Build static guides, the Signals playground, and API docs as one Pages tree."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.request import urlopen
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = ("signals.mjs", "wasm_memory_views.mjs", "controlled_input_policy.mjs")
SIGNALS_VERSION = "0.2.0-rc3"
SIGNALS_EXAMPLES_URL = (
    "https://github.com/lukewilliamboswell/roc-signals/releases/download/"
    f"{SIGNALS_VERSION}/signals-examples.zip"
)
SIGNALS_EXAMPLES_SHA256 = "a67827d639acd5030e81ac390adba1835157410a0a51de5f01e53302fca7e793"


def run(*args: str, env: dict[str, str] | None = None) -> None:
    print("+", *args, flush=True)
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def read_header_value(source: str, field: str) -> str:
    match = re.search(rf'\b{re.escape(field)}:\s*(?:platform\s*)?"([^"]+)"', source)
    if match is None:
        raise ValueError(f"playground source has no {field} declaration")
    return match.group(1)


def fetch_signals_runtime(destination: Path) -> None:
    print(f"+ download {SIGNALS_EXAMPLES_URL}", flush=True)
    with urlopen(SIGNALS_EXAMPLES_URL, timeout=60) as response:
        archive = response.read()
    actual = hashlib.sha256(archive).hexdigest()
    if actual != SIGNALS_EXAMPLES_SHA256:
        raise ValueError(
            f"roc-signals examples digest mismatch: expected {SIGNALS_EXAMPLES_SHA256}, got {actual}"
        )
    with tempfile.TemporaryDirectory(prefix="signals-runtime-") as extracted:
        archive_path = Path(extracted) / "signals-examples.zip"
        archive_path.write_bytes(archive)
        with ZipFile(archive_path) as bundle:
            for name in RUNTIME_FILES:
                member = f"browser/{name}"
                destination.joinpath(name).write_bytes(bundle.read(member))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    parser.add_argument("--playground-roc", default=os.environ.get("PLAYGROUND_ROC"))
    parser.add_argument("--output", type=Path, default=ROOT / "dist/site")
    parser.add_argument("--version", default="dev")
    parser.add_argument("--base-path", default="/roc-graph-layout")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.version):
        parser.error("version must be a single URL-safe path component")
    if not re.fullmatch(r"(?:/[A-Za-z0-9_-]+)*", args.base_path):
        parser.error("base-path must be empty or a slash-prefixed project path without a trailing slash")
    output = args.output.resolve()
    if output.exists():
        parser.error(f"output already exists: {output}; choose a fresh directory")
    app_source = (ROOT / "playground/app.roc").read_text()
    package_source = (ROOT / "package/main.roc").read_text()
    try:
        playground_roc_pin = read_header_value(app_source, "roc")
        package_roc_pin = read_header_value(package_source, "roc")
        signals_platform = read_header_value(app_source, "pf")
    except ValueError as error:
        parser.error(str(error))
    playground_roc = args.playground_roc or args.roc
    actual_package_roc = subprocess.check_output([args.roc, "--version"], text=True).strip()
    if actual_package_roc != f"Roc compiler version {package_roc_pin}":
        parser.error(f"package compiler mismatch: expected {package_roc_pin}, got {actual_package_roc}")
    actual_playground_roc = subprocess.check_output([playground_roc, "--version"], text=True).strip()
    if actual_playground_roc != f"Roc compiler version {playground_roc_pin}":
        parser.error(
            f"playground compiler mismatch: expected {playground_roc_pin}, got {actual_playground_roc}"
        )

    expected_platform = (
        "https://github.com/lukewilliamboswell/roc-signals/releases/download/"
        f"{SIGNALS_VERSION}/HVTvH6n1bcFccyLz5xtdpjRrStMa2T6CmHQRiuTtTs6F.tar.zst"
    )
    if signals_platform != expected_platform:
        parser.error(f"playground must use the reviewed roc-signals {SIGNALS_VERSION} web archive")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".graph-site-", dir=output.parent) as scratch:
        work = Path(scratch)
        site = work / "site"
        site.mkdir()
        generator = work / "site-generator"
        run(args.roc, "build", "site/main.roc", f"--output={generator}")
        run(str(generator), str(ROOT / "site/content"), str(site))
        shutil.copytree(ROOT / "site/public", site, dirs_exist_ok=True)
        (site / "assets").mkdir()
        shutil.copy2(ROOT / "examples/build_pipeline/output.svg", site / "assets/build-pipeline.svg")

        playground = site / "playground"
        playground.mkdir()
        wasm = playground / "app.wasm"
        # Roc extracts only the selected target from this multi-target package.
        # Keep the browser extraction isolated from native spec builds that may
        # use the same package hash in the user's default cache.
        playground_env = {**os.environ, "ROC_CACHE_DIR": str(work / "roc-cache-wasm")}
        run(
            playground_roc,
            "build",
            "playground/app.roc",
            "--opt=size",
            f"--output={wasm}",
            env=playground_env,
        )
        run("node", "-e", "WebAssembly.compile(require('fs').readFileSync(process.argv[1])).catch(e=>{console.error(e);process.exitCode=1})", str(wasm))
        shutil.copy2(ROOT / "site/playground.html", playground / "index.html")
        shutil.copy2(ROOT / "playground/www/style.css", playground / "style.css")
        fetch_signals_runtime(playground)

        docs = site / "docs" / args.version
        env = {**os.environ, "ROC_DOCS_URL_ROOT": f"{args.base_path}/docs/{args.version}"}
        run(args.roc, "docs", "package/main.roc", f"--output={docs}", env=env)
        (site / "docs/index.html").write_text(
            f'<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=./{args.version}/">'
            f'<title>API reference</title><a href="./{args.version}/">API reference {args.version}</a>\n'
        )
        (site / ".nojekyll").touch()
        (site / "build-info.json").write_text(json.dumps({
            "version": args.version,
            "base_path": args.base_path,
            "package_roc_pin": package_roc_pin,
            "playground_roc_pin": playground_roc_pin,
            "signals_version": SIGNALS_VERSION,
            "signals_platform": signals_platform,
            "signals_examples_sha256": SIGNALS_EXAMPLES_SHA256,
        }, indent=2) + "\n")
        # Publish only after every compiler invocation and Wasm validation passes.
        site.rename(output)
    print(f"Built site: {output}")


if __name__ == "__main__":
    main()
