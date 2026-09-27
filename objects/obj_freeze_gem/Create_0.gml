image_xscale = 0.9
image_yscale = 0.9
image_speed = 0

on_click = false
gem_id = "freeze_gem"
gem_info = get_gem_info(gem_id)
gem_level = get_gem_level(gem_id)

if(gem_level > gem_info.max_level) gem_level = gem_info.max_level

cooldown = gem_info.cooldown[gem_level] * 60
cooldown_timer = gem_info.first_cooldown * 60//cooldown

range = 7

coop_gem_index = -1;
function try_use_gem(_player, _ordered = false) {
	if (coop_battle_active() && !_ordered) {
		global.coop.send_input("use_gem", {gem_index:coop_gem_index, gem_id:gem_id});
		return true;
	}
	if (global.is_paused || global.game_over || !instance_exists(_player) || !_player.is_placed) return false;
if cooldown_timer <= 0{
	audio_play_sound(snd_button,0,0)

	var text = instance_create_depth(room_width/2+80,room_height/3-100,-500,obj_gem_text)
	text.sprite_index = spr_freeze_gem_text

	var real_range = range - 1
	var up_range = floor(real_range/2)
	var down_range = ceil(real_range/2)
	var start_row = _player.grid_row
	if start_row - up_range < 0{
		start_row = up_range
	}
	if start_row + down_range > global.grid_rows - 1{
		start_row = global.grid_rows - down_range - 1
	}
	var inst_pos1 = get_world_position_from_grid(-1,start_row){
		var inst1 = instance_create_depth(inst_pos1.x,inst_pos1.y+35,-500,obj_freeze_gem_spawn)
		inst1.row = start_row
	}
	for(var i = 1;i<=up_range;i++){
		var inst_pos = get_world_position_from_grid(-1,start_row-i)
		var inst = instance_create_depth(inst_pos1.x,inst_pos.y+35,-500,obj_freeze_gem_spawn)
		inst.row = start_row-i
	}
	for(var i = 1;i<=down_range;i++){
		var inst_pos = get_world_position_from_grid(-1,start_row+i)
		var inst = instance_create_depth(inst_pos1.x,inst_pos.y+35,-500,obj_freeze_gem_spawn)
		inst.row = start_row+i
	}

	cooldown_timer = cooldown
	return true;
}
	return false;
}
