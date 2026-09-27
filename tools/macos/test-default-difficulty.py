#!/usr/bin/env python3
"""Verify production difficulty configuration and level selection in an isolated VM.

Copies the actual configuration block, difficulty button and level-selection
Mouse events. Only sound/texture prefetch calls are omitted. Reads/writes use
real GameMaker INI and buffer APIs under a fresh test-only sandbox identity.
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
spec = importlib.util.spec_from_file_location("difficulty_helpers", HERE / "test-autosave.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
helpers.NAME = "FVM-Difficulty-Tests"
REPO = helpers.REPO


def prepare(root, app_id):
    project_file = helpers.prepare(root, app_id)
    project = project_file.parent
    yyp = helpers.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if r["id"]["path"].startswith("rooms/")]
    shutil.rmtree(project / "scripts")
    shutil.rmtree(project / "objects")
    parent = {"name": "Harness", "path": "folders/Harness.yy"}
    paths = ["objects/obj_game_init/Create_0.gml", "objects/obj_difficulty_select_btn/Mouse_4.gml", "objects/obj_levelselect_button/Mouse_4.gml", "scripts/ini_bool_functions/ini_bool_functions.gml"]
    sources = [(REPO / p).read_text() for p in paths]
    config = sources[0].split("// 初始化全局设置（如果不存在配置文件）", 1)[1].split("audio_group_set_gain(music", 1)[0]
    difficulty_click = sources[1].replace("audio_play_sound(snd_button,0,0)", "// Audio omitted in headless fixture.")
    level_click = sources[2].replace("audio_play_sound(snd_button, 0, 0);", "// Audio omitted in headless fixture.").replace('texture_prefetch("cards")', "// Texture prefetch omitted in headless fixture.")
    code = sources[3] + '''\n#macro room_battle -10
#macro room_ready 42
#macro room_tower_cake 43
function show_notice(_message, _duration) { }
function difficulty_config_read() {\n''' + config + "\n}\nfunction difficulty_click() {\n" + difficulty_click + "\n}\nfunction difficulty_level_click() {\n" + level_click + '''
}
function difficulty_expect(_name, _ok) {
    array_push(global.test_results, {name:_name,passed:_ok});
}
function difficulty_config_value() {
    ini_open("config.ini"); var _v=ini_read_real("settings","difficulty",-1); ini_close(); return _v;
}
function difficulty_write_json(_path,_data) {
    var _f=file_text_open_write(_path); file_text_write_string(_f,json_stringify(_data)); file_text_close(_f);
}
function difficulty_run() {
    global.test_results=[];
    try {
        if (string_pos("difficulty-tests",game_save_id)<=0) throw "Refusing non-test sandbox";
        global.keybind_config=[]; global.keybind_map=ds_map_create();
        if(file_exists("config.ini")) file_delete("config.ini");
        difficulty_config_read();
        difficulty_expect("fresh configuration defaults to highest existing difficulty",global.difficulty==3);
        difficulty_expect("fresh configuration persists highest difficulty",difficulty_config_value()==3);
        ini_open("config.ini"); ini_key_delete("settings","difficulty"); ini_close();
        difficulty_config_read();
        difficulty_expect("missing difficulty key defaults to highest",global.difficulty==3);
        for(var _v=0;_v<=3;_v++) {
            ini_open("config.ini"); ini_write_real("settings","difficulty",_v); ini_close();
            difficulty_config_read();
            difficulty_expect("existing manual difficulty "+string(_v)+" survives initialization",global.difficulty==_v && difficulty_config_value()==_v);
        }
        config_key="difficulty"; state=3; b_type="next";
        difficulty_click();
        difficulty_expect("highest difficulty next button wraps to easiest",global.difficulty==0 && difficulty_config_value()==0);
        difficulty_config_read();
        difficulty_expect("manual UI difficulty survives restart",global.difficulty==0);
        state=0; b_type="prev"; difficulty_click();
        difficulty_expect("previous button selects existing highest",global.difficulty==3 && difficulty_config_value()==3);
        var _ui=instance_create_depth(0,0,0,obj_player_info_ui); _ui.menu_type=0;
        global.gui_stack={to:function(_target){global.test_destination=_target;}};
        global.maps_map=ds_map_create(); global.map_id="fixture";
        ds_map_add(global.maps_map,"fixture",{levels_data:[{id:"fixture_level"}]});
        directory_create("level_data");
        difficulty_write_json("level_data/normal.json",{variant:"normal"});
        difficulty_write_json("level_data/hard.json",{variant:"hard"});
        on_click=true; unlock=true; level_index=0; target_level_id="fixture_level";
        target_level_file="normal.json"; target_level_file_hard="hard.json";
        global.coop=undefined; difficulty_level_click();
        difficulty_expect("solo highest selects actual hard level data",global.level_file.variant=="hard" && global.difficulty==3 && global.test_destination==room_ready);
        global.coop={active:true,role:"host"}; difficulty_level_click();
        difficulty_expect("co-op host highest uses same hard level selection",global.level_file.variant=="hard" && global.difficulty==3 && global.level_data.id==target_level_id);
        state=1; b_type="prev"; difficulty_click(); // Explicitly selects easy difficulty 0.
        difficulty_level_click();
        difficulty_expect("manual easier choice remains respected in host selection",global.level_file.variant=="normal" && global.difficulty==0);
    } catch(_error) {
        array_push(global.test_results,{name:"unexpected native error",passed:false,detail:string(_error)});
    }
    var _passed=0;
    for(var _i=0;_i<array_length(global.test_results);_i++) if(global.test_results[_i].passed) _passed++;
    show_debug_message("FVM_AUTOSAVE_RESULT="+json_stringify({passed:_passed,total:array_length(global.test_results),tests:global.test_results}));
    game_end();
}
'''
    name = "difficulty_fixture"
    path = project / "scripts" / name / (name + ".yy")
    helpers.write_yy(path, {"$GMScript":"v1","%Name":name,"name":name,"isCompatibility":False,"isDnD":False,"parent":parent,"resourceType":"GMScript","resourceVersion":"2.0"})
    path.with_suffix(".gml").write_text(code)
    yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    template = helpers.read_yy(REPO / "objects/obj_file_manager/obj_file_manager.yy")
    for name in ("obj_autosave_tests", "obj_player_info_ui"):
        obj = copy.deepcopy(template)
        obj.update({"%Name":name,"name":name,"parent":parent,"parentObjectId":None,"spriteId":None,"spriteMaskId":None,"visible":False,"persistent":False,"eventList":[]})
        if name == "obj_autosave_tests": obj["eventList"] = [e for e in template["eventList"] if e["eventType"] == 0]
        path = project / "objects" / name / (name + ".yy")
        helpers.write_yy(path, obj)
        if name == "obj_autosave_tests": path.with_name("Create_0.gml").write_text("difficulty_run();\n")
        yyp["resources"].append({"id":{"name":name,"path":str(path.relative_to(project))}})
    helpers.write_yy(project_file, yyp)
    helpers.write_yy(root / "manifest.json", {"app_id":app_id,"source_sha256":dict(zip(paths,[hashlib.sha256(s.encode()).hexdigest() for s in sources])),"scope":"Real config init block, difficulty mouse event and level selection event; only audiovisual calls omitted."})
    return project_file


def main():
    root = Path(tempfile.mkdtemp(prefix="fvm-difficulty-", dir="/tmp"))
    app_id = "io.github.9tempest.fvmreborn.difficulty-tests." + uuid.uuid4().hex
    print("Difficulty test workspace: " + str(root), flush=True)
    project = prepare(root, app_id)
    return helpers.build_and_run(root, project, Path("/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-"+helpers.VERSION), app_id)


if __name__ == "__main__":
    sys.exit(main())
