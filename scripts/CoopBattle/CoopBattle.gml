/// Only the host room contains a running simulation. Guests render snapshots.
function coop_battle_active() {
    return variable_global_exists("coop") && is_struct(global.coop) && global.coop.active;
}
function coop_battle_host() { return coop_battle_active() && global.coop.role == "host"; }
function coop_player_id(_player) {
    if (is_string(_player)) return _player;
    if (is_struct(_player) && variable_struct_exists(_player, "player_id")) return _player.player_id;
    if (is_struct(_player) && variable_struct_exists(_player, "id")) return _player.id;
    return "";
}
function coop_player_instance(_owner) {
    for (var _i = 0; _i < instance_number(obj_player_character); _i++) {
        var _player = instance_find(obj_player_character, _i);
        if (_player.coop_owner == _owner) return _player;
    }
    return noone;
}
function coop_grid_valid(_row, _col) {
    return is_real(_row) && is_real(_col) && _row == floor(_row) && _col == floor(_col)
        && _row >= 0 && _row < global.grid_rows && _col >= 0 && _col < global.grid_cols;
}

/// Interpret clicks using the same moving-platform grid as planting.
function coop_grid_from_world(_x, _y) {
    var _direct = get_grid_position_from_world(_x, _y);
    var _blocked = false;
    for (var _i = 0; _i < instance_number(obj_platform); _i++) {
        var _p = instance_find(obj_platform, _i);
        var _axis_x = variable_instance_exists(_p, "move_axis") && _p.move_axis == "x";
        var _sx = _axis_x ? _p.visual_x_shift : 0;
        var _sy = _axis_x ? 0 : _p.visual_y_shift;
        var _col = _p.start_col + (_axis_x ? _p.current_offset : 0);
        var _row = _p.start_row + (_axis_x ? 0 : _p.current_offset);
        var _cell = get_grid_position_from_world(_x - _sx, _y - _sy);
        if (_cell.col >= _col && _cell.col < _col + _p.width && _cell.row >= _row && _cell.row < _row + _p.length) return _cell;
        if (_direct.col >= _col && _direct.col < _col + _p.width && _direct.row >= _row && _direct.row < _row + _p.length) _blocked = true;
    }
    if (_blocked || !coop_grid_valid(_direct.row, _direct.col)) return {row:-1, col:-1};
    return _direct;
}
function coop_world_from_grid(_row, _col) {
    var _world = get_world_position_from_grid(_col, _row);
    for (var _i = 0; _i < instance_number(obj_platform); _i++) {
        var _p = instance_find(obj_platform, _i);
        var _axis_x = variable_instance_exists(_p, "move_axis") && _p.move_axis == "x";
        var _pc = _p.start_col + (_axis_x ? _p.current_offset : 0);
        var _pr = _p.start_row + (_axis_x ? 0 : _p.current_offset);
        if (_col >= _pc && _col < _pc + _p.width && _row >= _pr && _row < _pr + _p.length) {
            _world.x += _axis_x ? _p.visual_x_shift : 0;
            _world.y += _axis_x ? 0 : _p.visual_y_shift;
            break;
        }
    }
    return _world;
}

function coop_battle_begin() {
    if (!coop_battle_host()) return;
    global.coop_battle = {ready:false, last_seq:-1, last_seqs:{}, last_snapshot:-1000, result_sent:false, start_requested:false, start_retry_at:current_time + 500, pause_votes:{}, owners:[]};
    global.is_paused = true;
    game_set_speed(60, gamespeed_fps);
    obj_battle.speed_up = false;
    if (global.coop.battle_started) coop_battle_ready();
    else global.coop_battle.start_requested = global.coop.start_battle(global.level_data.id);
}

/// Called after the server acknowledges the match and assigns both player IDs.
function coop_battle_ready() {
    if (!coop_battle_host() || !instance_exists(obj_battle) || !variable_global_exists("coop_battle")) return false;
    if (global.coop_battle.ready) return true;
    if (array_length(global.coop.players) != 2) return false;
    var _owners = [];
    for (var _i = 0; _i < 2; _i++) {
        var _owner = coop_player_id(global.coop.players[_i]);
        if (_owner == "" || array_get_index(_owners, _owner) != -1) return false;
        array_push(_owners, _owner);
    }
    if (array_get_index(_owners, global.coop.player_id) == -1) return false;
    // The existing character is always the local host's; create one teammate.
    var _host = instance_find(obj_player_character, 0);
    if (!instance_exists(_host)) _host = instance_create_depth(mouse_x, mouse_y, 0, obj_player_character);
    _host.coop_owner = global.coop.player_id;
    for (var _i = 0; _i < 2; _i++) {
        if (_owners[_i] != global.coop.player_id && !instance_exists(coop_player_instance(_owners[_i]))) {
            var _guest = instance_create_depth(-200, -200, 0, obj_player_character);
            _guest.coop_owner = _owners[_i];
        }
    }
    global.coop_battle.owners = _owners;
    for (var _i = 0; _i < 2; _i++) {
        variable_struct_set(global.coop_battle.pause_votes, _owners[_i], false);
        variable_struct_set(global.coop_battle.last_seqs, _owners[_i], -1);
    }
    global.coop_battle.ready = true;
    global.coop_battle.start_requested = true;
    global.is_paused = true;
    return true;
}
function coop_battle_can_run() {
    if (!coop_battle_host() || !variable_global_exists("coop_battle") || !global.coop_battle.ready) return false;
    if (!global.coop.all_connected()) return false;
    for (var _i = 0; _i < array_length(global.coop_battle.owners); _i++) {
        var _p = coop_player_instance(global.coop_battle.owners[_i]);
        if (!instance_exists(_p) || !_p.is_placed || variable_struct_get(global.coop_battle.pause_votes, global.coop_battle.owners[_i])) return false;
    }
    return !global.game_over;
}

/// The player identity and sequence must come from the server, never the payload.
function coop_battle_command(_packet) {
    if (!coop_battle_host() || !instance_exists(obj_battle) || !variable_global_exists("coop_battle") || !global.coop_battle.ready) return false;
    if (!is_struct(_packet) || !variable_struct_exists(_packet,"player_id") || !variable_struct_exists(_packet,"seq")
        || !variable_struct_exists(_packet,"action") || !variable_struct_exists(_packet,"payload")
        || !variable_struct_exists(_packet,"match_id") || _packet.match_id != global.coop.match_id) return false;
    if (!is_real(_packet.seq) || _packet.seq != floor(_packet.seq)) return false;
    var _owner_index = array_get_index(global.coop_battle.owners, _packet.player_id);
    if (_owner_index == -1 || !is_struct(_packet.payload)) return false;
    if (_packet.seq <= variable_struct_get(global.coop_battle.last_seqs, _packet.player_id)) return false;
    variable_struct_set(global.coop_battle.last_seqs, _packet.player_id, _packet.seq);
    global.coop_battle.last_seq = max(global.coop_battle.last_seq, _packet.seq);
    if (!global.coop.all_connected() || global.game_over) return false;
    var _data = _packet.payload;
    if (_packet.action == "pause_vote") {
        if (!variable_struct_exists(_data,"paused") || !is_bool(_data.paused)) return false;
        variable_struct_set(global.coop_battle.pause_votes, _packet.player_id, _data.paused);
        global.is_paused = !coop_battle_can_run();
        return true;
    }
    var _player = coop_player_instance(_packet.player_id);
    if (!instance_exists(_player)) return false;
    if (_packet.action == "use_gem") {
        if (!coop_battle_can_run() || !variable_struct_exists(_data,"gem_index")) return false;
        var _used = false;
        with (all) {
            if (variable_instance_exists(id,"coop_gem_index") && coop_gem_index == _data.gem_index && variable_instance_exists(id,"try_use_gem")) {
                if (!variable_struct_exists(_data,"gem_id") || gem_id == _data.gem_id) _used = try_use_gem(_player, true);
                break;
            }
        }
        return _used;
    }
    if (!variable_struct_exists(_data,"row") || !variable_struct_exists(_data,"col") || !coop_grid_valid(_data.row, _data.col)) return false;
    var _world = coop_world_from_grid(_data.row, _data.col);
    switch (_packet.action) {
        case "place_player":
            if (_player.is_placed) return false;
            var _placed = _player.try_place_player(_world.x, _world.y);
            global.is_paused = !coop_battle_can_run();
            return _placed;
        case "place_card":
            if (!coop_battle_can_run() || !variable_struct_exists(_data,"card_id") || !variable_struct_exists(_data,"slot_index")) return false;
            for (var _i = 0; _i < instance_number(obj_card_slot); _i++) {
                var _slot = instance_find(obj_card_slot, _i);
                if (_slot.slot_index == _data.slot_index && _slot.card_id == _data.card_id) return _slot.try_place_once(_world.x, _world.y, true);
            }
            return false;
        case "shovel":
            if (!coop_battle_can_run() || !instance_exists(obj_shovel_slot)) return false;
            return instance_find(obj_shovel_slot, 0).try_shovel_once(_world.x, _world.y, true);
    }
    return false;
}

function coop_snapshot_sprite(_sprite) {
    return !is_undefined(_sprite) && sprite_exists(_sprite) ? sprite_get_name(_sprite) : "";
}
function coop_battle_snapshot() {
    var _state = {background:{sprite:coop_snapshot_sprite(global.level_data.level_sprite),frame:obj_battle.map_spr_index},
        entities:[], slots:[], gems:[], players:[], platforms:[], bosses:[], audio:coop_audio_snapshot(),
        grid:{offset_x:global.grid_offset_x,offset_y:global.grid_offset_y,cell_x:global.grid_cell_size_x,cell_y:global.grid_cell_size_y,cols:global.grid_cols,rows:global.grid_rows},
        flame:global.flame,paused:global.is_paused,pause_votes:global.coop_battle.pause_votes,game_over:global.game_over,outcome:"",level_name:global.level_data.name,
        battle_time:obj_battle.battle_time,wave:obj_battle.current_wave,total_waves:obj_battle.total_wave,
        waiting:!global.coop_battle.ready || !coop_battle_can_run(),connected:global.coop.all_connected(),last_seq:global.coop_battle.last_seq};
    for (var _i = 0; _i < instance_number(all); _i++) {
        var _inst = instance_find(all, _i);
        if (!_inst.visible || !sprite_exists(_inst.sprite_index) || _inst.image_alpha <= 0) continue;
        if (_inst.object_index == obj_card_slot || _inst.object_index == obj_shovel_slot || _inst.object_index == obj_game_over || _inst.object_index == obj_card_preview || _inst.object_index == obj_boss_hpbar) continue;
        if (variable_instance_exists(_inst,"coop_gem_index")) continue;
        if (_inst.object_index == obj_player_character && !_inst.is_placed) continue;
        var _entity = {id:string(_inst.id),sprite:coop_snapshot_sprite(_inst.sprite_index),frame:_inst.image_index,x:_inst.x,y:_inst.y,
            xscale:_inst.image_xscale,yscale:_inst.image_yscale,angle:_inst.image_angle,alpha:_inst.image_alpha,blend:_inst.image_blend,depth:_inst.depth};
        if (variable_instance_exists(_inst,"hp")) _entity.hp = _inst.hp;
        if (variable_instance_exists(_inst,"max_hp")) _entity.max_hp = _inst.max_hp;
        var _enemy = variable_instance_exists(_inst,"maxhp");
        if (_enemy) _entity.max_hp = _inst.maxhp;
        if (variable_instance_exists(_inst,"coop_owner")) _entity.owner = _inst.coop_owner;
        // These overlays exist only in Draw events and cannot be found as instances.
        var _effects = [];
        if (variable_instance_exists(_inst,"is_frozen") && _inst.is_frozen) {
            var _ice = variable_instance_exists(_inst,"ice_sprite") ? _inst.ice_sprite : spr_mouse_frozen;
            array_push(_effects, {sprite:coop_snapshot_sprite(_ice),frame:0,dx:0,dy:_enemy ? 50 : 95,xscale:1.8,yscale:1.8,alpha:1,blend:c_white});
        }
        if (variable_instance_exists(_inst,"is_scare") && _inst.is_scare) {
            array_push(_effects, {sprite:coop_snapshot_sprite(spr_mouse_scared),frame:0,dx:-45,dy:-125,xscale:1.8,yscale:1.8,alpha:1,blend:c_white});
        }
        if (variable_instance_exists(_inst,"is_stun") && _inst.is_stun && variable_instance_exists(_inst,"stun_sprite")) {
            var _frames = max(1,sprite_get_number(_inst.stun_sprite));
            var _frame = (_frames - (floor(_inst.stun_timer / 5) mod _frames)) mod _frames;
            array_push(_effects, {sprite:coop_snapshot_sprite(_inst.stun_sprite),frame:_frame,dx:-20,dy:-150,xscale:1.8,yscale:1.8,alpha:1,blend:c_white});
        }
        if (array_length(_effects) > 0) _entity.effects = _effects;
        if (variable_instance_exists(_inst,"is_slowdown") && _inst.is_slowdown) _entity.blend = merge_colour(c_white,c_blue,0.5);
        if (variable_instance_exists(_inst,"flash_value") && _inst.flash_value > 0) {
            _entity.flash_alpha = clamp(_inst.flash_value / 200,0,1);
            _entity.flash_colour = variable_instance_exists(_inst,"flash_color") ? _inst.flash_color : c_white;
            _entity.flash_shader = "hit_effect_2"; // All current enemy shader_hit fields use this shader.
        }
        if (_enemy || variable_instance_exists(_inst,"plant_type")) {
            var _type = _enemy ? "enemy" : _inst.plant_type;
            var _visible = _enemy ? (variable_global_exists("enemy_hpbar") && global.enemy_hpbar) : (variable_global_exists("card_hpbar") && global.card_hpbar);
            _entity.healthbar = {visible:_visible && !global.is_paused && _type != "coffee",
                offset_y:_enemy ? -30 : (_type == "lilypad" ? 10 : (_type == "shield_outer" ? -50 : -20)),
                colour:_enemy ? c_purple : (_type == "lilypad" ? c_yellow : (_type == "shield_outer" ? c_lime : c_green)),
                shield_hp:variable_instance_exists(_inst,"shield_hp") ? _inst.shield_hp : 0,
                shield_max_hp:variable_instance_exists(_inst,"shield_max_hp") ? _inst.shield_max_hp : 0};
        }
        array_push(_state.entities, _entity);
    }
    array_sort(_state.entities, function(_a, _b) { return _b.depth - _a.depth; });
    for (var _i = 0; _i < instance_number(obj_player_character); _i++) {
        var _p = instance_find(obj_player_character, _i);
        array_push(_state.players, {player_id:_p.coop_owner,placed:_p.is_placed,row:_p.grid_row,col:_p.grid_col,hp:_p.hp,max_hp:_p.max_hp,sprite:coop_snapshot_sprite(_p.sprite_index)});
    }
    for (var _i = 0; _i < instance_number(obj_card_slot); _i++) {
        var _s = instance_find(obj_card_slot, _i);
        if (!_s.info_got) with (_s) event_user(0);
        array_push(_state.slots, {slot_index:_s.slot_index,card_id:_s.card_id,x:_s.x,y:_s.y,sprite:coop_snapshot_sprite(_s.card_spr),
            preview:coop_snapshot_sprite(_s.place_preview),frame:0,cost:_s.current_cost,cooldown:_s.cooldown,remaining_cd:max(0,_s.cooldown - _s.cooldown_timer),ready:_s.is_ready,level:_s.clevel,shape:_s.cshape});
    }
    for (var _i = 0; _i < instance_number(all); _i++) {
        var _g = instance_find(all, _i);
        if (variable_instance_exists(_g,"coop_gem_index") && _g.coop_gem_index >= 0) {
            var _name = _g.gem_id;
            if (variable_instance_exists(_g,"gem_info") && is_struct(_g.gem_info) && variable_struct_exists(_g.gem_info,"name")) _name = _g.gem_info.name;
            array_push(_state.gems, {gem_index:_g.coop_gem_index,gem_id:_g.gem_id,name:_name,active:variable_instance_exists(_g,"try_use_gem"),x:_g.x,y:_g.y,sprite:coop_snapshot_sprite(_g.sprite_index),frame:0,cooldown:_g.cooldown,remaining_cd:max(0,_g.cooldown_timer)});
        }
    }
    for (var _i = 0; _i < instance_number(obj_platform); _i++) {
        var _p = instance_find(obj_platform, _i);
        var _axis_x = variable_instance_exists(_p,"move_axis") && _p.move_axis == "x";
        array_push(_state.platforms, {col:_p.start_col + (_axis_x ? _p.current_offset : 0),row:_p.start_row + (_axis_x ? 0 : _p.current_offset),
            width:_p.width,height:_p.length,shift_x:_axis_x ? _p.visual_x_shift : 0,shift_y:_axis_x ? 0 : _p.visual_y_shift});
    }
    for (var _i = 0; _i < instance_number(obj_boss_hpbar); _i++) {
        var _bar = instance_find(obj_boss_hpbar,_i);
        if (!instance_exists(_bar.target_boss)) continue;
        var _boss_name = _bar.boss_name;
        var _icon = _bar.icon_spr;
        if (_bar.boss_id != "" && ds_map_exists(global.boss_list,_bar.boss_id)) {
            _boss_name = global.boss_list[? _bar.boss_id].name;
            _icon = global.boss_list[? _bar.boss_id].icon;
        }
        array_push(_state.bosses,{name:_boss_name,icon:coop_snapshot_sprite(_icon),hp:max(0,_bar.target_boss.hp),max_hp:_bar.target_boss.maxhp,x:_bar.x,y:_bar.y,width:_bar.bar_width});
    }
    if (global.game_over && instance_exists(obj_game_over)) {
        _state.outcome = obj_game_over.sprite_index == spr_win ? "victory" : "defeat";
        if (instance_exists(obj_battle_pause_manager) && obj_battle_pause_manager.victory_started) {
            var _ui = obj_battle_pause_manager;
            var _resources = [];
            var _unlocks = [];
            for (var _i = 0; _i < array_length(_ui.victory_resources); _i++) {
                var _r = _ui.victory_resources[_i];
                array_push(_resources, {name:_r.name,amount:_r.amount,sprite:coop_snapshot_sprite(_r.sprite),frame:_r.frame});
            }
            for (var _i = 0; _i < array_length(_ui.victory_unlocks); _i++) {
                var _u = _ui.victory_unlocks[_i];
                array_push(_unlocks, {name:_u.name,kind:_u.kind,sprite:coop_snapshot_sprite(_u.sprite),card:_u.card,cost:_u.cost});
            }
            _state.victory = {resources:_resources,unlocks:_unlocks,milestones:_ui.victory_milestones,first_complete:_ui.first_complete};
        }
    }
    return _state;
}

/// Called by the session controller even while the battle is paused/disconnected.
function coop_battle_tick() {
    if (!coop_battle_host() || !instance_exists(obj_battle) || !variable_global_exists("coop_battle")) return;
    if (!global.coop_battle.ready) {
        if (global.coop.battle_started) coop_battle_ready();
        else if (!global.coop_battle.start_requested && global.coop.all_connected() && current_time >= global.coop_battle.start_retry_at) {
            global.coop_battle.start_retry_at = current_time + 500;
            global.coop_battle.start_requested = global.coop.start_battle(global.level_data.id);
        }
    }
    global.is_paused = !coop_battle_can_run();
    if (!global.coop.battle_started) return;
    if (current_time - global.coop_battle.last_snapshot >= 100) {
        global.coop_battle.last_snapshot = current_time;
        global.coop.send_snapshot(coop_battle_snapshot());
    }
    if (global.game_over && !global.coop_battle.result_sent && instance_exists(obj_game_over)) {
        if (obj_game_over.sprite_index == spr_win && (!instance_exists(obj_battle_pause_manager)
            || !obj_battle_pause_manager.rewards_committed || !obj_battle_pause_manager.victory_started)) return;
        global.coop_battle.result_sent = true;
        global.coop.send_snapshot(coop_battle_snapshot());
        global.coop.submit_result(obj_game_over.sprite_index == spr_win ? "victory" : "defeat");
    }
}
