#!/usr/bin/env python3
"""Install/control the per-user macOS FVM co-op service without administrator rights."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

from install_cloudflared import install as install_cloudflared

LABEL = "io.github.9tempest.fvmreborn.coop"
DEFAULT_DATA = Path.home() / "Library/Application Support/FVM-Reborn/co-op"
SOURCE_FILES = ("main.py", "storage.py", "protocol.py", "configure_host.py", "launcher.py", "requirements.txt")


def launchctl(*arguments, check=True):
    return subprocess.run(["/bin/launchctl", *arguments], check=check, capture_output=True, text=True)


def stop_loaded(target):
    launchctl("bootout", target, check=False)
    deadline = time.monotonic() + 30
    while launchctl("print", target, check=False).returncode == 0:
        if time.monotonic() >= deadline:
            raise RuntimeError("The prior game service is still shutting down; retry shortly")
        time.sleep(0.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "start", "stop", "status", "uninstall"))
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--game-data-dir", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--cloudflared", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin": parser.error("This manager requires macOS")
    if not 1 <= args.port <= 65535: parser.error("Invalid port")
    os.umask(0o077)
    root = args.data_dir.expanduser().resolve()
    plist = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{LABEL}"
    if args.action == "install":
        if args.game_data_dir is None: parser.error("--game-data-dir is required for install")
        game_data_dir = args.game_data_dir.expanduser().resolve()
        if not game_data_dir.is_dir(): parser.error("Game save directory does not exist")
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(root, 0o700)
        stop_loaded(target)
        runtime = root / "service"
        runtime.mkdir(mode=0o700, exist_ok=True)
        source = Path(__file__).parent
        for name in SOURCE_FILES: shutil.copy2(source / name, runtime / name)
        executable = root / ".venv/bin/python"
        if not executable.exists():
            subprocess.run([sys._base_executable, "-m", "venv", str(root / ".venv")], check=True)
        subprocess.run([str(executable), "-m", "pip", "install", "-r", str(runtime / "requirements.txt")], check=True)
        cloudflared = args.cloudflared or root / "bin/cloudflared"
        if not cloudflared.exists(): cloudflared = install_cloudflared(root / "bin")
        cloudflared = cloudflared.resolve()
        subprocess.run([str(cloudflared), "--version"], check=True)
        with open(root / "launcher.json", "w") as output:
            json.dump({"game_data_dir": str(game_data_dir), "port": args.port, "cloudflared": str(cloudflared)}, output)
            output.write("\n")
        agent = {"Label": LABEL, "ProgramArguments": [str(executable), str(runtime / "launcher.py"), "--data-dir", str(root)],
                 "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 15, "ExitTimeOut": 25,
                 "ProcessType": "Interactive", "WorkingDirectory": str(root),
                 "EnvironmentVariables": {"PYTHONUNBUFFERED": "1", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"},
                 "StandardOutPath": str(root / "launchd.stdout.log"), "StandardErrorPath": str(root / "launchd.stderr.log")}
        plist.parent.mkdir(parents=True, exist_ok=True)
        with open(plist, "wb") as output: plistlib.dump(agent, output)
        os.chmod(plist, 0o600)
        launchctl("enable", target)
        launchctl("bootstrap", domain, str(plist))
        print(f"Installed and started {LABEL}. Status: {root / 'status.json'}")
    elif args.action == "start":
        if not plist.exists(): parser.error("Install the service first")
        launchctl("enable", target)
        if launchctl("print", target, check=False).returncode:
            launchctl("bootstrap", domain, str(plist))
            print("FVM co-op service starting; a new Quick Tunnel URL will appear in status.json and host.json")
        else:
            print("FVM co-op service is already running. Stop, then start to obtain a new Quick Tunnel URL.")
    elif args.action in ("stop", "uninstall"):
        launchctl("disable", target)
        stop_loaded(target)
        if args.action == "uninstall" and plist.exists(): plist.unlink()
        print("FVM co-op service stopped; automatic login startup disabled. Saved game data is retained.")
    else:
        loaded = launchctl("print", target, check=False).returncode == 0
        state = json.loads((root / "status.json").read_text()) if (root / "status.json").exists() else {}
        print(json.dumps({"loaded": loaded, **state}, ensure_ascii=False, indent=2))


if __name__ == "__main__": main()
