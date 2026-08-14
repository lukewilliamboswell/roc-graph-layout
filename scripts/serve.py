#!/usr/bin/env python3
"""Serve the vendored playground for local browser QA."""

from argparse import ArgumentParser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1] / "playground" / "www"
    handler = partial(SimpleHTTPRequestHandler, directory=root)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"Serving playground at http://{args.bind}:{args.port}/")
    print("Press Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
