// Victory is entirely cosmetic: the reward transaction has already committed.
if (victory_started) {
	var _gold = make_colour_rgb(250, 206, 111)
	var _white = make_colour_rgb(247, 242, 229)
	var _muted = make_colour_rgb(157, 176, 181)
	var _teal = make_colour_rgb(117, 217, 184)
	var _intro = victory_reveal(0)
	draw_set_alpha(0.84 * _intro)
	draw_set_colour(make_colour_rgb(6, 18, 26))
	draw_rectangle(0, 0, room_width, room_height, false)

	// A small deterministic burst avoids changing the gameplay random stream.
	for (var _i = 0; _i < 22; _i++) {
		var _angle = _i * 137.5
		var _radius = 115 + ((_i * 43) mod 470) + min(victory_time, 3) * 26
		var _px = 960 + lengthdir_x(_radius, _angle)
		var _py = 190 + lengthdir_y(_radius * 0.38, _angle)
		draw_set_alpha(_intro * max(0.12, 0.6 - victory_time * 0.11))
		draw_set_colour(_i mod 3 == 0 ? _teal : _gold)
		draw_circle(_px, _py, 2 + (_i mod 3), false)
	}
	var _title_y = 151 - (1 - _intro) * 32
	victory_text(960, _title_y - 58, first_complete ? "首次通关" : "挑战完成", 0.95, _gold, _intro, fa_center, 500)
	victory_text(963, _title_y + 4, "冒险胜利", 3.15 + (1 - _intro) * 0.25, c_black, _intro * 0.4, fa_center, 800)
	victory_text(960, _title_y, "冒险胜利", 3.15 + (1 - _intro) * 0.25, _gold, _intro, fa_center, 800)
	victory_text(960, 227, global.level_data.name, 1.2, _white, _intro, fa_center, 1000)

	var _panel = victory_reveal(0.15)
	draw_set_alpha(_panel * 0.4)
	draw_set_colour(c_black)
	draw_roundrect_ext(195, 293, 1735, 922, 26, 26, false)
	draw_set_alpha(_panel)
	draw_set_colour(make_colour_rgb(17, 34, 44))
	draw_roundrect_ext(190, 278, 1730, 910, 26, 26, false)
	draw_set_colour(make_colour_rgb(37, 59, 68))
	draw_roundrect_ext(190, 278, 1730, 910, 26, 26, true)
	draw_set_colour(_gold)
	draw_line_width(230, 279, 530, 279, 3)
	draw_set_colour(make_colour_rgb(49, 69, 74))
	draw_line(550, 322, 550, 866)

	victory_text(240, 332, "通关统计", 1.4, _white, _panel, fa_left, 270)
	var _seconds = floor(obj_battle.battle_time / 60)
	var _time = string(floor(_seconds / 60)) + ":" + string_format(_seconds mod 60, 2, 0)
	_time = string_replace_all(_time, " ", "0")
	victory_text(240, 400, "通关时间", 0.9, _muted, _panel, fa_left, 270)
	victory_text(240, 443, _time, 2.1, _white, _panel, fa_left, 270)
	victory_text(240, 511, "卡片损失", 0.9, _muted, _panel, fa_left, 180)
	victory_text(512, 511, string(obj_task_manager.card_loss), 1.4, _white, _panel, fa_right, 85)
	victory_text(240, 554, "猫损失", 0.9, _muted, _panel, fa_left, 180)
	victory_text(512, 554, string(obj_task_manager.cat_loss), 1.4, _white, _panel, fa_right, 85)
	victory_text(240, 597, "难度", 0.9, _muted, _panel, fa_left, 180)
	victory_text(512, 597, string(global.difficulty), 1.1, _white, _panel, fa_right, 170)
	for (var _i = 0; _i < array_length(victory_milestones); _i++) {
		var _a = victory_reveal(0.5 + _i * 0.1)
		victory_text(240, 692 + _i * 41, victory_milestones[_i], 0.95, _teal, _a, fa_left, 276)
	}

	victory_text(590, 332, "通关奖励", 1.4, _white, _panel, fa_left, 500)
	for (var _i = 0; _i < 4; _i++) {
		var _index = victory_page * 4 + _i
		if (_index >= array_length(victory_resources)) break;
		var _entry = victory_resources[_index]
		var _a = victory_reveal(0.45 + _i * 0.15)
		var _x = 590 + _i * 278
		var _y = 375 + (1 - _a) * 24
		draw_set_alpha(_a)
		draw_set_colour(make_colour_rgb(30, 49, 58))
		draw_roundrect_ext(_x, _y, _x + 260, _y + 108, 14, 14, false)
		victory_icon(_entry.sprite, _entry.frame, _x + 48, _y + 54, 62, 68, _a)
		victory_text(_x + 92, _y + 31, _entry.name, 0.85, _muted, _a, fa_left, 153)
		victory_text(_x + 92, _y + 74, "+" + string(_entry.amount), 1.6, _gold, _a, fa_left, 153)
	}
	if (array_length(victory_resources) == 0) {
		victory_text(590, 428, "本关挑战已完成", 1.2, _muted, _panel, fa_left, 1000)
	}
	victory_text(590, 531, "获得物品", 1.4, _white, _panel, fa_left, 550)
	var _unlocks_count = min(6, max(0, array_length(victory_unlocks) - victory_page * 6))
	for (var _i = 0; _i < _unlocks_count; _i++) {
		var _entry = victory_unlocks[victory_page * 6 + _i]
		var _a = victory_reveal(0.95 + _i * 0.16)
		var _x = 590 + _i * 185
		var _y = 578 + (1 - _a) * 35
		var _accent = _entry.card ? _gold : _teal
		draw_set_alpha(_a * 0.22)
		draw_set_colour(_accent)
		draw_roundrect_ext(_x - 3, _y - 3, _x + 173, _y + 273, 16, 16, false)
		draw_set_alpha(_a)
		draw_set_colour(make_colour_rgb(27, 44, 53))
		draw_roundrect_ext(_x, _y, _x + 170, _y + 270, 14, 14, false)
		victory_text(_x + 85, _y + 24, _entry.kind, 0.75, _accent, _a, fa_center, 140)
		if (_entry.card) {
			victory_icon(spr_slot, 0, _x + 85, _y + 121, 118, 157, _a)
			victory_icon(_entry.sprite, 0, _x + 85, _y + 110, 91, 94, _a)
			victory_icon(spr_flame, 0, _x + 61, _y + 177, 17, 23, _a)
			victory_text(_x + 78, _y + 176, string(_entry.cost), 0.7, make_colour_rgb(59, 39, 25), _a, fa_left, 52)
		} else {
			draw_set_alpha(_a * 0.08)
			draw_set_colour(_accent)
			draw_circle(_x + 85, _y + 126, 60, false)
			victory_icon(_entry.sprite, 0, _x + 85, _y + 125, 96, 114, _a)
		}
		victory_text(_x + 85, _y + 224, _entry.name, 0.95, _white, _a, fa_center, 148)
		victory_text(_x + 85, _y + 249, "已解锁", 0.65, _accent, _a, fa_center, 148)
	}
	if (_unlocks_count == 0) {
		draw_set_alpha(_panel)
		draw_set_colour(make_colour_rgb(24, 43, 52))
		draw_roundrect_ext(590, 578, 1700, 848, 16, 16, false)
		victory_text(1145, 699, "每一次胜利，都让冒险更进一步", 1.5, _white, _panel, fa_center, 990)
		victory_text(1145, 748, "继续探索，收集更多卡片", 1, _muted, _panel, fa_center, 990)
	}

	var _ready = victory_time >= victory_duration
	victory_text(230, 976, _ready ? "空格继续    左右方向键查看奖励" : "点击或按空格键，立即展示全部奖励", 0.9, _muted, _intro, fa_left, 920)
	if (victory_pages > 1) {
		victory_text(1240, 977, "<", 1.5, _muted, _intro, fa_center, 50)
		victory_text(1300, 977, string(victory_page + 1) + "/" + string(victory_pages), 0.9, _white, _intro, fa_center, 60)
		victory_text(1360, 977, ">", 1.5, _muted, _intro, fa_center, 50)
	}
	var _hover = point_in_rectangle(mouse_x, mouse_y, 1430, 942, 1710, 1012)
	draw_set_alpha(_intro)
	draw_set_colour(_hover ? make_colour_rgb(255, 222, 152) : _gold)
	draw_roundrect_ext(1430, 942, 1710, 1012, 18, 18, false)
	var _exit_label = coop_is_active() ? (global.coop.result_saved ? "回到合作房间" : "等待存档确认") : "返回地图"
	victory_text(1570, 977, !_ready ? "跳过动画" : (victory_page < victory_pages - 1 ? "下一页" : _exit_label), 1.15, make_colour_rgb(37, 37, 32), _intro, fa_center, 240)
	draw_set_alpha(1)
	draw_set_colour(c_white)
	draw_set_halign(fa_left)
	draw_set_valign(fa_top)
	exit;
}

// Preserve the existing pause and defeat presentation.
if (global.is_paused && !global.show_menu) {
	draw_set_alpha(0.5)
	draw_set_colour(c_black)
	draw_rectangle(0, 0, room_width, room_height, false)
	draw_set_alpha(1)
	draw_set_font(font_yuan)
	draw_set_halign(fa_center)
	draw_set_valign(fa_middle)
	draw_set_colour(c_white)
	if (obj_battle.battle_time == 1) {
		draw_sprite_ext(spr_place_player_tip, 0, room_width / 2, room_height / 2, 1.8, 1.8, 0, c_white, 1)
	} else if (!global.game_over) {
		draw_text(room_width / 2, room_height / 2, "暂停中")
	} else {
		draw_text(room_width / 2, room_height / 2 + 150, "左键点击或按空格键继续……")
		if (obj_game_over.sprite_index == spr_lose) draw_text(room_width / 2, room_height / 2 + 175, "按R重新开始")
	}
}
