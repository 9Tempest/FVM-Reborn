// Commit a victory before waiting for input, including End Step victories.
commit_victory_rewards()

// All input below this branch is the existing pause/defeat flow.
if (victory_started) {
	victory_time += min(delta_time / 1000000, 0.05)
	victory_duration = victory_page_duration()
	var _advance = keyboard_check_pressed(vk_space) || keyboard_check_pressed(vk_enter)
	var _click = mouse_check_button_pressed(mb_left)
	if (victory_time > 0.2 && (_advance || _click)) {
		if (victory_time < victory_duration) {
			victory_time = victory_duration
		} else if (_advance || point_in_rectangle(mouse_x, mouse_y, 1430, 942, 1710, 1012)) {
			if (victory_page < victory_pages - 1) {
				victory_page++
				victory_time = 0.4
			} else {
				leave_victory_screen()
				exit;
			}
		}
	}
	if (victory_pages > 1 && victory_time >= victory_duration) {
		var _previous = keyboard_check_pressed(vk_left) || (_click && point_in_rectangle(mouse_x, mouse_y, 1210, 947, 1270, 1007))
		var _next = keyboard_check_pressed(vk_right) || (_click && point_in_rectangle(mouse_x, mouse_y, 1330, 947, 1390, 1007))
		if (_previous && victory_page > 0) { victory_page--; victory_time = victory_page_duration() }
		if (_next && victory_page < victory_pages - 1) { victory_page++; victory_time = 0.4 }
	}
	exit;
}

// obj_battle_pause_manager - Step Event
if (keyboard_check_pressed(vk_space) || (mouse_check_button_pressed(mb_left) && global.game_over)) {	
    //if global.selected_slot == noone {
        if (!global.is_paused) {
            // 空格暂停：只暂停不显示菜单
            global.is_paused = true;
            global.show_menu = false;
        }
        else if (global.is_paused && !global.show_menu) {
            // 取消暂停
			if global.game_over{
				if settlement || obj_game_over.sprite_index == spr_lose || global.level_file.version == "1.0.0"{
					if global.map_id == "tower_cake" || global.map_id == "delicious_town"{
						global.map_id = "delicious_island"
						global.map_name = "美味岛"
					}
					global.gui_stack.pop()
					if (obj_game_over.sprite_index != spr_lose) {
						global.gui_stack.pop()
					}
					global.menu_screen = true
					obj_world_map_button.world_map = 0
				}
				if global.level_file.version != "1.0.0"{
					if obj_game_over.sprite_index == spr_win && !settlement{
						commit_victory_rewards()
						settlement = true
						obj_game_over.image_alpha = 0
					}
				}
				
				
			}
			if obj_battle.battle_time != 0 && !global.game_over{
				global.is_paused = false;
			}
        }
    //}
}

if (keyboard_check_pressed(vk_escape)) {
    if (!global.is_paused) {
        // ESC暂停：暂停并显示菜单
        global.is_paused = true;
        global.show_menu = true;
        
        // 创建暂停菜单实例
        
        instance_create_depth(room_width / 2, room_height / 2, depth, obj_pause_menu);
    }
    else if (global.is_paused && global.show_menu) {
        // 尝试关闭菜单（菜单自身会处理ESC关闭）
        var menu = instance_find(obj_pause_menu, 0);
        if (menu != noone && !menu.submenu_open) {
            instance_destroy(menu);
            global.is_paused = false;
            global.show_menu = false;
        }
    }
}

if (keyboard_check_pressed(ord("R"))) {
	if global.game_over{
		if obj_game_over.sprite_index == spr_lose{
			room_restart()
		}
	}
}

if obj_battle.battle_time == 1{
	global.is_paused = true;
}