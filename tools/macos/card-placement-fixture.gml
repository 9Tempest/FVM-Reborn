#macro spr_small_fire -1
#macro spr_enter_water_effect -1
#macro snd_card_lift -1
#macro snd_place1 -1
#macro snd_enter_water -1
#macro snd_flame_collect -1
#macro spr_win -1
#macro spr_lose -1
#macro spr_mouse_frozen -1
#macro spr_mouse_scared -1
#macro obj_card_parent obj_fixture_plant

function placement_mouse_check_button_pressed(_button) { return _button == mb_left && global.placement_click; }
function placement_keyboard_check_pressed(_key) { return _key == ord("1") && global.placement_key; }
function placement_device_mouse_x_to_gui(_device) { return global.placement_mouse_x; }
function placement_device_mouse_y_to_gui(_device) { return global.placement_mouse_y; }
function placement_audio_play_sound(_sound, _priority, _loop) { return -1; }
function coop_audio_snapshot() { return {}; }
function deck_slot_max() { return 3; }
function deck_slot_is_empty(_i) { return true; }
function placement_owned_slot(_owner,_card) {
    for(var _i=0;_i<instance_number(obj_card_slot);_i++) {
        var _slot=instance_find(obj_card_slot,_i);
        if(_slot.coop_owner==_owner && _slot.card_id==_card) return _slot;
    }
    return noone;
}
function placement_plant_created() {
    plant_id=global.spawn_id; plant_type=global.spawn_type; feature_type=global.spawn_feature; shape=0; depth_value=0;
    if (global.placement_nested) {
        global.placement_nested=false;
        global.placement_owner_at_create=coop_owner;
        coop_flame_collect(25);
        var _world=get_world_position_from_grid(5,4);
        global.placement_nested_accepted=global.placement_nested_slot.try_place_once(_world.x,_world.y,true,coop_owner);
    }
}
function deselect_shovel() {}
function get_card_info_simple(_id) { return {shape:0,level:0,skill:0}; }
function get_card_info(_id) { return get_card_info_simple(_id); }
function get_plant_data(_id) { return global.placement_cards[$ _id]; }
function get_plant_data_with_skill(_id, _shape, _level, _skill) { return get_plant_data(_id); }
function deck_get_card_data(_id, _shape) { return get_plant_data(_id); }
function get_cookbook_data(_id) { return {modif:[]}; }
function placement_expect(_name, _passed) { array_push(global.placement_tests, {name:_name,passed:_passed}); }
function placement_card(_id, _type, _feature, _target, _cost) {
    var _data = ds_map_create();
    _data[? "plant_type"] = _type; _data[? "feature_type"] = _feature; _data[? "target_card"] = _target;
    _data[? "cost"] = _cost; _data[? "cooldown"] = 60; _data[? "sprite"] = -1;
    _data[? "obj"] = obj_fixture_plant; _data[? "place_preview"] = undefined; _data[? "description"] = "Fixture";
    global.placement_cards[$ _id] = _data;
}
function placement_slot(_id) {
    var _slot = instance_create_depth(80,50,0,obj_card_slot);
    _slot.card_id = _id; _slot.slot_index = 1; _slot.card_obj = obj_fixture_plant;
    with (_slot) event_user(0);
    _slot.current_cost = _slot.cost;
    return _slot;
}
function placement_spawn(_slot) {
    var _data = get_plant_data(_slot.card_id);
    global.spawn_id = _slot.card_id; global.spawn_type = _data[? "plant_type"]; global.spawn_feature = _data[? "feature_type"];
}
function placement_at(_slot, _col, _row) {
    placement_spawn(_slot);
    var _world = get_world_position_from_grid(_col,_row);
    return _slot.try_place_once(_world.x,_world.y);
}
function placement_step(_slot, _col, _row, _key, _click) {
    placement_spawn(_slot);
    var _world = get_world_position_from_grid(_col,_row);
    global.placement_mouse_x = _world.x; global.placement_mouse_y = _world.y;
    global.placement_key = _key; global.placement_click = _click;
    with (_slot) event_perform(ev_step,ev_step_normal);
    global.placement_key = false; global.placement_click = false;
}
function placement_run() {
    global.placement_tests=[]; global.placement_cards={}; global.placement_key=false; global.placement_click=false;
    global.placement_mouse_x=0; global.placement_mouse_y=0; global.placement_nested=false;
    global.flame=10000; global.game_over=false; global.is_paused=false; global.debug=false;
    global.quick_placement=false; global.replace_placement=false; global.selected_slot=noone; global.prev_place_id="";
    global.plus_card_map=ds_map_create(); global.keybind_map=ds_map_create(); global.keybind_map[? "卡槽1"]=ord("1");
    global.save_data={equipped_cookbook:[]};
    global.grid_cols=8; global.grid_rows=5; global.grid_offset_x=200; global.grid_offset_y=200;
    global.grid_cell_size_x=80; global.grid_cell_size_y=80;
    global.grid_plants=ds_grid_create(global.grid_cols,global.grid_rows); global.grid_terrains=[];
    for (var _row=0; _row<global.grid_rows; _row++) {
        var _terrain=[];
        for (var _col=0; _col<global.grid_cols; _col++) {
            array_push(_terrain,{type:"normal"}); ds_grid_set(global.grid_plants,_col,_row,ds_list_create());
        }
        array_push(global.grid_terrains,_terrain);
    }
    placement_card("base","normal","normal","none",100);
    placement_card("lily","lilypad","normal","none",25);
    placement_card("shield","shield_outer","normal","none",50);
    placement_card("upgrade","normal","upgrade","base",200);
    placement_card("magic_chicken","normal","normal","none",0);

    var _slot=placement_slot("base");
    placement_expect("placement spends the current cost once",placement_at(_slot,0,0) && global.flame==9900 && _slot.cooldown_timer==0);
    var _flame=global.flame;
    placement_expect("second same-frame placement cannot bypass cooldown",!placement_at(_slot,1,0) && global.flame==_flame && ds_list_size(global.grid_plants[# 1,0])==0);
    _slot.cooldown_timer=_slot.cooldown;
    global.flame=99;
    placement_expect("insufficient flame preserves board and cooldown",!placement_at(_slot,1,0) && global.flame==99 && _slot.cooldown_timer==_slot.cooldown);
    global.flame=10000;
    placement_expect("same layer rejects a second card",!placement_at(_slot,0,0) && ds_list_size(global.grid_plants[# 0,0])==1);

    global.quick_placement=true;
    placement_step(_slot,-1,1,true,false);
    placement_expect("failed out-of-grid quick hotkey clears selection",!_slot.is_selected && global.selected_slot==noone);
    placement_step(_slot,1,0,true,false);
    placement_expect("next quick hotkey places immediately after failed attempt",ds_list_size(global.grid_plants[# 1,0])==1 && !_slot.is_selected);
    _slot.cooldown_timer=_slot.cooldown;
    _slot.select_slot();
    placement_step(_slot,0,0,false,true);
    placement_expect("invalid mouse target keeps card selected even with quick mode",_slot.is_selected && global.selected_slot==_slot);
    placement_step(_slot,2,0,false,true);
    placement_expect("selected card can retry mouse placement on another cell",ds_list_size(global.grid_plants[# 2,0])==1 && !_slot.is_selected);

    var _lily=placement_slot("lily"); var _shield=placement_slot("shield");
    global.grid_terrains[1][0].type="water"; _slot.cooldown_timer=_slot.cooldown;
    placement_expect("normal card cannot plant directly on water",!placement_at(_slot,0,1));
    placement_expect("lilypad accepts normal card and outer shield",placement_at(_lily,0,1) && placement_at(_slot,0,1) && placement_at(_shield,0,1) && ds_list_size(global.grid_plants[# 0,1])==3);
    var _upgrade=placement_slot("upgrade"); var _base=ds_list_find_value(global.grid_plants[# 0,0],0);
    placement_expect("upgrade requires its base",!placement_at(_upgrade,3,0));
    placement_expect("upgrade replaces exactly its base",placement_at(_upgrade,0,0) && !instance_exists(_base) && ds_list_size(global.grid_plants[# 0,0])==1);
    global.replace_placement=true; _slot.cooldown_timer=_slot.cooldown;
    _base=ds_list_find_value(global.grid_plants[# 1,0],0);
    placement_expect("replacement removes the previous same-layer plant",placement_at(_slot,1,0) && !instance_exists(_base) && ds_list_size(global.grid_plants[# 1,0])==1);
    global.replace_placement=false;

    var _platform=instance_create_depth(0,0,0,obj_platform);
    _platform.move_axis="x"; _platform.visual_x_shift=50; _platform.visual_y_shift=0;
    _platform.current_offset=0; _platform.start_col=4; _platform.start_row=2; _platform.width=2; _platform.length=1; _platform.state="moving";
    _slot.cooldown_timer=_slot.cooldown; placement_spawn(_slot);
    var _world=get_world_position_from_grid(4,2);
    placement_expect("moving horizontal platform uses shifted visual coordinates",_slot.try_place_once(_world.x+50,_world.y));
    var _plant=ds_list_find_value(global.grid_plants[# 4,2],0);
    placement_expect("moving platform preserves logical grid and locks it",instance_exists(_plant) && _plant.grid_col==4 && _plant.grid_row==2 && _plant.x==_world.x+50 && _plant.platform_grid_lock);
    _slot.cooldown_timer=_slot.cooldown;
    placement_expect("uncovered edge of moving platform rejects placement",!_slot.try_place_once(_world.x-35,_world.y));
    _platform.move_axis="y"; _platform.visual_x_shift=0; _platform.visual_y_shift=-50; _platform.start_col=6; _platform.start_row=3; _platform.width=1; _platform.length=2;
    _world=get_world_position_from_grid(6,3);
    placement_expect("moving vertical platform retains its logical row",_slot.try_place_once(_world.x,_world.y-50) && ds_list_size(global.grid_plants[# 6,3])==1);

    global.plus_card_map[? "base"]=[obj_fixture_plant,1]; _slot.cooldown_timer=_slot.cooldown; _slot.current_cost=0;
    _flame=global.flame; var _expected=100+instance_number(obj_fixture_plant)*50;
    placement_expect("ordered placement refreshes growing cost from current board",placement_at(_slot,7,0) && global.flame==_flame-_expected);
    var _copy=placement_slot("magic_chicken"); global.prev_place_id="base";
    _flame=global.flame; _expected=100+instance_number(obj_fixture_plant)*50;
    placement_expect("copy card refreshes target cost before charging",placement_at(_copy,7,1) && global.flame==_flame-_expected && _copy.cooldown==810 && _copy.cooldown_timer==0);


    // Enable the negotiated mode with the real slot factory and flame manager.
    with(obj_card_slot) instance_destroy();
    with(obj_platform) instance_destroy();
    ds_map_clear(global.plus_card_map);
    global.coop={active:true,role:"host",player_id:"host",battle_started:true,
        players:[{player_id:"host"},{player_id:"guest"}],
        match_config:{per_player_loadouts:true,flame_ratio:0.6,loadouts:{host:["base","magic_chicken"],guest:["base","shield","magic_chicken"]}}};
    global.level_file={starting_flame:350}; global.difficulty=0;
    global.player_deck=ds_list_create();
    var _manager=instance_create_depth(0,0,0,obj_flame_manager_probe);
    with(_manager) placement_obj_flame_manager_Create_0();
    instance_create_depth(0,0,0,obj_battle);
    coop_battle_begin();
    placement_expect("initial personal flame includes sixty percent of difficulty bonus",coop_flame_get("host")==300 && coop_flame_get("guest")==300);
    placement_expect("independent deck factory creates only each player's selected cards",instance_number(obj_card_slot)==5 && instance_exists(placement_owned_slot("guest","shield")) && !instance_exists(placement_owned_slot("host","shield")));
    var _host=placement_owned_slot("host","base"); var _guest=placement_owned_slot("guest","base");
    global.is_paused=false; global.debug=true;
    placement_step(_guest,2,4,true,true);
    placement_expect("hidden guest slot ignores host mouse and keyboard",!_guest.is_selected && global.selected_slot==noone && !_guest.visible && _host.visible);
    placement_spawn(_guest);
    _world=get_world_position_from_grid(0,4);
    placement_expect("slot refuses another player's ordered identity",!_guest.try_place_once(_world.x,_world.y,true,"host") && coop_flame_get("guest")==300);
    global.placement_nested=true; global.placement_nested_slot=_guest; global.placement_nested_accepted=true;
    placement_expect("guest placement is authoritative with its own resource account",_guest.try_place_once(_world.x,_world.y,true,"guest"));
    placement_expect("nested creation preserves owner and credits both real accounts",global.placement_owner_at_create=="guest" && coop_flame_get("guest")==215 && coop_flame_get("host")==315 && global.flame==315);
    placement_expect("nested placement cannot spend again before cooldown reservation",!global.placement_nested_accepted && ds_list_size(global.grid_plants[# 5,4])==0);
    placement_expect("guest cooldown cannot affect the host same-card slot",_guest.cooldown_timer==0 && _host.cooldown_timer>=_host.cooldown);
    placement_step(_guest,2,4,false,false);
    with(_manager) placement_obj_flame_manager_Step_2();
    placement_expect("hidden cooldown ticks and debug grants no coop freebies",_guest.cooldown_timer==1 && coop_flame_get("guest")==215 && coop_flame_get("host")==315);
    placement_spawn(_host); _world=get_world_position_from_grid(1,4);
    placement_expect("host can use same card during guest cooldown",_host.try_place_once(_world.x,_world.y,true,"host") && coop_flame_get("host")==215 && coop_flame_get("guest")==215);
    var _host_copy=placement_owned_slot("host","magic_chicken"); var _guest_copy=placement_owned_slot("guest","magic_chicken");
    coop_prev_card_set("host","shield"); coop_prev_card_set("guest","base");
    with(_host_copy) event_user(0);
    with(_guest_copy) event_user(0);
    placement_spawn(_host_copy); _world=get_world_position_from_grid(2,4);
    placement_expect("copy card charges only its owner's previous target",_host_copy.try_place_once(_world.x,_world.y,true,"host") && coop_flame_get("host")==165 && coop_flame_get("guest")==215);
    _plant=ds_list_find_value(global.grid_plants[# 2,4],0);
    placement_expect("copy target reaches nested Create without shared globals",_plant.coop_copy_card=="shield" && _plant.coop_owner=="host" && coop_prev_card_get("guest")=="base");
    placement_spawn(_guest_copy); _world=get_world_position_from_grid(3,4);
    placement_expect("guest copy remains independent after host copying",_guest_copy.try_place_once(_world.x,_world.y,true,"guest") && coop_flame_get("guest")==115 && coop_flame_get("host")==165);
    var _ice=instance_create_depth(0,0,0,obj_ice_cream_probe);
    _ice.coop_owner="host"; _ice.attack_timer=0; _ice.shape=2; _ice.is_slowdown=false; _ice.flash_speed=1; _ice.idle_anim=100; _ice.ignore_list=["magic_chicken"];
    with(_ice) placement_obj_ice_cream_Step_0();
    placement_expect("ice cream resets only its owner's eligible cooldowns",_host.cooldown_timer==_host.cooldown && _guest.cooldown_timer==1 && _host_copy.cooldown_timer==0);
    var _flame_object=instance_create_depth(0,0,0,obj_flame);
    with(_flame_object) placement_obj_flame_Create_0();
    _flame_object.is_collected=true; _flame_object.collect_timer=_flame_object.collect_duration-1; _flame_object.value=25;
    var _before_host=coop_flame_get("host"); var _before_guest=coop_flame_get("guest");
    with(_flame_object) placement_obj_flame_Step_0();
    placement_expect("real flame collection destroys pickup and credits exactly fifteen each",!instance_exists(_flame_object) && coop_flame_get("host")==_before_host+15 && coop_flame_get("guest")==_before_guest+15);

    var _passed=0;
    for(var _i=0;_i<array_length(global.placement_tests);_i++) if(global.placement_tests[_i].passed) _passed++;
    show_debug_message("FVM_AUTOSAVE_RESULT="+json_stringify({passed:_passed,total:array_length(global.placement_tests),tests:global.placement_tests}));
    game_end();
}
