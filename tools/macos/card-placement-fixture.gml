#macro spr_small_fire -1
#macro spr_enter_water_effect -1
#macro snd_card_lift -1
#macro snd_place1 -1
#macro snd_enter_water -1

function placement_mouse_check_button_pressed(_button) { return _button == mb_left && global.placement_click; }
function placement_keyboard_check_pressed(_key) { return _key == ord("1") && global.placement_key; }
function placement_device_mouse_x_to_gui(_device) { return global.placement_mouse_x; }
function placement_device_mouse_y_to_gui(_device) { return global.placement_mouse_y; }
function placement_audio_play_sound(_sound, _priority, _loop) { return -1; }
function coop_battle_active() { return false; }
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
    global.placement_mouse_x=0; global.placement_mouse_y=0;
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

    var _passed=0;
    for(var _i=0;_i<array_length(global.placement_tests);_i++) if(global.placement_tests[_i].passed) _passed++;
    show_debug_message("FVM_AUTOSAVE_RESULT="+json_stringify({passed:_passed,total:array_length(global.placement_tests),tests:global.placement_tests}));
    game_end();
}
