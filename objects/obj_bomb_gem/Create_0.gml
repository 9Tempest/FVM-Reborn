image_xscale = 0.9
image_yscale = 0.9
image_speed = 0

on_click = false
gem_id = "bomb_gem"
gem_info = get_gem_info(gem_id)
gem_level = get_gem_level(gem_id)

if(gem_level > gem_info.max_level) gem_level = gem_info.max_level

cooldown = gem_info.cooldown[gem_level] * 60
cooldown_timer = gem_info.first_cooldown * 60

range = 7
inst_pos_col = [7,5,7,5,7]
inst_pos_row = [1,2,3,4,5]

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
	text.sprite_index = spr_bomb_gem_text

	for(var i = 0 ; i < array_length(inst_pos_col);i++){
		var inst_pos = get_world_position_from_grid(inst_pos_col[i],inst_pos_row[i])
		var inst = instance_create_depth(inst_pos.x,inst_pos.y+30,-500,obj_bomb_gem_effect)
		inst.grid_row = inst_pos_row[i]
	}

	cooldown_timer = cooldown
	return true;
}
	return false;
}
