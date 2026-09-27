//step事件
if global.is_paused{
	exit
}

if card_id != "magic_chicken"{
	current_cost = cost
	if ds_map_find_value(global.plus_card_map,card_id) != undefined{
		var plus_info = ds_map_find_value(global.plus_card_map,card_id)
		with plus_info[0]{
			if shape < plus_info[1]{
				other.current_cost += 50
			}
		}
	}
}
if global.debug && !coop_battle_active(){
	cooldown_timer = cooldown
}
if cooldown_timer < cooldown{
	cooldown_timer ++


    // 冷却中状态
    is_ready = false;
    cooling_alpha = min(cooling_alpha + 0.05, 0.7); // 淡入冷却效果
} else {
    // 冷却完成状态
    cooling_alpha = max(cooling_alpha - 0.05, 0); // 淡出冷却效果
    
    // 检查阳光是否足够
    if (coop_flame_get(coop_owner) >= current_cost) {
        is_ready = true;
    } else {
        is_ready = false;
    }
}

// Remote owned slots keep cooling down but never consume host input.
if (!info_got) event_user(0);
if (!coop_slot_local(id)) { hover_alpha = 0; exit; }

// 检测鼠标悬停（用于显示提示）
var mx = device_mouse_x_to_gui(0);
var my = device_mouse_y_to_gui(0);
var is_hovered = point_in_rectangle(mx, my, x-42, y-55, x+42, y+50);

// 控制悬停提示透明度
if (is_hovered) {
    hover_alpha = min(hover_alpha + 0.1, 1);
} else {
    hover_alpha = 0
}

// 检测鼠标点击（选中卡槽）
if (is_ready && mouse_check_button_pressed(mb_left)) {
    mx = mouse_x;
    my = mouse_y;
    
    if (point_in_rectangle(mx, my, x-50, y-70, x+50, y+70)) {
		
        select_slot()
        
        // 创建放置预览对象
        if (selected_preview == noone) {
            selected_preview = instance_create_depth(mouse_x, mouse_y, depth-2, obj_card_preview);
            selected_preview.preview_sprite = card_spr; // 设置预览精灵
			if place_preview != undefined{
				selected_preview.preview_sprite = place_preview
			}
            selected_preview.parent_slot = id; // 设置父卡槽
			selected_preview.card_id = card_id
        }
    }
}

var slot_key = global.keybind_map[? "卡槽" + string(slot_index)];

if keyboard_check_pressed(slot_key) && is_ready{
        // 选中当前卡槽
		if !is_selected{
			select_slot()
        
			if global.quick_placement{
				try_place_once()
				// Quick hotkeys are one-shot attempts, including invalid targets.
				// Mouse placement keeps its selection so the player can retry.
				deselect_slot();
			}
			else{
	        // 创建放置预览对象
		        if (selected_preview == noone) {
		            selected_preview = instance_create_depth(mouse_x, mouse_y, depth-2, obj_card_preview);
		            selected_preview.preview_sprite = card_spr; // 设置预览精灵
					if place_preview != undefined{
						selected_preview.preview_sprite = place_preview
					}
		            selected_preview.parent_slot = id; // 设置父卡槽
					selected_preview.card_id = card_id
		        }
			}
		}
		else{
			is_selected = false;
	        if (selected_preview != noone && instance_exists(selected_preview)) {
	            instance_destroy(selected_preview);
	        }
	        selected_preview = noone;
	        global.selected_slot = noone;
		}
    }

// 如果当前卡槽被选中，处理放置逻辑
if (is_selected) {
    // 更新预览位置
    if (selected_preview != noone && instance_exists(selected_preview)) {
        selected_preview.x = mouse_x;
        selected_preview.y = mouse_y;
    }
    
    // 右键取消选择
    if (mouse_check_button_pressed(mb_right)) or (keyboard_check_pressed(vk_escape)) {
        is_selected = false;
        if (selected_preview != noone && instance_exists(selected_preview)) {
            instance_destroy(selected_preview);
        }
        selected_preview = noone;
        global.selected_slot = noone;
    }
    
    // Normal clicks share the same validator as hotkeys and ordered co-op input.
    if (mouse_check_button_pressed(mb_left)) try_place_once();
}

depth = -1 * slot_index - 1000
if info_got == false{
	event_user(0)
}
