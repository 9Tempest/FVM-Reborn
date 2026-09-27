#!/usr/bin/env python3
"""Run two native GameMaker clients against an isolated copy of the real server.

Only synthetic profiles, a disposable host credential, and a new SQLite database
are used. No installed game, production server, or real save is read or changed.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fvm_network_helpers", Path(__file__).with_name("test-coop-transport.py"))
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)
helpers = network.helpers


def main(session=False):
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        import websockets
    except ImportError:
        sys.exit("Install server/requirements.txt in a separate venv, then run this script with its Python.")
    if sys.platform != "darwin":
        sys.exit("This native VM integration test requires macOS.")
    os.umask(0o077)
    parent = Path.home() / "Library/Caches/FVM-Reborn" / ("coop-session-tests" if session else "coop-server-tests")
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    source_root = root / "server-source"
    source_root.mkdir()
    sources = {}
    for name in ("main.py", "protocol.py", "storage.py", "requirements.txt"):
        source = helpers.REPO / "server" / name
        shutil.copyfile(source, source_root / name)
        sources["server/" + name] = hashlib.sha256(source.read_bytes()).hexdigest()
    data = root / "server-data"
    server = None
    server_log = (root / "server.log").open("wb")
    print("Test workspace: " + str(root), flush=True)
    try:
        server = subprocess.Popen([sys.executable, str(source_root / "main.py"), "--data-dir", str(data), "--port", "0", "--backup-every", "0", "--auth-timeout", "30"], stdout=subprocess.PIPE, stderr=server_log)
        if not select.select([server.stdout], [], [], 10)[0]:
            raise RuntimeError("Isolated server did not start in time")
        line = server.stdout.readline()
        if not line:
            raise RuntimeError("Isolated server failed; inspect server.log")
        ready = json.loads(line)
        if ready["listening"] != "127.0.0.1":
            raise RuntimeError("Refusing to test a server outside loopback")
        url = "ws://127.0.0.1:" + str(ready["port"]) + "/game"
        token = (data / "host-token").read_text().strip()
        app_id = "io.github.9tempest.fvmreborn." + ("coop-session-tests." if session else "coop-server-tests.") + uuid.uuid4().hex
        project = network.prepare(root, app_id, url, url)
        fixture = Path(__file__).with_name("coop-session-fixture.gml" if session else "coop-server-fixture.gml").read_text(encoding="utf-8")
        fixture = fixture.replace("@HOST_TOKEN@", json.dumps(token)).replace("@SERVER_URL@", json.dumps(url))
        (project.parent / "scripts/transport_fixture/transport_fixture.gml").write_text(fixture, encoding="utf-8")
        if session:
            metadata = helpers.read_yy(project)
            name = "CoopSession"
            relative = "scripts/CoopSession/CoopSession.yy"
            yy = helpers.read_yy(project.parent / "scripts/CoopTransport/CoopTransport.yy")
            yy.update({"%Name":name,"name":name})
            helpers.write_yy(project.parent / relative, yy)
            source = (helpers.REPO / "scripts/CoopSession/CoopSession.gml").read_text()
            sources["scripts/CoopSession/CoopSession.gml"] = hashlib.sha256(source.encode()).hexdigest()
            # Fixture-only deterministic disk-full seam; all successful writes use real code.
            source = source.replace("function coop_write_json(","function fixture_real_write_json(",1)
            source = source.replace("clipboard_set_text(invite_code);","global.fixture_clipboard = invite_code;")
            source += "\nfunction coop_write_json(_path,_data) { if(global.fixture_write_fail)return false; return fixture_real_write_json(_path,_data); }\n"
            (project.parent / relative).with_suffix(".gml").write_text(source)
            metadata["resources"].append({"id":{"name":name,"path":relative}})
            for name in ("obj_battle","obj_game_over"):
                relative = "objects/"+name+"/"+name+".yy"
                yy = helpers.read_yy(project.parent / "objects/obj_transport_test/obj_transport_test.yy")
                yy.update({"%Name":name,"name":name,"eventList":[]})
                helpers.write_yy(project.parent / relative,yy)
                metadata["resources"].append({"id":{"name":name,"path":relative}})
            helpers.write_yy(project,metadata)
        (project.parent / "objects/obj_transport_test/Other_68.gml").write_text("global.session.event(global.session.transport.handle_event(async_load));\nglobal.fixture_peer.handle_event(async_load);\n" if session else "global.transport.handle_event(async_load);\nglobal.server_guest.handle_event(async_load);\n")
        sources["scripts/CoopTransport/CoopTransport.gml"] = hashlib.sha256((helpers.REPO / "scripts/CoopTransport/CoopTransport.gml").read_bytes()).hexdigest()
        helpers.write_yy(root / "manifest.json", {"app_id": app_id, "sources": sources, "websockets": websockets.__version__, "credentials": "Disposable credential exists only in the isolated cache workspace", "server": "127.0.0.1"})
        report = network.build_run(root, project, app_id)
        # Stop gracefully so the final checkpoint/backup is durable before SQL checks.
        server.terminate()
        server.wait(timeout=8)
        server = None
        with sqlite3.connect(data / "coop.sqlite3") as db:
            match_configs = [json.loads(row[0]) for row in db.execute("SELECT config_json FROM matches")]
            sql_checks = [
                ("prepared start creates exactly one SQLite match", len(match_configs) == 1),
                ("SQLite match freezes independent player decks", len(match_configs) == 1
                 and match_configs[0].get("per_player_loadouts") is True
                 and match_configs[0].get("flame_ratio") == 0.6
                 and sorted(match_configs[0].get("loadouts", {}).values()) == [["small_fire"], ["toast_bread"]]),
                ("both selected decks are cached durably", db.execute("SELECT COUNT(*) FROM loadout_cache").fetchone()[0] == 2),
                ("SQLite integrity remains intact", db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"),
                ("exactly one input is stored after retry", db.execute("SELECT COUNT(*) FROM commands").fetchone()[0] == 1),
                ("exactly one result is stored after retry", db.execute("SELECT COUNT(*) FROM match_results").fetchone()[0] == 1),
                ("both synthetic profiles receive one reward", sorted(json.loads(row[0])["coins"] for row in db.execute("SELECT profile_json FROM profiles")) == ([180, 180] if session else [150, 150])),
                ("authoritative checkpoint is durable", db.execute("SELECT tick FROM checkpoints").fetchall() == ([(1,)] if session else [(50,)])),
            ]
        for name, passed in sql_checks:
            report["tests"].append({"name": name, "passed": passed})
            report["total"] += 1
            report["passed"] += int(passed)
        helpers.write_yy(root / "results.json", report)
        print(str(int(report["passed"])) + "/" + str(int(report["total"])) + " native/server integration assertions passed.")
        for test in report["tests"]:
            if not test["passed"]:
                print("FAIL: " + test["name"])
        print("Report: " + str(root / "results.json"))
        return 0 if report["passed"] == report["total"] else 1
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, sqlite3.Error) as error:
        print("Error: " + str(error), file=sys.stderr)
        print("Inspect logs under " + str(root), file=sys.stderr)
        return 1
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=8)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        server_log.close()


if __name__ == "__main__":
    sys.exit(main())
