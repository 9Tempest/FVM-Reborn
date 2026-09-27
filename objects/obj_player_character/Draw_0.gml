if (coop_battle_active() && !is_placed && coop_owner != global.coop.player_id) exit;
if not is_placed{
	var can_plant = (can_place_at_position(mouse_x, mouse_y, "normal","amphi","none"));
	if can_plant{
		var grid_pos = get_grid_position_from_world(mouse_x,mouse_y)
		draw_sprite_ext(sprite_index,0,grid_pos.x,grid_pos.y,1.6,1.6,0,c_white,0.5)
	}
}

if flash_value >0{
	
    draw_self()
	shader_set(hit_effect_2);
	draw_sprite_ext(sprite_index,image_index,x,y,image_xscale,image_yscale,image_angle,c_white,flash_value/200);
	shader_reset();
	
}
else{
	image_blend = c_white
	draw_self()
	
}
if (coop_battle_active() && is_placed) {
	draw_set_font(font_yuan);
	draw_set_halign(fa_center);
	draw_set_valign(fa_bottom);
	draw_set_colour(coop_owner == global.coop.player_id ? c_aqua : c_yellow);
	draw_text(x, y - 125, coop_owner == global.coop.player_id ? "你" : "队友");
	draw_set_colour(c_white);
	draw_set_halign(fa_left);
	draw_set_valign(fa_top);
}
