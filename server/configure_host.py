#!/usr/bin/env python3
"""Write the local game host credential without exposing it to stdout or Git."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlparse

from storage import Store


def write_configuration(game_data_dir, url, public_url, token):
    directory = Path(game_data_dir).expanduser().resolve() / "coop"
    if directory.is_symlink(): raise ValueError("coop/ cannot be a symlink")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    destination = directory / "host.json"
    if destination.is_symlink(): raise ValueError("host.json cannot be a symlink")
    config = {"url": url, "public_url": public_url, "token": token}
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
    return destination


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
    store = Store(args.data_dir)
    try:
        destination = write_configuration(args.game_data_dir, args.url, args.public_url, store.host_token)
    finally:
        store.close()
    print(f"Configured local game host file: {destination}")


if __name__ == "__main__":
    main()
