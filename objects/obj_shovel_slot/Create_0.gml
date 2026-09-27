image_xscale = 1.8
image_yscale = 1.8
image_speed = 0

// obj_shovel_slot CREATE 事件
is_selected = false;        // 铲子是否被选中
is_ready = true;            // 铲子总是可用
description = "铲子:移除植物";
flame_rate = 0 //回收比例
hotkey_pressed = false

// 铲子精灵
if global.save_data.unlocked_items.shovel == "normal"{
	shovel_spr = spr_shovel;
}
else if global.save_data.unlocked_items.shovel == "copper"{
	shovel_spr = spr_copper_shovel;
	flame_rate = 0.1
}
else if global.save_data.unlocked_items.shovel == "silver"{
	shovel_spr = spr_silver_shovel;
	flame_rate = 0.25
}
else if global.save_data.unlocked_items.shovel == "gold"{
	shovel_spr = spr_gold_shovel;
	flame_rate = 0.5
}
else{
	shovel_spr = spr_shovel;
}

hotkey = "`";               // 快捷键
var slot_length = deck_slot_count()
if slot_length <= 14{
	image_index = 0
}
else{
	image_index = 1
}
// 位置和大小
slot_width = 84;
slot_height = 105;
x_offset = 0;
y_offset = 0;
mx = 0
my = 0
depth = -1200


function try_shovel_once(_world_x, _world_y, _ordered = false) {
	if (coop_battle_active() && !_ordered) {
		var _cell = coop_grid_from_world(_world_x, _world_y);
		if (_cell.col < 0 || _cell.row < 0) return false;
		global.coop.send_input("shovel", {row:_cell.row, col:_cell.col});
		return true;
	}
	if (global.game_over || global.is_paused) return false;

    var found_plat = noone;
    var platform_shift_x = 0;
    var platform_shift_y = 0;
    var logical_col = -1;
    var logical_row = -1;

    with (obj_platform) {
        var is_axis_x = (variable_instance_exists(id, "move_axis") && move_axis == "x");
        var shift_x = is_axis_x ? visual_x_shift : 0;
        var shift_y = (!is_axis_x) ? visual_y_shift : 0;
        var adj_x = _world_x - shift_x;
        var adj_y = _world_y - shift_y;
        var grid_pos_adj = get_grid_position_from_world(adj_x, adj_y);

        var c_off = is_axis_x ? current_offset : 0;
        var r_off = (!is_axis_x) ? current_offset : 0;
        var p_start_c = start_col + c_off;
        var p_start_r = start_row + r_off;

        if (grid_pos_adj.col >= p_start_c && grid_pos_adj.col < p_start_c + width &&
            grid_pos_adj.row >= p_start_r && grid_pos_adj.row < p_start_r + length) {
            found_plat = id;
            logical_col = grid_pos_adj.col;
            logical_row = grid_pos_adj.row;
            platform_shift_x = shift_x;
            platform_shift_y = shift_y;
            break;
        }

        var grid_pos_dir = get_grid_position_from_world(_world_x, _world_y);
        if (grid_pos_dir.col >= p_start_c && grid_pos_dir.col < p_start_c + width &&
            grid_pos_dir.row >= p_start_r && grid_pos_dir.row < p_start_r + length) {
            found_plat = id;
            logical_col = grid_pos_adj.col;
            logical_row = grid_pos_adj.row;
            platform_shift_x = shift_x;
            platform_shift_y = shift_y;
            break;
        }
    }

    if (found_plat == noone) {
        var grid_pos_direct = get_grid_position_from_world(_world_x, _world_y);
        logical_col = grid_pos_direct.col;
        logical_row = grid_pos_direct.row;
    }

    var logical_world = get_world_position_from_grid(logical_col, logical_row);

    if (logical_col < 0 || logical_col >= global.grid_cols || logical_row < 0 || logical_row >= global.grid_rows) {
        return false;
    }

    var plant_list = ds_grid_get(global.grid_plants, logical_col, logical_row);

    var plant_to_remove = noone;

    // 按照铲除顺序查找最上层的可移除植物
    for (var i = 0; i < ds_list_size(global.shovel_order); i++) {
        var target_type = ds_list_find_value(global.shovel_order, i);

        // 从上层开始查找（列表最后）
        for (var j = ds_list_size(plant_list) - 1; j >= 0; j--) {
            var plant = ds_list_find_value(plant_list, j);
			if instance_exists(plant){
	            if (plant.plant_type == target_type and plant.can_shovel_remove) {
	                plant_to_remove = plant;
	                break;
	            }
			}
        }

        if (plant_to_remove != noone) break;
    }

    // 移除找到的植物
    if (plant_to_remove != noone) {
        // 播放移除效果
        with (plant_to_remove) {
            // 播放移除动画
            var shovel_effect = instance_create_depth(x+10, y-55, depth, obj_shovel);
			shovel_effect.sprite_index = other.shovel_spr
			if other.flame_rate > 0{
				var flame_cost = get_plant_data_with_skill(plant_id,shape,current_level,skill)[? "cost"]
				var flame_inst = instance_create_depth(x,y-30,-2000,obj_flame)
				flame_inst.value = round(flame_cost * other.flame_rate)
			}
			if global.grid_terrains[logical_row][logical_col].type == "normal"{
				instance_create_depth(logical_world.x + platform_shift_x,logical_world.y + platform_shift_y,-2,obj_place_effect)
				audio_play_sound(snd_place2, 1, false);
			}
			else if global.grid_terrains[logical_row][logical_col].type == "water"{
				var inst = instance_create_depth(logical_world.x + platform_shift_x,logical_world.y + platform_shift_y + 20,-2500,obj_place_effect)
				inst.sprite_index = spr_enter_water_effect
				audio_play_sound(snd_enter_water,0,0)
			}
            instance_destroy();
        }

		if (is_selected) deselect_shovel()

        sort_plants_in_grid(logical_col, logical_row);

    } else {
		// 没有找到可移除的植物

		var shovel_effect = instance_create_depth(logical_world.x + platform_shift_x, logical_world.y + platform_shift_y -55, depth, obj_shovel);
		shovel_effect.sprite_index = shovel_spr
		if global.grid_terrains[logical_row][logical_col].type == "normal"{
				instance_create_depth(logical_world.x + platform_shift_x,logical_world.y + platform_shift_y,-2,obj_place_effect)
				audio_play_sound(snd_place2, 1, false);
			}
			else if global.grid_terrains[logical_row][logical_col].type == "water"{
				var inst = instance_create_depth(logical_world.x + platform_shift_x,logical_world.y + platform_shift_y + 20,-2500,obj_place_effect)
				inst.sprite_index = spr_enter_water_effect
				audio_play_sound(snd_enter_water,0,0)
			}
		if (is_selected) deselect_shovel()

    }
	hotkey_pressed = false

	return true;
}
