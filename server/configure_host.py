#!/usr/bin/env python3
"""Write the local game host credential without exposing it to stdout or Git."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlparse

from storage import Store


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).parent / "serverdata")
    parser.add_argument("--game-data-dir", type=Path, required=True, help="GameMaker save_directory containing saves/; host.json goes in coop/")
    parser.add_argument("--url", default="ws://127.0.0.1:8765/game")
    parser.add_argument("--public-url", default="", help="Optional published WSS /game endpoint; does not create a tunnel")
    args = parser.parse_args()
    local = urlparse(args.url)
    if local.scheme != "ws" or local.hostname != "127.0.0.1" or local.path != "/game" or local.query or local.fragment or local.username:
        parser.error("--url must be a loopback ws://127.0.0.1:PORT/game URL")
    if args.public_url:
        public = urlparse(args.public_url)
        if public.scheme != "wss" or not public.hostname or public.path != "/game" or public.query or public.fragment or public.username:
            parser.error("--public-url must be an authenticated-by-invitation wss://HOST/game URL")
    os.umask(0o077)
    directory = args.game_data_dir.expanduser().resolve() / "coop"
    if directory.is_symlink(): parser.error("coop/ cannot be a symlink")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    destination = directory / "host.json"
    if destination.is_symlink(): parser.error("host.json cannot be a symlink")
    store = Store(args.data_dir)
    try:
        config = {"url": args.url, "public_url": args.public_url, "token": store.host_token}
        fd, temporary = tempfile.mkstemp(prefix=".host-", dir=directory)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(config, output, ensure_ascii=False)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    finally:
        store.close()
    print(f"Configured local game host file: {destination}")


if __name__ == "__main__":
    main()
