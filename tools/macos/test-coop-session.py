#!/usr/bin/env python3
"""Exercise actual CoopSession preparation, recovery, durable outboxes and networking.

Run with a macOS Python venv containing server/requirements.txt. Save/UI/battle
stubs and a disk-failure seam exist only in the isolated temporary project.
"""
import importlib.util
from pathlib import Path
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fvm_server_fixture", Path(__file__).with_name("test-coop-server.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
if __name__ == "__main__":
    sys.exit(harness.main(session=True))
