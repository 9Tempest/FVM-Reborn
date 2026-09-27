#!/usr/bin/env python3
"""Run the real save/load GML in a minimal, isolated macOS GameMaker VM app.

Requires the same installed runtime and signed-in user as build.sh. No production
app is launched or edited. Test fixtures only touch the dedicated app sandbox.
Close/rename failures are injected at I/O boundaries in temporary source copies;
all non-failing I/O delegates to GameMaker's actual builtins.
"""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[2]
APP_ID = "io.github.9tempest.fvmreborn.autosave-tests"
NAME = "FVM-Autosave-Tests"
VERSION = "2026.0.0.23"


def read_yy(path):
    return json.loads(re.sub(r",\s*([}\]])", r"\1", path.read_text(encoding="utf-8")))


def write_yy(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def prepare(root, app_id):
    project = root / "project"
    project.mkdir()
    parent = {"name": "Harness", "path": "folders/Harness.yy"}
    source_hashes = {}
    resources = []
    for name in ("save_file", "load_file"):
        src = REPO / "scripts" / name
        dst = project / "scripts" / name
        dst.mkdir(parents=True)
        metadata = read_yy(src / (name + ".yy"))
        metadata["parent"] = parent
        write_yy(dst / (name + ".yy"), metadata)
        source = (src / (name + ".gml")).read_text(encoding="utf-8")
        source_hashes[name] = {"sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(), "interceptions": {}}
        for builtin in ("file_text_open_write", "file_text_close", "file_rename"):
            source, count = re.subn(r"\b" + builtin + r"\s*\(", "harness_" + builtin + "(", source)
            source_hashes[name]["interceptions"][builtin] = count
        (dst / (name + ".gml")).write_text(source, encoding="utf-8")
        resources.append({"id": {"name": name, "path": "scripts/" + name + "/" + name + ".yy"}})
    helper = "autosave_fixture"
    metadata = {"$GMScript": "v1", "%Name": helper, "name": helper, "isCompatibility": False, "isDnD": False, "parent": parent, "resourceType": "GMScript", "resourceVersion": "2.0"}
    write_yy(project / "scripts" / helper / (helper + ".yy"), metadata)
    shutil.copyfile(Path(__file__).with_name("autosave-fixture.gml"), project / "scripts" / helper / (helper + ".gml"))
    resources.append({"id": {"name": helper, "path": "scripts/" + helper + "/" + helper + ".yy"}})

    obj_name = "obj_autosave_tests"
    obj = read_yy(REPO / "objects/obj_file_manager/obj_file_manager.yy")
    obj.update({"%Name": obj_name, "name": obj_name, "persistent": False, "parent": parent})
    obj["eventList"] = [event for event in obj["eventList"] if event["eventType"] == 0]
    write_yy(project / "objects" / obj_name / (obj_name + ".yy"), obj)
    (project / "objects" / obj_name / "Create_0.gml").write_text("harness_run();\n", encoding="utf-8")
    resources.append({"id": {"name": obj_name, "path": "objects/" + obj_name + "/" + obj_name + ".yy"}})

    room_name = "room_autosave_tests"
    room_path = "rooms/" + room_name + "/" + room_name + ".yy"
    room = read_yy(REPO / "rooms/room_init/room_init.yy")
    room.update({"%Name": room_name, "name": room_name, "parent": parent, "creationCodeFile": ""})
    room["instanceCreationOrder"] = [{"name": "inst_autosave_test", "path": room_path}]
    instance = copy.deepcopy(room["layers"][0]["instances"][0])
    instance.update({"%Name": "inst_autosave_test", "name": "inst_autosave_test", "objectId": {"name": obj_name, "path": "objects/" + obj_name + "/" + obj_name + ".yy"}})
    room["layers"][0]["instances"] = [instance]
    room["roomSettings"].update({"Width": 320, "Height": 180})
    write_yy(project / room_path, room)
    resources.append({"id": {"name": room_name, "path": room_path}})

    yyp = read_yy(REPO / "FVM-reborn.yyp")
    yyp.update({"%Name": NAME, "name": NAME, "IncludedFiles": [], "resources": resources,
                "Folders": [{"$GMFolder": "", "%Name": "Harness", "name": "Harness", "folderPath": "folders/Harness.yy", "resourceType": "GMFolder", "resourceVersion": "2.0"}],
                "RoomOrderNodes": [{"roomId": {"name": room_name, "path": room_path}}]})
    yyp["AudioGroups"] = yyp["AudioGroups"][:1]
    yyp["TextureGroups"] = yyp["TextureGroups"][:1]
    project_file = project / (NAME + ".yyp")
    write_yy(project_file, yyp)
    for target in ("main", "mac"):
        shutil.copytree(REPO / "options" / target, project / "options" / target)
    main_file = project / "options/main/options_main.yy"
    main = read_yy(main_file)
    main["option_gameguid"] = str(uuid.uuid4())
    write_yy(main_file, main)
    mac_file = project / "options/mac/options_mac.yy"
    mac = read_yy(mac_file)
    mac.update({"option_mac_app_id": app_id, "option_mac_display_name": NAME, "option_mac_output_dir": str(root / "output"), "option_mac_start_fullscreen": False, "option_mac_allow_outgoing_network": False, "option_mac_version": "1.0.0.0"})
    write_yy(mac_file, mac)
    manifest = {"app_id": app_id, "project": str(project_file), "sources": source_hashes, "fault_injection": "Temporary source copies delegate file opens/closes/renames to test wrappers; otherwise real VM I/O."}
    write_yy(root / "manifest.json", manifest)
    return project_file


def toolchain(runtime_arg):
    runtime = runtime_arg.expanduser().resolve(strict=True)
    arch = "arm64" if platform.machine() == "arm64" else "x64"
    receipt = json.loads((runtime / "receipt.json").read_text())
    for module in ("base", "base-module-osx-" + arch, "mac"):
        if receipt.get(module, {}).get("Version") != VERSION:
            raise ValueError("Install matching GameMaker runtime modules for " + VERSION)
    user_arg = os.environ.get("FVM_GAMEMAKER_USER")
    users = [Path(user_arg).expanduser()] if user_arg else list((Path.home() / "Library/Application Support/GameMakerStudio2-LTS2026").glob("*"))
    users = [p for p in users if p.name not in ("unknownUser_unknownUserID", "guest", "Guest") and (p / "licence.plist").is_file() and (p / "licence.plist").stat().st_size > 0]
    if len(users) != 1:
        raise ValueError("Sign in to GameMaker; use FVM_GAMEMAKER_USER when multiple accounts exist.")
    return runtime, runtime / ("bin/igor/osx/" + arch + "/Igor"), users[0]


def command(args, log_path, **kwargs):
    with log_path.open("wb") as log:
        subprocess.run([str(arg) for arg in args], stdout=log, stderr=subprocess.STDOUT, check=True, **kwargs)


def build_and_run(root, project, runtime_arg, app_id):
    runtime, igor, user = toolchain(runtime_arg)
    for directory in ("cache", "temp", "output", "logs"):
        (root / directory).mkdir()
    print("Compiling isolated autosave test project...", flush=True)
    args = [igor, "-j=1", "/uf=" + str(user), "/lf=" + str(user / "licence.plist"), "/rp=" + str(runtime), "/project=" + str(project), "/cache=" + str(root / "cache"), "/temp=" + str(root / "temp"), "/runtime=VM", "/of=" + str(root / "output/test"), "--", "Mac", "Compile"]
    env = dict(os.environ, COMPlus_ZapDisable="1")
    command(args, root / "logs/compile.log", cwd=project.parent, env=env, timeout=240)
    game = root / "output/assets/game.ios"
    if not game.is_file():
        game = root / "output/game.ios"
    if not game.is_file():
        raise ValueError("Igor did not produce the expected test game.ios; inspect compile.log.")
    app = root / (NAME + ".app")
    shutil.copytree(runtime / "mac/YoYo Runner.app", app, symlinks=True)
    contents = app / "Contents"
    resources = contents / "Resources"
    for name in ("yoyorunner.config", "game.yydebug"):
        (resources / name).unlink(missing_ok=True)
    shutil.copyfile(game, resources / "game.ios")
    options = root / "output/options.ini"
    if options.is_file():
        shutil.copyfile(options, resources / "options.ini")
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update({"CFBundleIdentifier": app_id, "CFBundleName": NAME, "CFBundleDisplayName": NAME, "LSMinimumSystemVersion": "13.0"})
    info_path.write_bytes(plistlib.dumps(info))
    entitlement_path = root / "local.entitlements.plist"
    entitlement_path.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    for library in sorted(contents.rglob("*.dylib")):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(library)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlement_path), str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Running isolated VM file-I/O tests...", flush=True)
    run_log = root / "logs/run.log"
    command([contents / "MacOS/Mac_Runner"], run_log, cwd=root, timeout=45)
    output = run_log.read_text(encoding="utf-8", errors="replace")
    reports = re.findall(r"FVM_AUTOSAVE_RESULT=(\{[^\r\n]+\})", output)
    if not reports:
        raise ValueError("Test app produced no report; inspect " + str(run_log))
    report = json.loads(reports[-1])
    write_yy(root / "results.json", report)
    print(str(int(report["passed"])) + "/" + str(int(report["total"])) + " integration assertions passed.")
    for test in report["tests"]:
        if not test["passed"]:
            print("FAIL: " + test["name"] + (": " + test["detail"] if "detail" in test else ""))
    print("Report: " + str(root / "results.json"))
    return 0 if report["passed"] == report["total"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true", help="Generate the isolated project without compiling or running")
    parser.add_argument("--runtime", type=Path, default=Path(os.environ.get("FVM_GAMEMAKER_RUNTIME", "/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + VERSION)))
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This integration harness requires macOS.")
    root_parent = Path.home() / "Library/Caches/FVM-Reborn/autosave-tests"
    root_parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=root_parent))
    print("Test workspace: " + str(root), flush=True)
    try:
        app_id = APP_ID + "." + uuid.uuid4().hex
        project = prepare(root, app_id)
        if args.prepare_only:
            print("Prepared " + str(project))
            return 0
        for required in ("save_transaction_begin", "save_transaction_end"):
            if required not in (REPO / "scripts/save_file/save_file.gml").read_text(encoding="utf-8"):
                raise ValueError("Central autosave implementation is not ready: missing " + required)
        return build_and_run(root, project, args.runtime, app_id)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Error: " + str(error), file=sys.stderr)
        print("Inspect logs under " + str(root / "logs"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
