function bridge_expect(_name, _passed) { array_push(global.bridge_tests, {name:_name, passed:_passed}); }
// Audio lifecycle is exercised by the separate native audio fixture.
function coop_audio_snapshot() { return {}; }
function deck_slot_max() { return 3; }
function deck_slot_is_empty(_i) { return true; }
function get_card_info_simple(_id) {
    return array_get_index(["fixture-card","host-card","guest-card"],_id) >= 0 ? {shape:0,level:0} : false;
}
function deck_get_card_data(_id,_shape) { return global.bridge_card_data; }
function bridge_slot_create() {
    if (!variable_instance_exists(id,"coop_owner")) coop_owner = "";
    info_got = true; card_spr = spr_win; place_preview = undefined;
    current_cost = 50; cooldown = 420; cooldown_timer = 420; is_ready = true; clevel = 0; cshape = 0;
    try_place_once = function(_x,_y,_ordered,_owner) {
        if (cooldown_timer < cooldown || !coop_flame_spend(coop_owner,current_cost)) return false;
        cooldown_timer = 0; is_ready = false; global.bridge_placed++;
        return _ordered && _owner == coop_owner;
    };
}
function bridge_player_create() {
    coop_owner = ""; is_placed = false; grid_row = -1; grid_col = -1; hp = 600; max_hp = 600;
    try_place_player = function(_x, _y) {
        var _cell = get_grid_position_from_world(_x,_y);
        grid_row = _cell.row; grid_col = _cell.col; x = _x; y = _y; is_placed = true;
        return true;
    };
}
function bridge_packet(_owner, _action, _payload) {
    var _seq = variable_struct_exists(global.bridge_seqs, _owner) ? variable_struct_get(global.bridge_seqs, _owner) + 1 : 1;
    variable_struct_set(global.bridge_seqs, _owner, _seq);
    return {player_id:_owner,action:_action,payload:_payload,seq:_seq,match_id:"fixture-match"};
}
function bridge_run() {
    global.bridge_tests = []; global.bridge_seqs = {}; global.bridge_placed = 0;
    global.bridge_shovels = 0; global.bridge_gems = 0; global.bridge_gem_owner = "";
    global.bridge_starts = 0; global.bridge_snapshots = 0; global.bridge_results = 0;
    global.game_over = false; global.flame = 300;
    global.grid_offset_x = 100; global.grid_offset_y = 100;
    global.grid_cell_size_x = 100; global.grid_cell_size_y = 100;
    global.grid_cols = 9; global.grid_rows = 6;
    global.level_data = {id:"fixture-level",name:"测试关卡",level_sprite:spr_win};
    global.coop = {active:true,role:"host",player_id:"host",match_id:"fixture-match",battle_started:false,connected:true,
        players:[{player_id:"host",connected:true},{player_id:"guest",connected:true}],
        all_connected:function(){return connected && players[0].connected && players[1].connected;},
        start_battle:function(_level){global.bridge_starts++; return global.bridge_starts > 1;},
        send_snapshot:function(_state){global.bridge_snapshots++; global.bridge_last_snapshot = _state;},
        submit_result:function(_outcome){global.bridge_results++; global.bridge_last_result = _outcome;}
    };
    var _battle = instance_create_depth(0,0,0,obj_battle);
    _battle.map_spr_index = 0; _battle.battle_time = 60; _battle.time_limit = 18000; _battle.current_wave = 1; _battle.total_wave = 5;
    instance_create_depth(0,0,0,obj_player_character);
    coop_battle_begin();
    bridge_expect("begin waits for server acknowledgement", global.bridge_starts == 1 && global.is_paused && !global.coop_battle.ready);
    global.coop_battle.start_retry_at = -1;
    coop_battle_tick();
    bridge_expect("deferred start retries after campaign ACK", global.bridge_starts == 2 && global.coop_battle.start_requested);
    coop_battle_tick();
    bridge_expect("successful start is not sent repeatedly", global.bridge_starts == 2);
    global.coop.battle_started = true;
    coop_battle_ready(); coop_battle_ready();
    bridge_expect("ack creates exactly two owned players", instance_number(obj_player_character) == 2 && instance_exists(coop_player_instance("host")) && instance_exists(coop_player_instance("guest")));
    coop_battle_command(bridge_packet("host","place_player",{row:0,col:0}));
    bridge_expect("one placed player does not resume simulation", global.is_paused && !coop_battle_can_run());
    coop_battle_command(bridge_packet("guest","place_player",{row:1,col:0}));
    bridge_expect("host and guest sequence one both accepted", coop_player_instance("host").is_placed && coop_player_instance("guest").is_placed);
    bridge_expect("both players resume simulation", !global.is_paused && coop_battle_can_run());
    var _slot = instance_create_depth(20,30,0,obj_card_slot);
    _slot.slot_index = 1; _slot.card_id = "fixture-card"; _slot.info_got = true;
    _slot.card_spr = spr_win; _slot.place_preview = undefined; _slot.current_cost = 50;
    _slot.cooldown = 420; _slot.cooldown_timer = 420; _slot.is_ready = true; _slot.clevel = 0; _slot.cshape = 0;
    _slot.try_place_once = function(_x,_y,_ordered) { global.bridge_placed++; global.flame -= 50; return _ordered; };
    var _packet = bridge_packet("guest","place_card",{row:2,col:2,slot_index:1,card_id:"fixture-card"});
    bridge_expect("guest shared-deck command reaches host once", coop_battle_command(_packet) && global.bridge_placed == 1 && global.flame == 250);
    bridge_expect("duplicate sequence cannot spend twice", !coop_battle_command(_packet) && global.bridge_placed == 1 && global.flame == 250);
    bridge_expect("unknown player rejected", !coop_battle_command(bridge_packet("intruder","place_card",{row:2,col:2,slot_index:1,card_id:"fixture-card"})));
    bridge_expect("card identity must match host slot", !coop_battle_command(bridge_packet("host","place_card",{row:2,col:2,slot_index:1,card_id:"forged-card"})));
    _packet = bridge_packet("host","place_card",{row:2,col:2,slot_index:1,card_id:"fixture-card"}); _packet.match_id = "old-match";
    bridge_expect("wrong match rejected", !coop_battle_command(_packet));
    bridge_expect("out-of-grid placement rejected", !coop_battle_command(bridge_packet("host","place_card",{row:6,col:2,slot_index:1,card_id:"fixture-card"})));
    coop_battle_command(bridge_packet("guest","pause_vote",{paused:true}));
    bridge_expect("either player can pause", global.is_paused && !coop_battle_can_run());
    var _paused_state = coop_battle_snapshot();
    bridge_expect("pause votes identify the player in the snapshot", _paused_state.pause_votes[$ "guest"] && !_paused_state.pause_votes[$ "host"]);
    bridge_expect("paused battle rejects planting", !coop_battle_command(bridge_packet("host","place_card",{row:2,col:2,slot_index:1,card_id:"fixture-card"})));
    coop_battle_command(bridge_packet("guest","pause_vote",{paused:false}));
    global.coop.players[1].connected = false;
    coop_battle_tick();
    bridge_expect("disconnect pauses simulation", global.is_paused && !coop_battle_can_run());
    global.coop.players[1].connected = true; coop_battle_tick();
    bridge_expect("reconnected ready pair can resume", !global.is_paused);
    var _shovel = instance_create_depth(0,0,0,obj_shovel_slot);
    _shovel.try_shovel_once = function(_x,_y,_ordered){global.bridge_shovels++; return _ordered;};
    coop_battle_command(bridge_packet("guest","shovel",{row:2,col:2}));
    bridge_expect("shovel routes through host method", global.bridge_shovels == 1);
    var _gem = instance_create_depth(0,0,0,obj_fixture_gem);
    _gem.coop_gem_index = 0; _gem.gem_id = "fixture-gem"; _gem.cooldown = 600; _gem.cooldown_timer = 0;
    _gem.try_use_gem = function(_player,_ordered){global.bridge_gems++; global.bridge_gem_owner = _player.coop_owner; return _ordered;};
    coop_battle_command(bridge_packet("guest","use_gem",{gem_index:0,gem_id:"fixture-gem"}));
    bridge_expect("gem uses the invoking player's character", global.bridge_gems == 1 && global.bridge_gem_owner == "guest");
    _battle.sprite_index = spr_win; _battle.depth = 100;
    coop_player_instance("host").sprite_index = spr_win; coop_player_instance("host").depth = -100;
    _battle.maxhp = 500; _battle.hp = 250; _battle.is_frozen = true; _battle.ice_sprite = spr_win;
    _battle.is_scare = true; _battle.is_stun = true; _battle.stun_sprite = spr_win; _battle.stun_timer = 10;
    _battle.flash_value = 100; _battle.flash_color = c_red; global.enemy_hpbar = true;
    var _boss_bar = instance_create_depth(0,0,0,obj_boss_hpbar);
    _boss_bar.target_boss = _battle; _boss_bar.boss_id = ""; _boss_bar.boss_name = "Fixture Boss";
    _boss_bar.icon_spr = spr_win; _boss_bar.bar_width = 1200;
    var _hud_objects = [obj_flame_manager,obj_world_map_button,obj_level_progress_bar,obj_battle_timer_display,obj_battle_pause_manager,obj_player_info_ui];
    for(var _i=0;_i<array_length(_hud_objects);_i++) {
        var _hud=instance_create_depth(0,0,-900,_hud_objects[_i]); _hud.sprite_index=spr_win;
    }
    var _plant=instance_create_depth(0,0,-50,obj_fixture_plant); _plant.sprite_index=spr_win; _plant.plant_type="normal";
    var _projectile=instance_create_depth(0,0,25,obj_fixture_projectile); _projectile.sprite_index=spr_win;
    var _snapshot = coop_battle_snapshot();
    bridge_expect("gem display name safely falls back without metadata", _snapshot.gems[0].name == "fixture-gem");
    _gem.gem_info = {name:"激光宝石"};
    _snapshot = coop_battle_snapshot();
    bridge_expect("gem snapshot preserves the localized display name", _snapshot.gems[0].name == "激光宝石");
    bridge_expect("snapshot contains shared HUD and stable sprite names", _snapshot.flame == 250 && _snapshot.slots[0].sprite == "spr_win" && _snapshot.players[1].player_id == "guest" && _snapshot.slots[0].preview == "");
    bridge_expect("entities are sorted back to front", array_length(_snapshot.entities) == 4 && _snapshot.entities[0].depth == 100 && _snapshot.entities[3].depth == -100);
    bridge_expect("HUD-only sprites are excluded while plants and projectiles remain", array_length(_snapshot.entities)==4 && _snapshot.entities[1].id==string(_projectile.id) && _snapshot.entities[2].id==string(_plant.id));
    bridge_expect("wave HUD and remaining time survive snapshot", _snapshot.wave==1 && _snapshot.total_waves==5 && _snapshot.time_limit==18000);
    bridge_expect("enemy maxhp and transient effects survive snapshot", _snapshot.entities[0].max_hp == 500 && array_length(_snapshot.entities[0].effects) == 3 && _snapshot.entities[0].flash_alpha == 0.5 && _snapshot.entities[0].flash_shader == "hit_effect_2");
    bridge_expect("custom boss health bar survives snapshot", array_length(_snapshot.bosses) == 1 && _snapshot.bosses[0].hp == 250 && _snapshot.bosses[0].max_hp == 500);
    bridge_expect("snapshot round-trips JSON", is_struct(json_parse(json_stringify(_snapshot))));

    // A new match uses one validated deck and one resource account per owner.
    global.bridge_card_data = ds_map_create();
    global.bridge_card_data[? "cost"] = 50; global.bridge_card_data[? "cooldown"] = 420;
    global.bridge_card_data[? "obj"] = obj_fixture_plant; global.bridge_card_data[? "sprite"] = spr_win;
    global.bridge_card_data[? "place_preview"] = undefined; global.bridge_card_data[? "description"] = "Fixture";
    with (obj_card_slot) instance_destroy();
    global.coop.match_config = {per_player_loadouts:true,flame_ratio:0.6,loadouts:{host:["fixture-card","host-card"],guest:["fixture-card","guest-card"]}};
    global.coop.battle_started = false;
    coop_flame_initialize(500);
    coop_battle_begin();
    bridge_expect("room start defers owned slots until both match owners exist", !create_battle_slots() && instance_number(obj_card_slot)==0);
    global.coop.battle_started = true;
    coop_battle_ready(); coop_battle_tick();
    bridge_expect("both chosen decks create four separate slots", instance_number(obj_card_slot)==4 && global.coop_battle.slots_ready);
    bridge_expect("initial resource becomes sixty percent for each player", coop_flame_get("host")==300 && coop_flame_get("guest")==300 && global.flame==300);
    var _host_slot=noone; var _guest_slot=noone;
    for(var _i=0;_i<instance_number(obj_card_slot);_i++) {
        var _s=instance_find(obj_card_slot,_i);
        if(_s.slot_index==1) { if(_s.coop_owner=="host") _host_slot=_s; else _guest_slot=_s; }
    }
    bridge_expect("guest slots are hidden while host slots stay visible", _host_slot.visible && !_guest_slot.visible);
    coop_flame_collect(25);
    bridge_expect("one 25 flame pickup credits fifteen to both", coop_flame_get("host")==315 && coop_flame_get("guest")==315);
    var _personal_packet=bridge_packet("guest","place_card",{row:2,col:3,slot_index:1,card_id:"fixture-card"});
    bridge_expect("guest spends only guest flame and cooldown", coop_battle_command(_personal_packet) && coop_flame_get("guest")==265 && coop_flame_get("host")==315 && _guest_slot.cooldown_timer==0 && _host_slot.cooldown_timer==420);
    bridge_expect("duplicate personal placement cannot charge twice", !coop_battle_command(_personal_packet) && coop_flame_get("guest")==265);
    bridge_expect("guest cannot use a host-only card at the same index", !coop_battle_command(bridge_packet("guest","place_card",{row:2,col:4,slot_index:2,card_id:"host-card"})));
    bridge_expect("host has independent cooldown for the same card", coop_battle_command(bridge_packet("host","place_card",{row:2,col:4,slot_index:1,card_id:"fixture-card"})) && coop_flame_get("host")==265);
    coop_flame_spend("guest",65);
    create_battle_slots(); coop_battle_ready();
    bridge_expect("repeat room and ready hooks do not recreate slots or balances", instance_number(obj_card_slot)==4 && coop_flame_get("guest")==200 && _guest_slot.cooldown_timer==0);
    coop_prev_card_set("host","host-card"); coop_prev_card_set("guest","guest-card");
    bridge_expect("copy history is independent for each owner", coop_prev_card_get("host")=="host-card" && coop_prev_card_get("guest")=="guest-card" && global.prev_place_id=="host-card");
    var _personal_state=coop_battle_snapshot();
    bridge_expect("snapshot provides owner slots and personal balances", _personal_state.per_player_loadouts && _personal_state.balances[$ "host"]==265 && _personal_state.balances[$ "guest"]==200 && _personal_state.slots[0].owner=="host" && _personal_state.slots[2].owner=="guest" && _personal_state.flame==265);
    coop_flame_collect(999999);
    bridge_expect("each personal pool has an independent 15000 cap", coop_flame_get("host")==15000 && coop_flame_get("guest")==15000);
    bridge_expect("unknown account cannot spend even zero", !coop_flame_spend("intruder",0));
    global.coop_battle.slots_ready=false;
    global.coop.match_config.loadouts.guest=["fixture-card","fixture-card"];
    bridge_expect("duplicate-card loadout cannot create extra cooldowns", !coop_battle_prepare_loadouts() && instance_number(obj_card_slot)==4);
    global.coop.match_config.loadouts.guest=["fixture-card","guest-card"];
    global.coop_battle.slots_ready=true;

    var _over = instance_create_depth(0,0,0,obj_game_over); _over.sprite_index = spr_win;
    var _ui = instance_find(obj_battle_pause_manager,0);
    _ui.rewards_committed = false; _ui.victory_started = false;
    global.game_over = true; coop_battle_tick();
    bridge_expect("victory cannot submit before reward commit", global.bridge_results == 0);
    _ui.rewards_committed = true; _ui.victory_started = true; _ui.victory_resources = []; _ui.victory_unlocks = []; _ui.victory_milestones = []; _ui.first_complete = true;
    coop_battle_tick(); coop_battle_tick();
    bridge_expect("completed victory submits exactly once", global.bridge_results == 1 && global.bridge_last_result == "victory" && variable_struct_exists(global.bridge_last_snapshot,"victory"));
    global.coop.role = "guest";
    bridge_expect("guest cannot run host command executor", !coop_battle_command(bridge_packet("guest","place_player",{row:3,col:0})));
    var _passed = 0; for (var _i=0; _i<array_length(global.bridge_tests); _i++) if (global.bridge_tests[_i].passed) _passed++;
    show_debug_message("FVM_AUTOSAVE_RESULT=" + json_stringify({passed:_passed,total:array_length(global.bridge_tests),tests:global.bridge_tests}));
    game_end();
}
