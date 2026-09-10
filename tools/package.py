"""Build dist/pafo-<version>.zip with only the files the addon needs to run.

The zip holds a single pafo/ folder, ready to drop into Ashita's addons
folder. Only files tracked by git are included, so local leftovers never
ship.

Usage: python tools/package.py
"""
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME_FILES = ["pafo.lua", "cacert.pem"]
RUNTIME_DIRS = ["ashita", "core", "data"]


def version():
    text = (ROOT / "pafo.lua").read_text(encoding="utf-8")
    m = re.search(r"addon\.version\s*=\s*'([^']+)'", text)
    if not m:
        sys.exit("addon.version not found in pafo.lua")
    return m.group(1)


def tracked(paths):
    out = subprocess.run(
        ["git", "ls-files", "--", *paths],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def runtime_files():
    files = tracked(RUNTIME_FILES)
    missing = sorted(set(RUNTIME_FILES) - set(files))
    if missing:
        sys.exit("not tracked by git: " + ", ".join(missing))
    files += [f for f in tracked(RUNTIME_DIRS) if f.endswith(".lua")]
    return sorted(files)


def main():
    files = runtime_files()
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    target = dist / f"pafo-{version()}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in files:
            zf.write(ROOT / rel, f"pafo/{rel}")
    print(f"{target.relative_to(ROOT)}: {len(files)} files")


if __name__ == "__main__":
    main()
