#!/usr/bin/env python3
"""Run production card-slot and grid placement logic in an isolated native VM.

Only input/audio builtins are substituted in temporary event copies. Synthetic
card definitions and inert plant objects keep this focused on selection, terrain,
stacking, upgrades, moving platforms and resource/cooldown transactions. Real
plant combat and networking are covered by the separate full-game fixture.
"""
import copy
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fvm_card_helpers", HERE / "test-autosave.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
helpers.NAME = "FVM-Card-Placement-Tests"
REPO = helpers.REPO


def prepare(root, app_id):
    project_file = helpers.prepare(root, app_id)
    project = project_file.parent
    yyp = helpers.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name":"Harness", "path":"folders/Harness.yy"}
    hashes = {}

    def register(path, meta):
        meta["parent"] = parent
        helpers.write_yy(path, meta)
        yyp["resources"].append({"id":{"name":meta["name"],"path":str(path.relative_to(project))}})

    for name in ("get_grid_position_from_world", "can_place_at_position", "card_created", "card_destroyed", "card_depth"):
        shutil.copytree(REPO / "scripts" / name, project / "scripts" / name)
        path = project / "scripts" / name / (name + ".yy")
        register(path, helpers.read_yy(path))
        hashes[str(path.with_suffix(".gml").relative_to(project))] = hashlib.sha256(path.with_suffix(".gml").read_bytes()).hexdigest()
    name = "placement_fixture"
    path = project / "scripts" / name / (name + ".yy")
    register(path, {"$GMScript":"v1","%Name":name,"name":name,"isCompatibility":False,"isDnD":False,"resourceType":"GMScript","resourceVersion":"2.0"})
    shutil.copyfile(HERE / "card-placement-fixture.gml", path.with_suffix(".gml"))
    template = helpers.read_yy(REPO / "objects/obj_card_slot/obj_card_slot.yy")
    for name in ("obj_autosave_tests", "obj_card_slot", "obj_small_fire", "obj_shovel_slot", "obj_platform", "obj_place_effect", "obj_card_preview", "obj_fixture_plant"):
        meta = copy.deepcopy(template)
        meta.update({"%Name":name,"name":name,"spriteId":None})
        meta["eventList"] = [e for e in template["eventList"] if (name == "obj_card_slot" and e["eventType"] != 8) or (name in ("obj_autosave_tests", "obj_fixture_plant") and e["eventType"] == 0)]
        path = project / "objects" / name / (name + ".yy")
        register(path, meta)
        if name == "obj_autosave_tests": path.with_name("Create_0.gml").write_text("placement_run();\n")
        if name == "obj_fixture_plant": path.with_name("Create_0.gml").write_text("plant_id=global.spawn_id; plant_type=global.spawn_type; feature_type=global.spawn_feature; shape=0; depth_value=0;\n")
        if name == "obj_card_slot":
            for event in ("Create_0.gml", "Step_0.gml", "Step_2.gml", "Other_10.gml"):
                source = (REPO / "objects" / name / event).read_text()
                hashes["objects/" + name + "/" + event] = hashlib.sha256(source.encode()).hexdigest()
                for builtin in ("mouse_check_button_pressed", "keyboard_check_pressed", "device_mouse_x_to_gui", "device_mouse_y_to_gui", "audio_play_sound"):
                    source = re.sub(r"\b" + builtin + r"\s*\(", "placement_" + builtin + "(", source)
                source = re.sub(r"\bmouse_x\b", "global.placement_mouse_x", source)
                source = re.sub(r"\bmouse_y\b", "global.placement_mouse_y", source)
                path.with_name(event).write_text(source)
    helpers.write_yy(project_file, yyp)
    helpers.write_yy(root / "manifest.json", {"app_id":app_id,"source_sha256":hashes,"scope":"Production card-slot events and placement/grid scripts; synthetic card metadata and inert plants; deterministic input/audio seams; no saves."})
    return project_file


def main():
    root = Path(tempfile.mkdtemp(prefix="fvm-card-placement-", dir="/tmp"))
    app_id = "io.github.9tempest.fvmreborn.card-placement-tests." + uuid.uuid4().hex
    print("Placement test workspace: " + str(root), flush=True)
    project = prepare(root, app_id)
    return helpers.build_and_run(root, project, Path("/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + helpers.VERSION), app_id)


if __name__ == "__main__":
    sys.exit(main())
