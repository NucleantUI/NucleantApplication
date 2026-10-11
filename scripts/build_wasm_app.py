#!/usr/bin/env python3
"""Build a NucleantApplication app for WebAssembly and lay it out as a web page.

    python3 scripts/build_wasm_app.py WasmProbe [--release] [--serve] [--output DIR]
    python3 scripts/build_wasm_app.py Flashcards --package-path ../NucleantUI/Examples/Flashcards --serve

`--package-path` builds an executable product of another package — any app
built on NucleantApplication, a NucleantUI app included; the default is
this package.

The product is built with the wasm Swift SDK as a WASI *reactor* — the
browser owns the event loop, so `main` (setup, run, onStart) is an exported
function the page calls once, and the module then lives on, called per
display refresh and per input event (see Web/nucleant-app.js). The page
directory gets:

    <Product>.wasm        the app
    index.html            Web/index.html with the product filled in
    nucleant-app.js       the page runtime: DOM windows, input, frame loop
    nucleant-webgpu.js    NucleantVulkan's WebGPU bridge (its Vulkan on wasm)
    nucleant-wgpu.js      the same bridge's webgpu.h (ThorVG's wg engine)
    nucleant-wasi.js      WASI for the Swift runtime
    naga_webgpu.wasm      SPIR-V -> WGSL for pipeline creation
    resources/            the products' resource bundles (<Target>.resources),
    resources.json        and their list — the page mounts them read-only at
                          /app in the module's file system and sets
                          NUCLEANT_APP_PATH=/app, as an Android app's
                          Activity does with the bundles it unpacks; and
                          again at the directory they were built in,
                          where `Bundle.module` looks for them
    zoneinfo.bin          the time zone database, from this machine's
                          /usr/share/zoneinfo — the page mounts it there,
                          where Foundation reads named zones (see
                          pack_zoneinfo)

--serve then serves it on http://127.0.0.1 (WebGPU needs a secure context,
which localhost is). Open it in a browser with WebGPU — Chrome/Edge 113+,
Safari 26+, Firefox 141+ (Windows); blocking Vulkan waits additionally use
JSPI (Chrome 137+).

Needs the wasm Swift SDK with its matching toolchain, and NucleantVulkan's
Web/naga_webgpu.wasm (NucleantVulkan/scripts/build_naga_wasm.py).
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")

# What a reactor build needs: no _start, an exported main. Given as a
# toolset, which applies to the wasm build only — `-Xswiftc`/`-Xlinker` also
# reach the host build of any macro or plugin in the graph (NucleantUI's
# `@View`), whose linker rejects `--export`.
#
# The stack: wasm-ld's default is 64 KB, placed after the data and growing
# down into it, so a deep call chain (a view tree built in a debug build)
# silently overwrites type metadata and fails somewhere else entirely. 8 MB,
# a desktop main thread's size.
STACK_SIZE = 8 * 1024 * 1024
REACTOR_TOOLSET = {
    "schemaVersion": "1.0",
    "swiftCompiler": {"extraCLIOptions": ["-Xclang-linker", "-mexec-model=reactor"]},
    "linker": {"extraCLIOptions": ["--export=__main_argc_argv", "-z", f"stack-size={STACK_SIZE}"]},
}
# Where the page mounts the resource bundles in the module's file system.
RESOURCES_ROOT = "/app"
NUCLEANT_VULKAN_WEB = ["nucleant-webgpu.js", "nucleant-wgpu.js", "nucleant-wasi.js", "naga_webgpu.wasm"]
ZONEINFO = Path("/usr/share/zoneinfo")
# Source text and leap-second tables, and Debian's posix/ and right/ copies
# of every zone: nothing in Foundation reads them.
ZONEINFO_SKIPPED = {"tzdata.zi", "leapseconds", "leap-seconds.list", "posix", "right"}


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
    sys.exit("error: no wasm Swift SDK with a matching toolchain found "
             "(https://www.swift.org/documentation/articles/wasm-getting-started.html)")


def nucleant_vulkan_web(scratch: Path) -> Path:
    """NucleantVulkan's Web/ — the sibling checkout in a development tree, else SwiftPM's."""
    for candidate in (PACKAGE_ROOT.parent / "NucleantVulkan" / "Web", scratch / "checkouts" / "NucleantVulkan" / "Web"):
        if (candidate / "nucleant-webgpu.js").is_file():
            return candidate
    sys.exit("error: NucleantVulkan's Web/ directory not found")


def build(package: Path, product: str, release: bool) -> Path:
    """Builds `product` of `package`; returns the products directory."""
    swift, sdk = find_wasm_sdk()
    scratch = package / ".build" / "wasm"
    configuration = "release" if release else "debug"
    toolset = json.loads(json.dumps(REACTOR_TOOLSET))
    if release:
        toolset["linker"]["extraCLIOptions"].append("--strip-debug")
    scratch.mkdir(parents=True, exist_ok=True)
    toolset_path = scratch / f"reactor-toolset-{configuration}.json"
    toolset_path.write_text(json.dumps(toolset, indent=2))
    command = [swift, "build", "--swift-sdk", sdk, "--toolset", str(toolset_path), "--scratch-path", str(scratch),
               "--product", product, "-c", configuration]
    print("+", " ".join(command), flush=True)
    env = dict(os.environ, WASM_BUILD="1")
    if subprocess.run(command, cwd=package, env=env).returncode != 0:
        sys.exit("error: the wasm build failed")
    products = scratch / configuration
    if not (products / f"{product}.wasm").is_file():
        sys.exit(f"error: expected {products / f'{product}.wasm'}")
    return products


def copy_resources(products: Path, output: Path) -> None:
    """The products' `<Target>.resources` bundles into resources/, listed in resources.json.

    The page mounts them at RESOURCES_ROOT, and again at `buildRoot`, the
    directory they were built in: SwiftPM's generated `Bundle.module`
    accessor for wasm looks for its bundle only at absolute paths on the
    machine that built the module, the build directory among them.
    """
    destination = output / "resources"
    if destination.exists():
        shutil.rmtree(destination)
    files: list[str] = []
    for bundle in sorted(products.glob("*.resources")):
        if not bundle.is_dir():
            continue
        shutil.copytree(bundle, destination / bundle.name)
        files += sorted(p.relative_to(destination).as_posix() for p in (destination / bundle.name).rglob("*") if p.is_file())
    manifest = {"root": RESOURCES_ROOT, "buildRoot": str(products.resolve()), "base": "resources/", "files": files}
    (output / "resources.json").write_text(json.dumps(manifest, indent=2) + "\n")


def pack_zoneinfo(source: Path = ZONEINFO) -> bytes | None:
    """This machine's time zone database as one file, or None if it has none.

    Foundation's CFTimeZone reads a named zone ("Europe/Lisbon") from
    /usr/share/zoneinfo/<name>, on WASI as on Linux; the browser has no such
    directory, so formatting a date in any named zone but UTC traps. The
    page mounts these files there (Web/nucleant-app.js, loadZoneinfo).

    One record per file, little-endian: u16 path length, the path relative
    to zoneinfo/ (UTF-8), u32 size, the bytes.
    """
    root = source.resolve()
    if not root.is_dir():
        return None
    packed = bytearray()
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(d for d in subdirectories if d not in ZONEINFO_SKIPPED)
        for name in sorted(names):
            path = Path(directory) / name
            if name in ZONEINFO_SKIPPED or not path.is_file():
                continue
            relative = path.relative_to(root).as_posix().encode()
            data = path.read_bytes()
            packed += struct.pack("<H", len(relative)) + relative + struct.pack("<I", len(data)) + data
    return bytes(packed)


def write_zoneinfo(output: Path) -> None:
    target = output / "zoneinfo.bin"
    packed = pack_zoneinfo()
    if packed is None:
        target.unlink(missing_ok=True)
        print(f"warning: no {ZONEINFO} here — in the page, formatting a date in a named time zone will trap", flush=True)
        return
    target.write_bytes(packed)


def lay_out(product: str, products: Path, output: Path) -> None:
    built = products / f"{product}.wasm"
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, output / f"{product}.wasm")
    web = PACKAGE_ROOT / "Web"
    shutil.copy2(web / "nucleant-app.js", output / "nucleant-app.js")
    page = (web / "index.html").read_text().replace("{{PRODUCT}}", product)
    (output / "index.html").write_text(page)
    vulkan_web = nucleant_vulkan_web(products.parent)
    for name in NUCLEANT_VULKAN_WEB:
        source = vulkan_web / name
        if not source.is_file():
            sys.exit(f"error: {source} is missing (NucleantVulkan/scripts/build_naga_wasm.py builds naga_webgpu.wasm)")
        shutil.copy2(source, output / name)
    copy_resources(products, output)
    write_zoneinfo(output)
    size = (output / f"{product}.wasm").stat().st_size / 1e6
    print(f"wrote {output} ({product}.wasm {size:.1f} MB)", flush=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def serve(directory: Path, port: int) -> None:
    handler = functools.partial(Handler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"serving http://127.0.0.1:{server.server_address[1]}/  (Ctrl-C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("product", help="executable product to build, e.g. WasmProbe")
    parser.add_argument("--package-path", type=Path, default=PACKAGE_ROOT,
                        help="the package the product is in (default: NucleantApplication)")
    parser.add_argument("--release", action="store_true", help="optimised build without debug info")
    parser.add_argument("--output", type=Path, help="page directory (default .build/wasm-app/<product>)")
    parser.add_argument("--serve", action="store_true", help="serve the page afterwards")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args(argv)

    package = args.package_path.resolve()
    products = build(package, args.product, args.release)
    output = (args.output or package / ".build" / "wasm-app" / args.product).resolve()
    lay_out(args.product, products, output)
    if args.serve:
        serve(output, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
