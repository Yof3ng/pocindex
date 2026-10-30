#!/usr/bin/env python3
"""Serve the generated PoC Index site with GitHub-Pages-style clean URLs.

GitHub Pages resolves /CVE-2021-44228 to /CVE-2021-44228.html. Python's stock
http.server does not, so CVE links from the homepage otherwise return 404 in a
local Docker deployment. This server only serves files below --directory and
never generates directory listings.
"""

from __future__ import annotations

import argparse
import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit, urlunsplit


class PoCIndexHandler(SimpleHTTPRequestHandler):
    server_version = "PoCIndexLocal"
    sys_version = ""

    def version_string(self):
        return self.server_version

    def send_head(self):
        parts = urlsplit(self.path)
        requested = unquote(parts.path)

        # The generated site never needs dotfiles or parent traversal.
        if any(part.startswith(".") for part in requested.split("/") if part):
            self.send_error(404)
            return None

        target = Path(self.translate_path(requested))
        if not requested.endswith("/") and not target.exists():
            html_target = target.with_name(target.name + ".html")
            if html_target.is_file():
                self.path = urlunsplit(("", "", parts.path + ".html", parts.query, ""))

        return super().send_head()

    def list_directory(self, path):
        self.send_error(404)
        return None

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Permissions-Policy", "camera=(), geolocation=(), microphone=()")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def parse_args() -> argparse.Namespace:
    default_docs = Path(__file__).resolve().parents[1] / "docs"
    parser = argparse.ArgumentParser(description="Serve a generated PoC Index site")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="port (default: 8765)")
    parser.add_argument("--directory", type=Path, default=default_docs,
                        help="directory containing index.html and generated data")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    directory = args.directory.expanduser().resolve()
    if not (directory / "index.html").is_file():
        print(
            f"error: {directory}/index.html is missing; build the site first\n"
            "hint: docker compose -f compose.yaml -f compose.build.yaml build",
            file=sys.stderr,
        )
        return 2

    handler = partial(PoCIndexHandler, directory=str(directory))
    server = Server((args.host, args.port), handler)
    print(f"PoC Index: http://{args.host}:{args.port}/", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
