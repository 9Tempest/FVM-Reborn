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
    test_loadout_selected=false;
    test_loadout_ready=false;
    test_loadout_at=0;
    test_loadout_image=false;
    test_guest_second=false;
    test_shared_menu=false; test_shared_craft=false; test_shared_map=false; test_shared_clear=false;
    test_shared_at=0; test_shared_seq=0;
    test_input_at=0; test_input_visible=false;
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
function coop_full_slot(_owner,_card) {
    var _slots=coop_battle_snapshot().slots;
    for(var _i=0;_i<array_length(_slots);_i++) if(_slots[_i].owner==_owner && _slots[_i].card_id==_card) return _slots[_i];
    return undefined;
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
    if (test_role=="guest" && test_shared_craft && !test_shared_map && !test_shared_clear
        && _c.active && !coop_screen_visible() && !is_struct(_c.preparation) && !_c.battle_started) {
        test_shared_clear=true;
        coop_full_expect("shared game screen clears when host returns to co-op lobby",true);
    }
    if (test_role=="guest" && coop_screen_visible()) {
        var _share=coop_screen_state();
        if (_share.room=="room_menu" && !test_shared_menu) {
            coop_full_expect("guest receives host main-menu game screen",_share.received_seq>0);
            surface_save(application_surface,"guest-shared-menu.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-shared-menu.png");
            test_shared_menu=true; test_shared_at=current_time; test_shared_seq=_share.received_seq;
        }
        if (_share.room=="room_menu" && test_shared_menu && !test_shared_craft && current_time-test_shared_at>5000) {
            coop_full_expect("shared menu continues updating while host uses crafting",_share.received_seq>test_shared_seq);
            surface_save(application_surface,"guest-shared-craft.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-shared-craft.png");
            test_shared_craft=true;
        }
        if (_share.room=="room_map" && !test_shared_map) {
            coop_full_expect("guest sees host level selection instead of waiting",test_shared_menu && test_shared_craft && test_shared_clear);
            surface_save(application_surface,"guest-shared-map.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-shared-map.png");
            test_shared_map=true;
        }
    }
    // Use the real preparation RPCs and UI state. Selecting cards is separate
    // from Ready, and the guest deliberately waits so one-sided Ready is tested.
    if (_c.active && is_struct(_c.preparation) && !_c.battle_started && !_c.result_saved) {
        var _wanted=test_role=="host" ? ["small_fire","xiao_long_bao"] : ["xiao_long_bao","small_fire"];
        if (!test_loadout_selected && !_c.loadout_pending) {
            test_loadout_selected=_c.set_loadout(_wanted,false); test_loadout_at=current_time;
        }
        if (test_loadout_selected && !_c.loadout_pending && json_stringify(_c.loadout_draft)==json_stringify(_wanted)) {
            if (!test_loadout_image && current_time-test_loadout_at>600) {
                coop_full_expect("personal draft and shared library shown",array_length(coop_loadout_cards())>=4 && array_length(_c.loadout_draft)==2);
                coop_full_expect("loadout UI retains the correct player role",_c.role==test_role);
                show_debug_message("FVM_FULL_LOADOUT_ROLE="+test_role+"/"+_c.role);
                surface_save(application_surface,test_role+"-loadout.png");
                show_debug_message("FVM_FULL_IMAGE="+game_save_id+test_role+"-loadout.png");
                test_loadout_image=true;
            }
            var _delay=test_role=="host" ? 1300 : 3600;
            if (!test_loadout_ready && current_time-test_loadout_at>_delay) {
                coop_full_expect("connected peers cannot start before both Ready",_c.room_status!="running");
                test_loadout_ready=_c.set_loadout(_wanted,true);
            }
            // A real conflicting card edit cancels Ready; exercise an explicit
            // reconfirmation if that happened while the other deck was arriving.
            if (test_loadout_ready && !coop_get(coop_get(_c.preparation.selections,_c.player_id),"ready",false)
                && current_time-test_loadout_at>_delay+1500) test_loadout_ready=false;
        }
    }
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
        // A focus-loss autosave can update only solo play time during the TLS
        // handshake. Freeze the actual file once campaign isolation is active.
        test_slot_json=save_read_candidate("saves/save0.json").text;
        coop_full_expect("joining preserves all solo progress before campaign",
            coop_campaign_progress(test_slot_json)==coop_campaign_progress(_c.solo.last_json));
        if (test_role=="host") {
            show_debug_message("FVM_FULL_INVITE="+_c.invite_code);
            test_stage=2;
        } else test_stage=4;
    }
    if (test_role=="host") {
        if (test_stage==2 && _c.all_connected()) {
            coop_full_expect("two real native peers connected",true);
            coop_full_expect("highest default difficulty is selected",global.difficulty==3);
            global.map_id="delicious_island"; global.map_name="美味岛";
            global.gui_stack.to(room_menu); test_stage=20; test_at=current_time; return;
        }
        if (test_stage==20 && room==room_menu && current_time-test_at>3000) {
            with (obj_player_menu_btn) if (target_screen=="craft") event_perform(ev_mouse,ev_left_press);
            coop_full_expect("host opens the real crafting interface",instance_exists(obj_craft_bg));
            test_stage=21; test_at=current_time; return;
        }
        if (test_stage==21 && current_time-test_at>8000) {
            var _share=coop_screen_state();
            coop_full_expect("host shares the composed game and GUI surface",surface_exists(_share.surface) && _share.sequence>0);
            show_debug_message("FVM_FULL_SCREEN_METRIC="+json_stringify({room:room_get_name(room),encode_ms:_share.encode_ms,base64_bytes:_share.frame_bytes}));
            if (surface_exists(_share.surface)) {
                surface_save(_share.surface,"host-shared-craft.png");
                show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-shared-craft.png");
            }
            global.gui_stack.to(room_coop); test_stage=23; test_at=current_time; return;
        }
        if (test_stage==23 && current_time-test_at>3000) {
            global.gui_stack.to(room_map); test_stage=22; test_at=current_time; return;
        }
        if (test_stage==22 && room==room_map && current_time-test_at>4000) {
            var _share=coop_screen_state();
            if (surface_exists(_share.surface)) {
                surface_save(_share.surface,"host-shared-map.png");
                show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-shared-map.png");
            }
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
        if (test_stage==3 && _c.battle_started && room==room_battle) {
            coop_full_expect("both Ready automatically launch the selected level",_c.match_config.per_player_loadouts && _c.match_config.level_id=="cookie_island");
            test_stage=4; return;
        }
        if (test_stage==4 && _c.battle_started && variable_global_exists("coop_battle") && global.coop_battle.ready) {
            coop_full_expect("host created two controllable characters",instance_number(obj_player_character)==2);
            _c.send_input("place_player",{row:0,col:0}); test_stage=5; test_at=current_time; return;
        }
        if (test_stage==5 && coop_battle_can_run()) {
            coop_full_expect("both characters placed through ordered commands",true);
            var _slot=coop_full_slot(_c.player_id,"small_fire");
            coop_full_expect("host slot retains its player owner after creation",is_struct(_slot));
            if (!is_struct(_slot)) { coop_full_finish(); return; }
            test_flame=global.flame;
            _c.send_input("place_card",{row:0,col:1,slot_index:_slot.slot_index,card_id:_slot.card_id});
            test_stage=6; test_at=current_time; return;
        }
        if (test_stage==6 && current_time-test_at>3000) {
            coop_full_expect("both players produced independent ordered inputs",global.coop.applied_command_id>=4);
            coop_full_expect("both can place the same card with independent cooldown",coop_full_cell_has(1,0,"small_fire") && coop_full_cell_has(1,5,"small_fire"));
            coop_full_expect("guest can use its independently ordered second card",coop_full_cell_has(2,5,"xiao_long_bao"));
            var _snap=coop_battle_snapshot();
            coop_full_expect("live battle has two separately owned decks",array_length(_snap.entities)>2 && array_length(_snap.slots)==4);
            var _guest="";
            for(var _i=0;_i<array_length(_c.players);_i++) if(_c.players[_i].player_id!=_c.player_id) _guest=_c.players[_i].player_id;
            var _host_card=coop_full_slot(_c.player_id,"xiao_long_bao"),_guest_card=coop_full_slot(_guest,"xiao_long_bao");
            coop_full_expect("guest cooldown does not cool down the host card",_host_card.remaining_cd==0 && _guest_card.remaining_cd>0);
            coop_full_expect("guest spending affects only its own balance",coop_flame_get(_c.player_id)-coop_flame_get(_guest)==_guest_card.cost);
            var _hb=coop_flame_get(_c.player_id),_gb=coop_flame_get(_guest);
            coop_flame_collect(25);
            coop_full_expect("25 flame gives each player exactly 15",coop_flame_get(_c.player_id)==_hb+15 && coop_flame_get(_guest)==_gb+15);
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
            coop_full_expect("saved result is not overwritten by late snapshot errors",string_pos("联机提示：",_c.status)==0);
            surface_save(application_surface,"host-victory.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-victory.png");
            global.gui_stack.to(room_coop);
            _c.prepare_loadout(global.level_data.id,global.level_data.name,deck_slot_max());
            test_stage=10; return;
        }
        if (test_stage==10 && is_struct(_c.preparation) && !_c.loadout_pending) {
            var _choice=coop_get(_c.preparation.selections,_c.player_id);
            coop_full_expect("host cached deck restored for the same level",_choice.cached && json_stringify(_choice.deck)==json_stringify(["small_fire","xiao_long_bao"]));
            coop_full_expect("cached deck never restores Ready automatically",!_choice.ready && !_c.both_loadouts_ready());
            test_stage=11; test_at=current_time;
        }
        if (test_stage==11 && current_time-test_at>2000) {
            surface_save(application_surface,"host-cached-loadout.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"host-cached-loadout.png");
            coop_full_finish();
        }
    } else {
        if (test_stage==4 && _c.battle_started && is_struct(_c.latest) && array_length(coop_get(_c.latest,"players",[]))==2) {
            coop_full_expect("shared-screen view yields to each player's game HUD",test_shared_map && !coop_screen_visible());
            // Cookie Island prepopulates rows 1-4, columns 0-1 with plants.
            _c.send_input("place_player",{row:5,col:0}); test_stage=5; test_at=current_time; return;
        }
        if (test_stage==5 && is_struct(_c.latest) && !_c.latest.paused) {
            var _slots=coop_guest_slots(_c.latest,_c.player_id);
            coop_full_expect("guest slots retain their player owner in the snapshot",array_length(_slots)==2);
            if (array_length(_slots)!=2) { coop_full_finish(); return; }
            var _slot=_slots[1];
            _c.send_input("place_card",{row:5,col:1,slot_index:_slot.slot_index,card_id:_slot.card_id});
            test_input_at=current_time;
            coop_full_expect("guest has real art and live host snapshot",array_length(_c.latest.entities)>0);
            coop_full_expect("guest HUD shows only its own two slots",array_length(_slots)==2 && _slots[0].card_id=="xiao_long_bao" && _slots[1].card_id=="small_fire");
            test_stage=6; test_at=current_time; return;
        }
        if (test_stage==6 && !test_guest_second && current_time-test_at>250) {
            var _slot=coop_guest_slots(_c.latest,_c.player_id)[0];
            _c.send_input("place_card",{row:5,col:2,slot_index:_slot.slot_index,card_id:_slot.card_id});
            test_guest_second=true;
        }
        if (test_stage==6 && !test_input_visible) {
            var _own_slots=coop_guest_slots(_c.latest,_c.player_id);
            if (array_length(_own_slots)==2 && _own_slots[1].remaining_cd>0) {
                test_input_visible=true;
                show_debug_message("FVM_FULL_INPUT_VISIBLE_MS="+string(current_time-test_input_at));
            }
        }
        if (test_stage==6 && current_time-test_at>2000) {
            coop_full_expect("guest sees its host-confirmed placement and cooldown",test_input_visible);
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
            _c.battle_started=false;_c.latest=undefined;test_stage=9;
        }
        if (test_stage==9 && is_struct(_c.preparation)) {
            var _choice=coop_get(_c.preparation.selections,_c.player_id);
            coop_full_expect("guest cached deck stays separate from host cache",_choice.cached && json_stringify(_choice.deck)==json_stringify(["xiao_long_bao","small_fire"]));
            coop_full_expect("guest must explicitly Ready again",!_choice.ready && _c.room_status!="running");
            surface_save(application_surface,"guest-cached-loadout.png");
            show_debug_message("FVM_FULL_IMAGE="+game_save_id+"guest-cached-loadout.png");
            coop_full_finish();
        }
    }
}
