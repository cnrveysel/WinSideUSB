#!/usr/bin/env python3
"""Compile and exercise the production iPad BSD listener on Linux/macOS.

Only the platform-independent listener is extracted; this tests the same socket
implementation shipped to iPad rather than a copy or a mock of its behavior.
Requires Python 3 and a Swift compiler (the Windows wrapper uses WSL).
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swiftc", help="Swift compiler executable")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    source_path = repo / "WinSideUSB" / "swiftclientcode.swift"
    source = source_path.read_text(encoding="utf-8-sig")
    native_path = repo / "iPadClient" / "Sources" / "WinSideUSBClient" / "App.swift"
    native_source = native_path.read_text(encoding="utf-8-sig")
    if source != native_source:
        raise SystemExit(
            "iPad sources differ: the native app would ship different code from the "
            "Playgrounds/setup client. Run scripts/Sync-iPadClient.ps1 before testing or building."
        )
    start_marker = "// MARK: - Recoverable BSD listener"
    end_marker = "// MARK: - VideoReceiver"
    if start_marker not in source or end_marker not in source:
        raise SystemExit("Production BSD listener markers are missing; refusing to test a substitute.")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    transport = source[start:end]
    if "class BSDVideoListener" not in transport:
        raise SystemExit("Production BSDVideoListener was not found between extraction markers.")
    imports = """import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif

"""
    compiler = shutil.which(args.swift)
    if not compiler:
        raise SystemExit("Swift compiler not found. Install Swift or pass --swift /path/to/swiftc.")
    with tempfile.TemporaryDirectory(prefix="winsideusb-ipad-tests-") as temp:
        temp_dir = Path(temp)
        extracted = temp_dir / "BSDVideoListener.swift"
        extracted.write_text(imports + transport, encoding="utf-8")
        entry = temp_dir / "main.swift"
        shutil.copyfile(repo / "tests" / "iPadTransport.Tests.swift", entry)
        executable = temp_dir / "iPadTransportTests"
        subprocess.run(
            [compiler, "-swift-version", "5", "-O", str(extracted), str(entry), "-o", str(executable)],
            check=True,
        )
        subprocess.run([str(executable)], check=True, timeout=90)


if __name__ == "__main__":
    main()
