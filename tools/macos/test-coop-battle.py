#!/usr/bin/env python3
"""Exercise the real host battle router in an isolated GameMaker VM.

A synthetic session and tiny stand-in scene test owner/sequence validation,
shared slots, pause/disconnect behavior, snapshots, and result ordering. Game
save scripts and user files are excluded. Card/equipment simulation is covered
by the full game build; this fixture tests the bridge's actual command routing.
"""
import copy
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fvm_battle_helpers", HERE / "test-autosave.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
helpers.NAME = "FVM-Coop-Battle-Tests"
REPO = helpers.REPO


def prepare(root, app_id):
    project_file = helpers.prepare(root, app_id)
    project = project_file.parent
    yyp = helpers.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name":"Harness", "path":"folders/Harness.yy"}
    for name in ("CoopBattle", "get_grid_position_from_world"):
        shutil.copytree(REPO / "scripts" / name, project / "scripts" / name)
        path = project / "scripts" / name / (name + ".yy")
        meta = helpers.read_yy(path)
        meta["parent"] = parent
        helpers.write_yy(path, meta)
        yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    name = "bridge_fixture"
    path = project / "scripts" / name / (name + ".yy")
    helpers.write_yy(path, {"$GMScript":"v1","%Name":name,"name":name,"isCompatibility":False,"isDnD":False,"parent":parent,"resourceType":"GMScript","resourceVersion":"2.0"})
    shutil.copyfile(HERE / "coop-battle-fixture.gml", path.with_suffix(".gml"))
    yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    template = helpers.read_yy(REPO / "objects/obj_battle_pause_manager/obj_battle_pause_manager.yy")
    for name in ("obj_autosave_tests", "obj_battle", "obj_player_character", "obj_card_slot", "obj_shovel_slot", "obj_platform", "obj_game_over", "obj_card_preview", "obj_battle_pause_manager", "obj_fixture_gem"):
        obj = copy.deepcopy(template)
        obj.update({"%Name":name,"name":name,"parent":parent})
        obj["eventList"] = []
        if name in ("obj_autosave_tests", "obj_player_character"):
            obj["eventList"] = [e for e in template["eventList"] if e["eventType"] == 0]
        path = project / "objects" / name / (name + ".yy")
        helpers.write_yy(path, obj)
        if name == "obj_autosave_tests": path.with_name("Create_0.gml").write_text("bridge_run();\n")
        if name == "obj_player_character": path.with_name("Create_0.gml").write_text("bridge_player_create();\n")
        yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    for name in ("spr_win", "spr_lose"):
        shutil.copytree(REPO / "sprites" / name, project / "sprites" / name)
        path = project / "sprites" / name / (name + ".yy")
        meta = helpers.read_yy(path)
        meta["parent"] = parent
        group = yyp["TextureGroups"][0]["name"]
        meta["textureGroupId"] = {"name":group,"path":"texturegroups/"+group}
        helpers.write_yy(path, meta)
        yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    helpers.write_yy(project_file, yyp)
    helpers.write_yy(root / "manifest.json", {"app_id":app_id,"source_sha256":hashlib.sha256((REPO / "scripts/CoopBattle/CoopBattle.gml").read_bytes()).hexdigest(),"scope":"Real bridge/router with synthetic session and dummy scene callbacks; no save files."})
    return project_file


def main():
    root = Path(tempfile.mkdtemp(prefix="fvm-coop-battle-", dir="/tmp"))
    app_id = "io.github.9tempest.fvmreborn.coop-battle-tests." + uuid.uuid4().hex
    print("Bridge test workspace: " + str(root), flush=True)
    project = prepare(root, app_id)
    return helpers.build_and_run(root, project, Path("/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-"+helpers.VERSION), app_id)


if __name__ == "__main__":
    sys.exit(main())
