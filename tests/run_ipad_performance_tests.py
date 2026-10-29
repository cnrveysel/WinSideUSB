#!/usr/bin/env python3
"""Small production-helper checks; no USB, display, or sustained workload."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swiftc")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    source = (repo / "WinSideUSB/swiftclientcode.swift").read_text(encoding="utf-8-sig")
    native = (repo / "iPadClient/Sources/WinSideUSBClient/App.swift").read_text(encoding="utf-8-sig")
    if source != native:
        raise SystemExit("iPad sources differ. Run scripts/Sync-iPadClient.ps1 first.")
    # Extract actual production logic; UIKit/transport are not exercised here.
    start = source.index("// MARK: - Async video logging")
    sample_start = source.index("// MARK: - Video sample attachments", start)
    end = source.index("// MARK: - Recoverable BSD listener", sample_start)
    helper = "import Foundation\nimport Dispatch\n" + source[start:sample_start]
    helper += "\n#if canImport(CoreMedia)\nimport CoreMedia\n" + source[sample_start:end] + "\n#endif\n"
    compiler = shutil.which(args.swift)
    if not compiler:
        raise SystemExit("Swift compiler not found.")
    with tempfile.TemporaryDirectory(prefix="winsideusb-ipad-performance-") as temp:
        folder = Path(temp)
        (folder / "Helpers.swift").write_text(helper, encoding="utf-8")
        shutil.copyfile(repo / "tests/iPadPerformance.Tests.swift", folder / "main.swift")
        binary = folder / "iPadPerformanceTests"
        subprocess.run([compiler, "-swift-version", "5", "-j", "1",
                        str(folder / "Helpers.swift"), str(folder / "main.swift"),
                        "-o", str(binary)], check=True, timeout=90)
        subprocess.run([str(binary)], check=True, timeout=25)


if __name__ == "__main__":
    main()
