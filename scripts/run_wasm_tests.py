#!/usr/bin/env python3
"""Build NucleantApplication's tests for WebAssembly and run them in headless Chrome.

Platform_Wasm needs a page: its windows are <canvas> elements and its frame
loop is requestAnimationFrame. This builds the test product with the wasm
Swift SDK, serves it over http://127.0.0.1 together with the page runtime —
Web/ here, plus NucleantVulkan's Web/ files (the WebGPU bridge, WASI, naga),
which the page finds next to nucleant-app.js exactly as in a built app — and
runs Web/test/index.html in headless Chrome, relaying the test output.

    python3 scripts/run_wasm_tests.py [--chrome PATH] [-- <test arguments>]

Chrome: --chrome, else $CHROME, else the usual install locations (any Chrome
with WebGPU and JSPI, i.e. 137+; Chrome for Testing works).
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from pathlib import Path

from build_wasm_app import pack_zoneinfo

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
SCRATCH = PACKAGE_ROOT / ".build" / "wasm"
VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")
NUCLEANT_VULKAN_WEB = {"nucleant-webgpu.js", "nucleant-wgpu.js", "nucleant-wasi.js", "naga_webgpu.wasm"}

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
]


def find_wasm_sdk() -> tuple[str, str]:
    """(swift executable, SDK id) for the newest installed *_wasm SDK whose toolchain exists."""
    roots = [Path.home() / "Library" / "org.swift.swiftpm" / "swift-sdks", Path.home() / ".swiftpm" / "swift-sdks"]
    for root in roots:
        for bundle in sorted(root.glob("*_wasm.artifactbundle"), reverse=True):
            sdk = bundle.name.removesuffix(".artifactbundle")
            version = VERSION_RE.search(sdk).group(1)
            for base in (Path.home() / "Library" / "Developer" / "Toolchains", Path("/Library/Developer/Toolchains")):
                swift = base / f"swift-{version}-RELEASE.xctoolchain" / "usr" / "bin" / "swift"
                if swift.is_file():
                    return str(swift), sdk
    sys.exit("error: no wasm Swift SDK with a matching toolchain found")


def find_chrome(explicit: str | None) -> str:
    for candidate in [explicit, os.environ.get("CHROME"), *CHROME_CANDIDATES]:
        if candidate and Path(candidate).is_file():
            return candidate
    sys.exit("error: no Chrome found; pass --chrome PATH or set CHROME")


def nucleant_vulkan_web() -> Path:
    for candidate in (PACKAGE_ROOT.parent / "NucleantVulkan" / "Web", SCRATCH / "checkouts" / "NucleantVulkan" / "Web"):
        if (candidate / "nucleant-webgpu.js").is_file():
            return candidate
    sys.exit("error: NucleantVulkan's Web/ directory not found")


def build_tests() -> Path:
    swift, sdk = find_wasm_sdk()
    env = dict(os.environ, WASM_BUILD="1")
    command = [swift, "build", "--build-tests", "--swift-sdk", sdk, "--scratch-path", str(SCRATCH)]
    print("+", " ".join(command), flush=True)
    if subprocess.run(command, cwd=PACKAGE_ROOT, env=env).returncode != 0:
        sys.exit("error: building the tests for wasm failed")
    product = SCRATCH / "debug" / "NucleantApplicationPackageTests.xctest"
    if not product.is_file():
        sys.exit(f"error: expected {product}")
    return product


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the package, NucleantVulkan's web files under /Web/, and the page's reports."""

    vulkan_web: Path
    # zoneinfo.bin, packed as build_wasm_app.py packs it for an app's page.
    zoneinfo: Path | None = None
    done = threading.Event()
    status = 1

    def translate_path(self, path):
        name = urllib.parse.urlparse(path).path
        if name == "/zoneinfo.bin" and self.zoneinfo:
            return str(self.zoneinfo)
        if name.startswith("/Web/") and name[len("/Web/"):] in NUCLEANT_VULKAN_WEB:
            return str(self.vulkan_web / name[len("/Web/"):])
        return super().translate_path(path)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if self.path == "/log":
            print(body, flush=True)
        elif self.path == "/done":
            Handler.status = int(body or 1)
            Handler.done.set()
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--chrome", help="Chrome executable")
    parser.add_argument("--timeout", type=float, default=300, help="seconds before giving up")
    parser.add_argument("--headed", action="store_true", help="show the browser window")
    parser.add_argument("test_args", nargs="*", help="arguments for the test runner (after --)")
    args = parser.parse_args(argv)

    chrome = find_chrome(args.chrome)
    Handler.vulkan_web = nucleant_vulkan_web()
    product = build_tests()

    profile = tempfile.mkdtemp(prefix="nucleant-app-wasm-tests-")
    packed = pack_zoneinfo()
    if packed is not None:
        Handler.zoneinfo = Path(profile) / "zoneinfo.bin"
        Handler.zoneinfo.write_bytes(packed)

    handler = functools.partial(Handler, directory=str(PACKAGE_ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    query = urllib.parse.urlencode({
        "wasm": "/" + product.relative_to(PACKAGE_ROOT).as_posix(),
        # The tests are Swift Testing; SwiftPM's runner defaults to XCTest.
        "args": json.dumps(["--testing-library", "swift-testing", *args.test_args]),
        **({"zoneinfo": "/zoneinfo.bin"} if Handler.zoneinfo else {}),
    })
    url = f"http://127.0.0.1:{server.server_address[1]}/Web/test/index.html?{query}"
    print(f"[run_wasm_tests] {url}", flush=True)

    # A dark page (prefers-color-scheme), whatever the machine's own setting:
    # the appearance tests expect the app to see dark at launch.
    command = [chrome, f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
               "--enable-unsafe-webgpu", "--blink-settings=preferredColorScheme=0", "--remote-debugging-port=0", url]
    if not args.headed:
        command.insert(1, "--headless=new")
    browser = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        finished = Handler.done.wait(args.timeout)
    finally:
        browser.terminate()
        try:
            browser.wait(10)
        except subprocess.TimeoutExpired:
            browser.kill()
        server.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
    if not finished:
        print(f"[run_wasm_tests] timed out after {args.timeout:.0f}s", flush=True)
        return 1
    print(f"[run_wasm_tests] exit status {Handler.status}", flush=True)
    return Handler.status


if __name__ == "__main__":
    sys.exit(main())
