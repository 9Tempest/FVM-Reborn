#!/usr/bin/env python3
"""Render and exercise production co-op loadout UI in a small isolated native VM.

Uses 100 synthetic unlocked card records, existing card art, the real deck helpers
and a synchronous session double. No server, installed game or user save is used.
Screenshots and behavioral results are retained in the unique fixture sandbox.
"""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("loadout_ui_support", HERE / "test-autosave.py")
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
s.NAME = "FVM-Coop-Loadout-UI-Tests"


def prepare(root, app_id):
    project_file = s.prepare(root, app_id)
    project = project_file.parent
    yyp = s.read_yy(project_file)
    original = s.read_yy(s.REPO / "FVM-reborn.yyp")
    yyp["TextureGroups"] = original["TextureGroups"]
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name": "Harness", "path": "folders/Harness.yy"}

    def add(kind, name):
        path = project / kind / name / (name + ".yy")
        yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
        return path

    for kind, names in (
        ("scripts", ["CoopUI", "add_to_deck", "deck_get_card_data"]),
        ("sprites", ["spr_slot", "spr_flame", "spr_lose", "spr_player_character", "spr_double_long_bao", "spr_coke_bomb", "spr_mouse_clip"]),
        ("fonts", ["font_yuan"]),
        ("shaders", ["hit_effect_2"]),
        ("sounds", ["mus_readyroom"]),
    ):
        for name in names:
            path = add(kind, name)
            shutil.copytree(s.REPO / kind / name, path.parent)
            meta = s.read_yy(path)
            meta["parent"] = parent
            if kind == "sounds":
                group = yyp["AudioGroups"][0]["name"]
                meta["audioGroupId"] = {"name": group, "path": "audiogroups/" + group}
            s.write_yy(path, meta)
    fixture = add("scripts", "loadout_ui_fixture")
    s.write_yy(fixture, {"$GMScript": "v1", "%Name": "loadout_ui_fixture", "name": "loadout_ui_fixture",
                       "isCompatibility": False, "isDnD": False, "parent": parent,
                       "resourceType": "GMScript", "resourceVersion": "2.0"})
    shutil.copyfile(HERE / "coop-loadout-ui-fixture.gml", fixture.with_suffix(".gml"))
    ready_path = add("objects", "obj_readyroom_manager")
    shutil.copytree(s.REPO / "objects/obj_readyroom_manager", ready_path.parent)
    ready_meta = s.read_yy(ready_path)
    ready_meta["parent"] = parent
    s.write_yy(ready_path, ready_meta)
    for name in ("obj_autosave_tests", "obj_game_over", "obj_battlestart_button"):
        meta = s.read_yy(s.REPO / "objects/obj_file_manager/obj_file_manager.yy")
        meta.update({"%Name": name, "name": name, "parent": parent, "persistent": False})
        event = meta["eventList"][0]
        meta["eventList"] = []
        if name == "obj_autosave_tests":
            for kind in (0, 3, 8):
                item = copy.deepcopy(event)
                item.update({"eventType": kind, "eventNum": 0})
                meta["eventList"].append(item)
        path = add("objects", name)
        s.write_yy(path, meta)
        if name == "obj_autosave_tests":
            path.with_name("Create_0.gml").write_text("fixture_configure(); fixture_checks();\n")
            path.with_name("Step_0.gml").write_text("fixture_step(); coop_ui_step();\n")
            path.with_name("Draw_0.gml").write_text("coop_ui_draw();\n")
    room_path = project / yyp["RoomOrderNodes"][0]["roomId"]["path"]
    room = s.read_yy(room_path)
    room["roomSettings"].update({"Width": 1920, "Height": 1080})
    s.write_yy(room_path, room)
    s.write_yy(project_file, yyp)
    s.write_yy(root / "manifest.json", {"app_id": app_id, "save_scope": "Synthetic controller only, no production save code",
        "sources": {name: hashlib.sha256((s.REPO / "scripts" / name / (name + ".gml")).read_bytes()).hexdigest()
                    for name in ("CoopUI", "add_to_deck", "deck_get_card_data")},
        "readyroom_events": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in (s.REPO / "objects/obj_readyroom_manager").glob("*.gml")}})
    return project_file


def main():
    cache = Path.home() / "Library/Caches/FVM-Reborn/coop-loadout-ui-tests"
    cache.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=cache))
    app_id = "io.github.9tempest.fvmreborn.loadout-ui-tests." + uuid.uuid4().hex
    print("Co-op loadout UI fixture: " + str(root), flush=True)
    project = prepare(root, app_id)
    runtime = Path(os.environ.get("FVM_GAMEMAKER_RUNTIME", "/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + s.VERSION))
    return s.build_and_run(root, project, runtime, app_id)


if __name__ == "__main__":
    sys.exit(main())
