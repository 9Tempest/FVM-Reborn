
    if (not audio_is_playing(readyroom_music)) {
        // 停止可能存在的暂停实例
        audio_stop_sound(readyroom_music);
        // 从头开始播放新实例
        audio_play_sound(readyroom_music, 0, 0);
    }
if (coop_prepare_redirect) {
	if (!coop_is_active()) { global.gui_stack.to(room_menu); exit; }
	if (keyboard_check_pressed(vk_escape) || coop_ui_hit(760,640,400,75)) { global.gui_stack.to(room_coop); exit; }
	if (current_time >= coop_prepare_retry_at) {
		coop_prepare_retry_at = current_time + 1000;
		if (global.coop.prepare_loadout(global.level_data.id, global.level_data.name, deck_slot_max())) {
			global.gui_stack.to(room_coop);
		}
	}
	exit;
}
if keyboard_check_pressed(vk_escape) || mouse_check_button_pressed(mb_right){
	if instance_exists(obj_quit_confirm){
		instance_destroy(obj_quit_confirm)
	}
	else{
		if !is_submenu_open{
			instance_create_depth(room_width / 2,room_height / 2,-100,obj_quit_confirm)
		}
	}
}

if instance_exists(obj_quit_confirm) || instance_exists(obj_level_preview){
	is_submenu_open = true
}
else{
	is_submenu_open = false
}
