#!/usr/bin/env python3
"""Supervise a loopback game server and outbound Cloudflare Quick Tunnel together."""
import argparse
import asyncio
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import time

from configure_host import write_configuration

LOG = logging.getLogger("fvm.launcher")
PUBLIC_URL = re.compile(r"https://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com\b")


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".status-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


async def terminate(process):
    if process and process.returncode is None:
        process.terminate()
        try: await asyncio.wait_for(process.wait(), 8)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()


async def supervise(config, data_dir):
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT): loop.add_signal_handler(sig, stopped.set)
    port = config.get("port", 8765)
    local_url = f"ws://127.0.0.1:{port}/game"
    public_url = ""
    tunnel_config = data_dir / "quick-tunnel.yml"
    # A nonempty, explicit empty YAML mapping avoids cloudflared's fallback search
    # after an empty-file parse error (for example when passed /dev/null).
    tunnel_config.write_text("{}\n")

    def update(status, url=""):
        nonlocal public_url
        public_url = url
        token_path = data_dir / "host-token"
        if token_path.exists():
            write_configuration(config["game_data_dir"], local_url, url, token_path.read_text().strip())
        atomic_json(data_dir / "status.json", {"status": status, "pid": os.getpid(),
            "local_url": local_url, "public_url": url, "updated_at": time.time()})

    async def relay(stream, source):
        async for raw in stream:
            line = raw.decode("utf-8", "replace").strip()
            LOG.info("%s: %s", source, line)
            if source == "tunnel":
                found = PUBLIC_URL.search(line)
                if found: update("connecting", found.group(0).replace("https://", "wss://", 1) + "/game")
                if "Registered tunnel connection" in line and public_url:
                    update("online", public_url)

    backoff = 2
    while not stopped.is_set():
        server = tunnel = None
        readers = watchers = []
        started_at = time.monotonic()
        update("starting")
        try:
            server = await asyncio.create_subprocess_exec(sys.executable, str(Path(__file__).with_name("main.py")),
                "--data-dir", str(data_dir), "--port", str(port), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            readers = [asyncio.create_task(relay(server.stderr, "server"))]
            line = await asyncio.wait_for(server.stdout.readline(), 15)
            ready = json.loads(line)
            if ready.get("listening") != "127.0.0.1" or ready.get("port") != port:
                raise RuntimeError("Unexpected game service listener")
            readers.append(asyncio.create_task(relay(server.stdout, "server")))
            update("local_ready")
            # The dedicated configuration never modifies the user's Cloudflare settings.
            tunnel = await asyncio.create_subprocess_exec(config["cloudflared"], "tunnel", "--config", str(tunnel_config),
                "--no-autoupdate", "--url", f"http://127.0.0.1:{port}", "--protocol", "http2", "--metrics", "127.0.0.1:0", "--management-diagnostics=false",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
            readers.append(asyncio.create_task(relay(tunnel.stdout, "tunnel")))
            watchers = [asyncio.create_task(stopped.wait()), asyncio.create_task(server.wait()), asyncio.create_task(tunnel.wait())]
            await asyncio.wait(watchers, return_when=asyncio.FIRST_COMPLETED)
            if not stopped.is_set(): LOG.warning("A child exited; restarting game service and tunnel")
            backoff = 2 if time.monotonic() - started_at >= 30 else min(backoff * 2, 60)
        except Exception:
            LOG.exception("Could not start game service and tunnel")
            backoff = min(backoff * 2, 60)
        finally:
            await terminate(tunnel)
            await terminate(server)
            for task in readers + watchers: task.cancel()
            await asyncio.gather(*(readers + watchers), return_exceptions=True)
            update("stopped" if stopped.is_set() else "reconnecting")
        if not stopped.is_set():
            try: await asyncio.wait_for(stopped.wait(), backoff)
            except asyncio.TimeoutError: pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    data_dir = args.data_dir.expanduser().resolve()
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(data_dir / "launcher.lock", "a") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise SystemExit("The FVM co-op launcher is already running")
        handler = RotatingFileHandler(data_dir / "service.log", maxBytes=2 * 1024 * 1024, backupCount=3)
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        LOG.addHandler(handler)
        LOG.setLevel(logging.INFO)
        config = json.loads((data_dir / "launcher.json").read_text())
        asyncio.run(supervise(config, data_dir))


if __name__ == "__main__": main()
