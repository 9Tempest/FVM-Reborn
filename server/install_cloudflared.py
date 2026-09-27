#!/usr/bin/env python3
"""Install a checksum-verified official Cloudflare release into private app data."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request

RELEASE = "2026.9.3"


def install(directory):
    architecture = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if platform.system() != "Darwin" or architecture is None:
        raise RuntimeError("This installer supports native macOS arm64 and x86_64")
    asset_name = f"cloudflared-darwin-{architecture}.tgz"
    api = f"https://api.github.com/repos/cloudflare/cloudflared/releases/tags/{RELEASE}"
    with urllib.request.urlopen(api, timeout=30) as response:
        release = json.load(response)
    asset = next(a for a in release["assets"] if a["name"] == asset_name)
    expected = asset.get("digest", "")
    if not expected.startswith("sha256:"):
        raise RuntimeError("Official release does not provide a SHA-256 digest")
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/cloudflare/cloudflared/releases/download/{RELEASE}/"):
        raise RuntimeError("Unexpected release download location")
    with urllib.request.urlopen(url, timeout=60) as response:
        payload = response.read(100 * 1024 * 1024 + 1)
    if len(payload) != asset["size"] or "sha256:" + hashlib.sha256(payload).hexdigest() != expected:
        raise RuntimeError("Cloudflare release checksum verification failed")
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = [m for m in archive.getmembers() if m.name in ("cloudflared", "./cloudflared") and m.isfile()]
        if len(members) != 1 or members[0].size > 200 * 1024 * 1024:
            raise RuntimeError("Unexpected official archive contents")
        executable = archive.extractfile(members[0]).read()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".cloudflared-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(executable)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o700)
        os.replace(temporary, directory / "cloudflared")
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    print(f"Installed official cloudflared {RELEASE}; SHA-256 verified")
    return directory / "cloudflared"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() / "Library/Application Support/FVM-Reborn/co-op/bin")
    arguments = parser.parse_args()
    os.umask(0o077)
    install(arguments.directory)
