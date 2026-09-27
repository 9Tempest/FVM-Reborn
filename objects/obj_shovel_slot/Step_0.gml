// 控制悬停提示透明度
if global.is_paused{
	exit
}
var slot_key = global.keybind_map[? "铲子"];
// 检测鼠标点击
if (mouse_check_button_pressed(mb_left)) {
    mx = mouse_x;
    my = mouse_y;
    
    if (point_in_rectangle(mx, my, x, y, x+150, y+150)) {
        select_shovel();
		audio_play_sound(snd_shovel,0,0)
    }
}
if keyboard_check_pressed(slot_key){
	if !is_selected{
		select_shovel();
		hotkey_pressed = true
		audio_play_sound(snd_shovel,0,0)
	}
	else{
		deselect_shovel();
	}
}
if ((mouse_check_button_pressed(mb_right) or keyboard_check_pressed(vk_escape)) && is_selected) {
    deselect_shovel();
}
// 在铲子槽对象 (obj_shovel_slot) 的鼠标点击处理中添加:
if ((is_selected && mouse_check_button_pressed(mb_left)) or (is_selected && global.quick_placement && hotkey_pressed)) {
	try_shovel_once(mouse_x, mouse_y);
	hotkey_pressed = false;
}
