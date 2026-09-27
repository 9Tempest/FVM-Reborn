#!/usr/bin/env python3
"""Exercise real CoopAudio with silent sound assets in an isolated native VM.

The production source is copied unchanged. A fixture macro maps room_coop to
the isolated test room; no session, network, game save or installed app is used.
"""
import copy
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import uuid
import wave

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fvm_audio_helpers", HERE / "test-autosave.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
helpers.NAME = "FVM-Coop-Audio-Tests"
REPO = helpers.REPO


def prepare(root, app_id):
    project_file = helpers.prepare(root, app_id)
    project = project_file.parent
    yyp = helpers.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name": "Harness", "path": "folders/Harness.yy"}
    for name in ("CoopAudio", "audio_fixture"):
        path = project / "scripts" / name / (name + ".yy")
        if name == "CoopAudio":
            shutil.copytree(REPO / "scripts" / name, path.parent)
            meta = helpers.read_yy(path)
            meta["parent"] = parent
        else:
            meta = {"$GMScript": "v1", "%Name": name, "name": name, "isCompatibility": False, "isDnD": False, "parent": parent, "resourceType": "GMScript", "resourceVersion": "2.0"}
        helpers.write_yy(path, meta)
        if name == "audio_fixture": shutil.copyfile(HERE / "coop-audio-fixture.gml", path.with_suffix(".gml"))
        yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
    for name in ("obj_autosave_tests", "obj_battle_music_controller"):
        meta = helpers.read_yy(REPO / "objects/obj_file_manager/obj_file_manager.yy")
        meta.update({"%Name": name, "name": name, "parent": parent, "persistent": False})
        meta["eventList"] = [e for e in meta["eventList"] if e["eventType"] == 0] if name == "obj_autosave_tests" else []
        path = project / "objects" / name / (name + ".yy")
        helpers.write_yy(path, meta)
        if name == "obj_autosave_tests": path.with_name("Create_0.gml").write_text("audio_run();\n")
        yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
    for name in ("mus_fixture_pre", "mus_fixture_elite", "snd_win", "snd_lose"):
        meta = helpers.read_yy(REPO / "sounds/snd_win/snd_win.yy")
        meta.update({"%Name": name, "name": name, "parent": parent, "preload": True, "duration": 2.0, "sampleRate": 44100, "soundFile": name + ".wav"})
        group = yyp["AudioGroups"][0]["name"]
        meta["audioGroupId"] = {"name": group, "path": "audiogroups/" + group}
        path = project / "sounds" / name / (name + ".yy")
        helpers.write_yy(path, meta)
        with wave.open(str(path.with_suffix(".wav")), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(44100)
            stream.writeframes(bytes(44100 * 2 * 2))
        yyp["resources"].append({"id": {"name": name, "path": str(path.relative_to(project))}})
    helpers.write_yy(project_file, yyp)
    helpers.write_yy(root / "manifest.json", {"app_id": app_id, "source_sha256": hashlib.sha256((REPO / "scripts/CoopAudio/CoopAudio.gml").read_bytes()).hexdigest(), "scope": "Native audio lifecycle with silent built-in test assets and synthetic session; no user data."})
    return project_file


def main():
    root = Path(tempfile.mkdtemp(prefix="fvm-coop-audio-", dir="/tmp"))
    app_id = "io.github.9tempest.fvmreborn.coop-audio-tests." + uuid.uuid4().hex
    print("Audio test workspace: " + str(root), flush=True)
    project = prepare(root, app_id)
    return helpers.build_and_run(root, project, Path("/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + helpers.VERSION), app_id)


if __name__ == "__main__":
    sys.exit(main())
