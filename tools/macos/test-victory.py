#!/usr/bin/env python3
"""Render the production victory UI with real art in an isolated, save-free VM app.

Default: verify reward idempotence and input, render three screenshots, then exit. --interactive
keeps the fixture open; press 1/2/3 for first clear, repeat clear, or two pages.
No production app, game progress, or user save is opened or changed.
"""
import argparse
import copy
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("autosave_test_support", HERE / "test-autosave.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
REPO = support.REPO
NAME = "FVM-Victory-Preview"


def prepare(root, app_id, interactive):
    project_file = support.prepare(root, app_id)
    project = project_file.parent
    yyp = support.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name": "Harness", "path": "folders/Harness.yy"}
    name = "LevelRewards"
    shutil.copytree(REPO / "scripts" / name, project / "scripts" / name)
    helper_path = project / "scripts" / name / (name + ".yy")
    helper_meta = support.read_yy(helper_path)
    helper_meta["parent"] = parent
    support.write_yy(helper_path, helper_meta)
    yyp["resources"].append({"id": {"name": name, "path": str(helper_path.relative_to(project))}})
    sprites = ["spr_slot", "spr_coin", "spr_craft_material", "spr_flame", "spr_win", "spr_lose", "spr_place_player_tip", "spr_double_long_bao", "spr_coke_bomb", "spr_mouse_clip"]
    # Use the exact registered equipment icons rather than guessed asset names.
    weapon_text = (REPO / "scripts/weapons_init/weapons_init.gml").read_text()
    for item in ("star_gun", "cookie_shield", "attack_gem"):
        match = re.search(r'"' + item + r'"\s*,\s*\{.*?"icon"\s*:\s*(spr_\w+)', weapon_text, re.S)
        if not match:
            raise ValueError("Cannot resolve fixture icon: " + item)
        sprites.append(match.group(1))
    for kind, names in (("sprites", list(dict.fromkeys(sprites))), ("fonts", ["font_yuan"])):
        for name in names:
            shutil.copytree(REPO / kind / name, project / kind / name)
            path = project / kind / name / (name + ".yy")
            meta = support.read_yy(path)
            meta["parent"] = parent
            meta["textureGroupId"] = {"name": yyp["TextureGroups"][0]["name"], "path": "texturegroups/" + yyp["TextureGroups"][0]["name"]}
            support.write_yy(path, meta)
            yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
    template = support.read_yy(REPO / "objects/obj_battle_pause_manager/obj_battle_pause_manager.yy")
    for name in ("obj_autosave_tests", "obj_battle_pause_manager", "obj_battle", "obj_task_manager", "obj_game_over", "obj_pause_menu", "obj_world_map_button"):
        meta = copy.deepcopy(template)
        meta.update({"%Name": name, "name": name, "parent": parent})
        meta["eventList"] = []
        if name == "obj_battle_pause_manager":
            meta["eventList"] = [e for e in template["eventList"] if e["eventType"] in (0, 3, 8)]
        if name == "obj_autosave_tests":
            meta["eventList"] = [e for e in template["eventList"] if e["eventType"] in (0, 3)]
        path = project / "objects" / name / (name + ".yy")
        support.write_yy(path, meta)
        yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
    for event in ("Create_0.gml", "Draw_0.gml", "Step_2.gml"):
        shutil.copyfile(REPO / "objects/obj_battle_pause_manager" / event, project / "objects/obj_battle_pause_manager" / event)
    fixture = (HERE / "victory-fixture.gml").read_text().replace("FIXTURE_WEAPON_A", sprites[-3]).replace("FIXTURE_WEAPON_B", sprites[-2]).replace("FIXTURE_GEM", sprites[-1])
    script_name = "victory_fixture"
    path = project / "scripts" / script_name / (script_name + ".yy")
    support.write_yy(path, {"$GMScript": "v1", "%Name": script_name, "name": script_name, "isCompatibility": False, "isDnD": False, "parent": parent, "resourceType": "GMScript", "resourceVersion": "2.0"})
    path.with_suffix(".gml").write_text(fixture)
    yyp["resources"].append({"id": {"name": script_name, "path": str(path.relative_to(project))}})
    (project / "objects/obj_autosave_tests/Create_0.gml").write_text("fixture_init();\nfixture_frame = 0;\n")
    step = '''fixture_frame++
if (fixture_frame == 20) keyboard_key_press(vk_space)
if (fixture_frame == 21) keyboard_key_release(vk_space)
if (fixture_frame == 23) fixture_expect("space skips animation", obj_battle_pause_manager.victory_time >= obj_battle_pause_manager.victory_duration)
if (fixture_frame == 170) { surface_save(application_surface, "first-clear.png"); show_debug_message("FVM_VICTORY_IMAGE=" + game_save_id + "first-clear.png"); }
if (fixture_frame == 175) fixture_show(2)
if (fixture_frame == 345) { surface_save(application_surface, "repeat-clear.png"); show_debug_message("FVM_VICTORY_IMAGE=" + game_save_id + "repeat-clear.png"); }
if (fixture_frame == 350) fixture_show(3)
if (fixture_frame == 375) keyboard_key_press(vk_space)
if (fixture_frame == 376) keyboard_key_release(vk_space)
if (fixture_frame == 380) keyboard_key_press(vk_right)
if (fixture_frame == 381) keyboard_key_release(vk_right)
if (fixture_frame == 540) {
	surface_save(application_surface, "page-two.png"); show_debug_message("FVM_VICTORY_IMAGE=" + game_save_id + "page-two.png");
	fixture_expect("right arrow changes page", obj_battle_pause_manager.victory_page == 1)
}
if (fixture_frame == 545) keyboard_key_press(vk_left)
if (fixture_frame == 546) keyboard_key_release(vk_left)
if (fixture_frame == 550) fixture_expect("left arrow returns page", obj_battle_pause_manager.victory_page == 0)
if (keyboard_check_pressed(ord("1"))) fixture_show(1)
if (keyboard_check_pressed(ord("2"))) fixture_show(2)
if (keyboard_check_pressed(ord("3"))) fixture_show(3)
'''
    step += "if (fixture_frame == 555) { fixture_report(); show_debug_message(\"FVM_VICTORY_SAVE_CALLS=\" + string(global.fixture_saves)); " + ("fixture_show(1);" if interactive else "game_end();") + " }\n"
    (project / "objects/obj_autosave_tests/Step_2.gml").write_text(step)
    room = project / yyp["RoomOrderNodes"][0]["roomId"]["path"]
    data = support.read_yy(room)
    data["roomSettings"].update({"Width": 1920, "Height": 1080})
    support.write_yy(room, data)
    support.write_yy(project_file, yyp)
    mac_path = project / "options/mac/options_mac.yy"
    mac = support.read_yy(mac_path)
    mac["option_mac_display_name"] = NAME
    support.write_yy(mac_path, mac)
    support.write_yy(root / "manifest.json", {
        "app_id": app_id,
        "project": str(project_file),
        "save_io": "All save calls are stubbed; production save scripts are excluded.",
        "reward_helper_sha256": hashlib.sha256((REPO / "scripts/LevelRewards/LevelRewards.gml").read_bytes()).hexdigest(),
        "production_sources": {
            name: hashlib.sha256((REPO / "objects/obj_battle_pause_manager" / name).read_bytes()).hexdigest()
            for name in ("Create_0.gml", "Draw_0.gml", "Step_2.gml")
        },
    })
    return project_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="fvm-victory-", dir="/tmp"))
    app_id = "io.github.9tempest.fvmreborn.victory-preview." + uuid.uuid4().hex
    print("Visual fixture: " + str(root), flush=True)
    project = prepare(root, app_id, args.interactive)
    if args.prepare_only:
        return
    runtime, igor, user = support.toolchain(Path(os.environ.get("FVM_GAMEMAKER_RUNTIME", "/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + support.VERSION)))
    for name in ("cache", "temp", "output", "logs"):
        (root / name).mkdir()
    command = [igor, "-j=1", "/uf=" + str(user), "/lf=" + str(user / "licence.plist"), "/rp=" + str(runtime), "/project=" + str(project), "/cache=" + str(root / "cache"), "/temp=" + str(root / "temp"), "/runtime=VM", "/of=" + str(root / "output/test"), "--", "Mac", "Compile"]
    support.command(command, root / "logs/compile.log", cwd=project.parent, env=dict(os.environ, COMPlus_ZapDisable="1"), timeout=240)
    game = root / "output/assets/game.ios"
    if not game.is_file():
        game = root / "output/game.ios"
    app = root / (NAME + ".app")
    shutil.copytree(runtime / "mac/YoYo Runner.app", app, symlinks=True)
    contents = app / "Contents"
    for name in ("yoyorunner.config", "game.yydebug"):
        (contents / "Resources" / name).unlink(missing_ok=True)
    shutil.copyfile(game, contents / "Resources/game.ios")
    options = root / "output/options.ini"
    if options.is_file():
        shutil.copyfile(options, contents / "Resources/options.ini")
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update({"CFBundleIdentifier": app_id, "CFBundleName": NAME, "CFBundleDisplayName": NAME})
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = root / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    for lib in sorted(contents.rglob("*.dylib")):
        subprocess.run(["codesign", "--force", "--sign", "-", str(lib)], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)], check=True, capture_output=True)
    # Use the real resource path explicitly, including macOS /private/tmp aliases.
    # This matches the production launcher's -game workaround without touching user apps.
    run_command = [str(contents / "MacOS/Mac_Runner"), "-game", str(contents / "Resources/game.ios").replace("/private/tmp/", "/tmp/")]
    if args.interactive:
        with (root / "logs/run.log").open("wb") as log:
            subprocess.Popen(run_command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
        print("Interactive preview running; press 1/2/3. Log: " + str(root / "logs/run.log"))
    else:
        support.command(run_command, root / "logs/run.log", cwd=root, timeout=60)
        output = (root / "logs/run.log").read_text(errors="replace")
        reports = re.findall(r"FVM_VICTORY_RESULT=(\{[^\r\n]+\})", output)
        if not reports:
            raise RuntimeError("Fixture did not emit its result; inspect " + str(root / "logs/run.log"))
        result = json.loads(reports[-1])
        support.write_yy(root / "results.json", result)
        print(str(int(result["passed"])) + "/" + str(int(result["total"])) + " victory assertions passed.")
        print("Report: " + str(root / "results.json"))
        for line in output.splitlines():
            if line.startswith("FVM_VICTORY_IMAGE=") or line.startswith("FVM_VICTORY_ASSERT=0"):
                print(line)
        if "FVM_VICTORY_SAVE_CALLS=0" not in output or result["passed"] != result["total"]:
            raise RuntimeError("Fixture did not finish with zero save calls; inspect " + str(root / "logs/run.log"))


if __name__ == "__main__":
    main()
