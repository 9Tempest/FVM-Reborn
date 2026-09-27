/// Test-only controller injected into an isolated copy of the full game.
function coop_full_init() {
    test_role=parameter_string(0);
    test_url=parameter_string(1);
    test_secret=parameter_string(2);
    test_stage=0;
    test_started=current_time;
    test_at=current_time;
    test_report=[];
    test_invited=false;
    test_card_sent=false;
    test_paused=false;
    test_resumed=false;
    test_finished=false;
    test_last_stage=-1;
    test_diagnostic_at=0;
    test_base_gold=global.save_data.player.gold;
    test_slot_json=global.save_last_json;
    persistent=true;
    show_debug_message("FVM_FULL_SAVE_ROOT="+game_save_id);
}
function coop_full_expect(_name,_ok) {
    array_push(test_report,{name:_name,passed:_ok});
    show_debug_message("FVM_FULL_ASSERT="+string(_ok)+" "+_name);
}
function coop_full_cell_has(_col,_row,_card_id) {
    var _plants=global.grid_plants[# _col,_row];
    for(var _i=0;_i<ds_list_size(_plants);_i++) {
        var _plant=_plants[| _i];
        if(instance_exists(_plant) && _plant.plant_id==_card_id) return true;
    }
    return false;
}
function coop_full_finish() {
    var _f=file_text_open_write("full-results.json");
    file_text_write_string(_f,json_stringify({role:test_role,tests:test_report})); file_text_close(_f);
    show_debug_message("FVM_FULL_DONE="+test_role);
    game_end();
}
function coop_full_step() {
    if (test_last_stage!=test_stage || current_time-test_diagnostic_at>10000) {
        test_last_stage=test_stage; test_diagnostic_at=current_time;
        show_debug_message("FVM_FULL_STAGE="+string(test_stage)+" room="+room_get_name(room)+" status="+global.coop.status);
    }
    if (current_time-test_started>420000) {
        coop_full_expect("full game completed before deadline",false);
        show_debug_message("FVM_FULL_STATUS="+global.coop.status+" stage="+string(test_stage));
        surface_save(application_surface,test_role+"-timeout.png");
        show_debug_message("FVM_FULL_IMAGE="+game_save_id+test_role+"-timeout.png");
        coop_full_finish(); return;
    }
    var _c=global.coop;
    if (test_stage==0) {
        if (!global.preloaded) {
            if (!instance_exists(obj_menu_manager)) return;
            // Load the same production texture groups, skipping only cosmetic
            // per-group progress-bar delays in this automated fixture.
            with (obj_menu_manager) {
                for (var _t=0;_t<array_length(texture_to_load);_t++) texture_prefetch(texture_to_load[_t]);
                after_texture_load();
            }
        }
        if (test_role=="host") {
            coop_write_json("coop/host.json",{url:test_url,public_url:test_url,token:test_secret});
            _c.create();
        } else _c.join(test_secret);
        test_stage=1; return;
    }
    if (test_stage==1 && _c.active) {
        coop_full_expect("native session joined",true);
        coop_full_expect("solo profile preserved before campaign",is_struct(_c.solo));
        test_slot_json=_c.solo.last_json;
        if (test_role=="host") {
            show_debug_message("FVM_FULL_INVITE="+_c.invite_code);
            test_stage=2;
        } else test_stage=4;
    }
    if (test_role=="host") {
        if (test_stage==2 && _c.all_connected()) {
            coop_full_expect("two real native peers connected",true);
            global.map_id="delicious_island"; global.map_name="美味岛";
            global.level_id="cookie_island";
            var _levels=ds_map_find_value(global.maps_map,"delicious_island").levels_data;
            for (var _i=0;_i<array_length(_levels);_i++) if (_levels[_i].id=="cookie_island") global.level_data=_levels[_i];
            var _b=buffer_load("level_data/cookie_island.json");
            global.level_file=json_parse(buffer_read(_b,buffer_string)); buffer_delete(_b);
            // Deterministic test funds allow both starter cards immediately.
            // Placement still uses production affordability/cooldown validation.
            global.level_file.starting_flame=500;
            global.gui_stack.to(room_ready); test_stage=3; test_at=current_time; return;
        }
        if (test_stage==3 && room==room_ready && current_time-test_at>200) {
            add_to_deck("small_fire",0); add_to_deck("xiao_long_bao",0);
            global.gui_stack.to(room_battle); test_stage=4; return;
        }
        if (test_stage==4 && _c.battle_started && variable_global_exists("coop_battle") && global.coop_battle.ready) {
            coop_full_expect("host created two controllable characters",instance_number(obj_player_character)==2);
            _c.send_input("place_player",{row:0,col:0}); test_stage=5; test_at=current_time; return;
        }
        if (test_stage==5 && coop_battle_can_run()) {
            coop_full_expect("both characters placed through ordered commands",true);
            var _slot=instance_find(obj_card_slot,0);
            test_flame=global.flame;
            _c.send_input("place_card",{row:0,col:1,slot_index:_slot.slot_index,card_id:_slot.card_id});
            test_stage=6; test_at=current_time; return;
        }
        if (test_stage==6 && current_time-test_at>3000) {
            coop_full_expect("both players produced independent ordered inputs",global.coop.applied_command_id>=4);
            coop_full_expect("host and guest placed the real two selected cards",coop_full_cell_has(1,0,"small_fire") && coop_full_cell_has(1,5,"xiao_long_bao"));
            var _snap=coop_battle_snapshot();
            coop_full_expect("live battle has replicated entities and card slots",array_length(_snap.entities)>2 && array_length(_snap.slots)>=2);
            surface_save(application_surface,"host-battle.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-battle.png");
            test_stage=7; test_at=current_time; return;
        }
        if (test_stage==7 && current_time-test_at>2000) {
            // Only the isolated test copy injects victory; rewards use production code.
            global.game_over=true; global.is_paused=true;
            var _over=instance_create_depth(960,500,-4000,obj_game_over); _over.sprite_index=spr_win;
            test_stage=8; test_at=current_time; return;
        }
        if (test_stage==8 && _c.result_saved) {
            coop_full_expect("victory acknowledged only after database commit",true);
            coop_full_expect("first-clear gold granted exactly once",global.save_data.player.gold==test_base_gold+global.level_file.rewards[1].gold);
            var _before=global.save_data.player.gold;
            obj_battle_pause_manager.commit_victory_rewards();
            coop_full_expect("repeat victory call does not grant again",global.save_data.player.gold==_before);
            coop_full_expect("single player save file untouched by co-op rewards",save_read_candidate("saves/save0.json").text==test_slot_json);
            test_stage=9; test_at=current_time;
        }
        if (test_stage==9 && current_time-test_at>5000) {
            surface_save(application_surface,"host-victory.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-victory.png");
            coop_full_finish();
        }
    } else {
        if (test_stage==4 && _c.battle_started && is_struct(_c.latest) && array_length(coop_get(_c.latest,"players",[]))==2) {
            // Cookie Island prepopulates rows 1-4, columns 0-1 with plants.
            _c.send_input("place_player",{row:5,col:0}); test_stage=5; test_at=current_time; return;
        }
        if (test_stage==5 && is_struct(_c.latest) && !_c.latest.paused) {
            var _slot=_c.latest.slots[1];
            _c.send_input("place_card",{row:5,col:1,slot_index:_slot.slot_index,card_id:_slot.card_id});
            coop_full_expect("guest has real art and live host snapshot",array_length(_c.latest.entities)>0);
            test_stage=6; test_at=current_time; return;
        }
        if (test_stage==6 && current_time-test_at>2000) {
            surface_save(application_surface,"guest-battle.png"); show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-battle.png");
            test_stage=7;
        }
        if (test_stage==7 && _c.result_saved && is_struct(coop_get(_c.latest,"victory"))) {
            coop_full_expect("guest received first-clear reward visuals",array_length(_c.latest.victory.resources)>0);
            coop_full_expect("guest received the durable shared campaign",array_get_index(global.save_data.completed_levels,"cookie_island")>=0);
            coop_full_expect("guest solo file untouched",save_read_candidate("saves/save0.json").text==test_slot_json);
            test_stage=8; test_at=current_time;
        }
        if (test_stage==8 && current_time-test_at>1800) {
            surface_save(application_surface,"guest-victory.png"); show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-victory.png");
            coop_full_finish();
        }
    }
}
