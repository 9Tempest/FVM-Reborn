#!/usr/bin/env python3
"""Test real native GameMaker WebSockets against a standard Python echo server.

Run using a Python environment with websockets==16.0. An isolated app container
and minimal project are created; the installed game and its saves are untouched.
WSS certificate validation is only tested when --url points to a trusted TLS
endpoint tunnelling to this echo server (--echo-port makes its port predictable).
"""

import argparse
import asyncio
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fvm_test_helpers", Path(__file__).with_name("test-autosave.py"))
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
REPO = helpers.REPO
NAME = "FVM-Coop-Transport-Tests"
APP_PREFIX = "io.github.9tempest.fvmreborn.coop-transport-tests"


class EchoServer:
    def __init__(self, port):
        self.port = port
        self.records = []
        self.ready = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        try:
            asyncio.run(self.serve())
        except BaseException as error:
            self.error = error
            self.ready.set()

    async def serve(self):
        from websockets.asyncio.server import serve
        from websockets.exceptions import ConnectionClosed
        self.loop = asyncio.get_running_loop()
        self.stop = asyncio.Event()

        async def echo(connection):
            path = connection.request.path
            self.records.append({"event": "connect", "path": path})
            try:
                async for message in connection:
                    text = isinstance(message, str)
                    record = {"event": "message", "path": path, "text_frame": text, "bytes": len(message.encode("utf-8") if text else message)}
                    self.records.append(record)
                    if not text:
                        await connection.close(code=1003, reason="Text required")
                        continue
                    payload = json.loads(message)
                    kind = payload.get("type")
                    if kind == "invalid_json":
                        await connection.send("{malformed-json")
                    elif kind == "binary":
                        await connection.send(b"{}")
                    elif kind == "server_close":
                        await connection.send(json.dumps({"type": "closing"}))
                        await connection.close(code=1000, reason="test close")
                        break
                    else:
                        await connection.send(json.dumps({"type": "echo", "payload": payload, "path": path, "text_frame": text, "valid_json": True, "byte_count": record["bytes"]}, ensure_ascii=False))
            except ConnectionClosed as error:
                # network_destroy may close TCP without a WebSocket close frame.
                self.records.append({"event": "closed", "path": path, "detail": str(error)})
            finally:
                self.records.append({"event": "disconnect", "path": path})

        async with serve(echo, "127.0.0.1", self.port, compression=None, max_size=4194304, close_timeout=0.5) as server:
            self.port = server.sockets[0].getsockname()[1]
            self.ready.set()
            await self.stop.wait()

    def start(self):
        self.thread.start()
        if not self.ready.wait(10) or self.error:
            raise RuntimeError("Echo server failed: " + str(self.error))

    def close(self):
        if hasattr(self, "loop") and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(self.stop.set)
        self.thread.join(3)


def prepare(root, app_id, echo_url, refused_url):
    project = root / "project"
    project.mkdir()
    parent = {"name": "Harness", "path": "folders/Harness.yy"}
    resources = []
    for name, source in (("CoopTransport", REPO / "scripts/CoopTransport/CoopTransport.gml"), ("transport_fixture", Path(__file__).with_name("coop-transport-fixture.gml"))):
        resource_path = "scripts/" + name + "/" + name + ".yy"
        helpers.write_yy(project / resource_path, {"$GMScript": "v1", "%Name": name, "name": name, "isCompatibility": False, "isDnD": False, "parent": parent, "resourceType": "GMScript", "resourceVersion": "2.0"})
        text = source.read_text(encoding="utf-8").replace("@ECHO_URL@", json.dumps(echo_url)).replace("@REFUSED_URL@", json.dumps(refused_url))
        (project / resource_path).with_suffix(".gml").write_text(text, encoding="utf-8")
        resources.append({"id": {"name": name, "path": resource_path}})
    obj_name = "obj_transport_test"
    obj_path = "objects/" + obj_name + "/" + obj_name + ".yy"
    obj = helpers.read_yy(REPO / "objects/obj_file_manager/obj_file_manager.yy")
    obj.update({"%Name": obj_name, "name": obj_name, "persistent": False, "parent": parent})
    event_template = obj["eventList"][0]
    obj["eventList"] = []
    for event_type, event_num, filename, code in (
        (0, 0, "Create_0.gml", "transport_test_start();"),
        (3, 0, "Step_0.gml", "transport_test_step();"),
        (7, 68, "Other_68.gml", "global.transport.handle_event(async_load);"),
    ):
        event = copy.deepcopy(event_template)
        event.update({"eventType": event_type, "eventNum": event_num})
        obj["eventList"].append(event)
        path = project / "objects" / obj_name / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(code + "\n")
    helpers.write_yy(project / obj_path, obj)
    resources.append({"id": {"name": obj_name, "path": obj_path}})
    room_name = "room_transport_test"
    room_path = "rooms/" + room_name + "/" + room_name + ".yy"
    room = helpers.read_yy(REPO / "rooms/room_init/room_init.yy")
    room.update({"%Name": room_name, "name": room_name, "parent": parent, "creationCodeFile": "", "instanceCreationOrder": [{"name": "inst_transport", "path": room_path}]})
    instance = copy.deepcopy(room["layers"][0]["instances"][0])
    instance.update({"%Name": "inst_transport", "name": "inst_transport", "objectId": {"name": obj_name, "path": obj_path}})
    room["layers"][0]["instances"] = [instance]
    room["roomSettings"].update({"Width": 320, "Height": 180})
    helpers.write_yy(project / room_path, room)
    resources.append({"id": {"name": room_name, "path": room_path}})
    yyp = helpers.read_yy(REPO / "FVM-reborn.yyp")
    yyp.update({"%Name": NAME, "name": NAME, "IncludedFiles": [], "resources": resources, "Folders": [{"$GMFolder": "", "%Name": "Harness", "name": "Harness", "folderPath": "folders/Harness.yy", "resourceType": "GMFolder", "resourceVersion": "2.0"}], "RoomOrderNodes": [{"roomId": {"name": room_name, "path": room_path}}]})
    yyp["AudioGroups"] = yyp["AudioGroups"][:1]
    yyp["TextureGroups"] = yyp["TextureGroups"][:1]
    project_file = project / (NAME + ".yyp")
    helpers.write_yy(project_file, yyp)
    for target in ("main", "mac"):
        shutil.copytree(REPO / "options" / target, project / "options" / target)
    main_path = project / "options/main/options_main.yy"
    main = helpers.read_yy(main_path)
    main["option_gameguid"] = str(uuid.uuid4())
    helpers.write_yy(main_path, main)
    mac_path = project / "options/mac/options_mac.yy"
    mac = helpers.read_yy(mac_path)
    mac.update({"option_mac_app_id": app_id, "option_mac_display_name": NAME, "option_mac_output_dir": str(root / "output"), "option_mac_start_fullscreen": False, "option_mac_allow_outgoing_network": True})
    helpers.write_yy(mac_path, mac)
    return project_file


def build_run(root, project, app_id):
    import os
    runtime, igor, user = helpers.toolchain(Path(os.environ.get("FVM_GAMEMAKER_RUNTIME", "/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + helpers.VERSION)))
    for name in ("cache", "temp", "output", "logs"):
        (root / name).mkdir()
    args = [igor, "-j=1", "/uf=" + str(user), "/lf=" + str(user / "licence.plist"), "/rp=" + str(runtime), "/project=" + str(project), "/cache=" + str(root / "cache"), "/temp=" + str(root / "temp"), "/runtime=VM", "/of=" + str(root / "output/test"), "--", "Mac", "Compile"]
    helpers.command(args, root / "logs/compile.log", cwd=project.parent, env=dict(os.environ, COMPlus_ZapDisable="1"), timeout=240)
    app = root / (NAME + ".app")
    shutil.copytree(runtime / "mac/YoYo Runner.app", app, symlinks=True)
    contents = app / "Contents"
    resources = contents / "Resources"
    (resources / "yoyorunner.config").unlink(missing_ok=True)
    shutil.copyfile(root / "output/assets/game.ios", resources / "game.ios")
    shutil.copyfile(root / "output/options.ini", resources / "options.ini")
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update({"CFBundleIdentifier": app_id, "CFBundleName": NAME, "CFBundleDisplayName": NAME, "LSMinimumSystemVersion": "13.0"})
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = root / "local.entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True}))
    for library in contents.rglob("*.dylib"):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(library)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Running isolated native WebSocket app...", flush=True)
    helpers.command([contents / "MacOS/Mac_Runner"], root / "logs/run.log", cwd=root, timeout=40)
    import re
    reports = re.findall(r"FVM_TRANSPORT_RESULT=(\{[^\r\n]+\})", (root / "logs/run.log").read_text(errors="replace"))
    if not reports:
        raise RuntimeError("No native test result; inspect run.log")
    return json.loads(reports[-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Optional trusted WSS tunnel to this echo server, with /game?transport_test=1 path")
    parser.add_argument("--echo-port", type=int, default=0, help="Local echo port; default selects a free loopback port")
    args = parser.parse_args()
    try:
        import websockets
    except ImportError:
        parser.error("Install websockets==16.0 in a separate venv and run this script using that Python.")
    if sys.platform != "darwin":
        parser.error("The VM integration test requires macOS.")
    parent = Path.home() / "Library/Caches/FVM-Reborn/coop-transport-tests"
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    server = EchoServer(args.echo_port)
    refused = socket.socket()
    refused.bind(("127.0.0.1", 0))
    print("Test workspace: " + str(root), flush=True)
    try:
        server.start()
        echo_url = args.url or "ws://127.0.0.1:" + str(server.port) + "/game?transport_test=1"
        print("Echo listening on 127.0.0.1:" + str(server.port), flush=True)
        app_id = APP_PREFIX + "." + uuid.uuid4().hex
        project = prepare(root, app_id, echo_url, "ws://127.0.0.1:" + str(refused.getsockname()[1]) + "/game")
        source = (REPO / "scripts/CoopTransport/CoopTransport.gml").read_bytes()
        helpers.write_yy(root / "manifest.json", {"app_id": app_id, "transport_sha256": hashlib.sha256(source).hexdigest(), "websockets": websockets.__version__, "tls_requested": echo_url.startswith("wss://"), "async_event_number": 68})
        report = build_run(root, project, app_id)
        report["tls_verified"] = echo_url.startswith("wss://") and report["passed"] == report["total"]
        helpers.write_yy(root / "results.json", report)
        print(str(int(report["passed"])) + "/" + str(int(report["total"])) + " native transport assertions passed.")
        for test in report["tests"]:
            if not test["passed"]:
                print("FAIL: " + test["name"])
        print("Report: " + str(root / "results.json"))
        print("WSS: " + ("verified via trusted TLS endpoint" if report["tls_verified"] else "not exercised; local WS only"))
        return 0 if report["passed"] == report["total"] else 1
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("Error: " + str(error), file=sys.stderr)
        print("Inspect " + str(root / "logs"), file=sys.stderr)
        return 1
    finally:
        refused.close()
        server.close()
        helpers.write_yy(root / "server-results.json", server.records)


if __name__ == "__main__":
    sys.exit(main())
