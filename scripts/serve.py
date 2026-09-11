#!/usr/bin/env python3
"""Serve a generated site for local browser QA."""

from argparse import ArgumentParser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parents[1] / "dist/site")
    args = parser.parse_args()

    root = args.directory.resolve()
    if not (root / "index.html").is_file():
        parser.error(f"No generated site at {root}; run scripts/build_site.py first")
    handler = partial(SimpleHTTPRequestHandler, directory=root)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"Serving site at http://{args.bind}:{args.port}/")
    print("Press Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
