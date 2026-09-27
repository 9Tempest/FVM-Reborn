// obj_battle_pause_manager - Create Event
global.is_paused = false;
global.show_menu = false; // 新增变量控制菜单显示
depth = -3000

settlement = false
first_complete = false

slot_unlock_level_id_list = ["cookie_island","salad_island_land","salad_island_water","champagne_island_land","champagne_island_water","cocoa_island_daytime","curry_island_night"]

// Reward commitment is separate from the player opening the results panel.
rewards_committed = false
function commit_victory_rewards() {
	if (rewards_committed) return;
	if (!global.game_over || !instance_exists(obj_game_over)) return;
	if (obj_game_over.sprite_index != spr_win) return;
	rewards_committed = true

	// Legacy/custom stages keep their existing reward rules. Flush battle gains.
	if (global.level_file.version == "1.0.0" || global.laboretory_room) {
		save_file(global.save_slot)
		start_victory_presentation()
		return;
	}

	save_transaction_begin()
	with obj_task_manager{
		refresh_task_progress()
	}
	if array_get_index(global.save_data.completed_levels,global.level_data.id) == -1{
		complete_level(global.level_data.id)
		first_complete = true
		if array_get_index(slot_unlock_level_id_list,global.level_data.id) != -1{
			if global.save_data.unlocked_items.max_slot < 21{
				global.save_data.unlocked_items.max_slot += 1
				show_notice("你解锁了一个新的卡槽",60)
			}
		}
		if global.level_data.id == "champagne_island_water"{
			global.save_data.unlocked_items.elite_unlocked = true
		}
		if global.level_data.id == "abyss"{
			global.save_data.unlocked_items.shovel = "copper"
		}
		if global.level_data.id == "macchiato_port"{
			global.save_data.unlocked_items.shovel = "silver"
		}
		if global.level_data.id == "snowcap_volcano"{
			global.save_data.unlocked_items.shovel = "gold"
		}
		if global.level_data.id == "tower_cake_35_3"{
			global.save_data.player.crown_version = global.game_version
		}
		if global.level_file.rewards[1].player_level >= global.save_data.player.level{
			global.save_data.player.level = global.level_file.rewards[1].player_level
		}
		if global.level_file.rewards[1].skill_level >= global.save_data.unlocked_items.max_skill_level{
			global.save_data.unlocked_items.max_skill_level = global.level_file.rewards[1].skill_level
			var length = array_length(global.save_data.unlocked_cards)
			for (var i = 0;i < length;i++){
				global.save_data.unlocked_cards[i].skill = global.save_data.unlocked_items.max_skill_level
			}

		}
		global.save_data.player.gold += global.level_file.rewards[1].gold
		var item_list = global.level_file.rewards[1].items
		for(var i = 0 ; i < array_length(item_list) ; i++){
			var item_id = item_list[i].id
			add_material_amount(item_id,real(item_list[i].amount))
		}

		var card_unlock_id_list = global.level_file.rewards[1].card_unlock
		for(var i = 0 ; i < array_length(card_unlock_id_list) ; i++){
			var card_id = card_unlock_id_list[i]
			unlock_card(card_id,0,0,global.save_data.unlocked_items.max_skill_level)
		}

		var weapon_unlock_id_list = global.level_file.rewards[1].weapon_unlock
		for(var i = 0 ; i < array_length(weapon_unlock_id_list) ; i++){
			var weapon_id = weapon_unlock_id_list[i]
			unlock_weapon(weapon_id)
		}

		var gem_unlock_id_list = global.level_file.rewards[1].gem_unlock
		for(var i = 0 ; i < array_length(gem_unlock_id_list) ; i++){
			var gem_id = gem_unlock_id_list[i]
			unlock_gem(gem_id)
		}
	}
	else{
		global.save_data.player.gold += global.level_file.rewards[0].gold
		var item_list = global.level_file.rewards[0].items
		for(var i = 0 ; i < array_length(item_list) ; i++){
			var item_id = item_list[i].id
			add_material_amount(item_id,item_list[i].amount)
		}
	}
	// First-clear flags, all unlocks, task progress and all rewards reach disk together.
	save_file(global.save_slot)
	save_transaction_end()
	start_victory_presentation()
}

// Presentation uses a read-only snapshot. It never grants or saves rewards.
victory_started = false
victory_time = 0
victory_page = 0
victory_pages = 1
victory_resources = []
victory_unlocks = []
victory_milestones = []
victory_duration = 2.2

function start_victory_presentation() {
	if (victory_started) return;
	victory_started = true
	settlement = true
	global.show_menu = false
	obj_game_over.image_alpha = 0
	if (global.level_file.version == "1.0.0" || global.laboretory_room) return;
	var _reward = global.level_file.rewards[first_complete ? 1 : 0]
	if (_reward.gold > 0) array_push(victory_resources, {name:"金币", amount:_reward.gold, sprite:spr_coin, frame:0})
	for (var _i = 0; _i < array_length(_reward.items); _i++) {
		var _item = _reward.items[_i]
		var _info = get_material_info(_item.id)
		array_push(victory_resources, {name:_info.name, amount:_item.amount, sprite:spr_craft_material, frame:_info.icon})
	}
	if (first_complete) {
		for (var _i = 0; _i < array_length(_reward.card_unlock); _i++) {
			var _id = _reward.card_unlock[_i]
			var _card = deck_get_card_data(_id, 0)
			var _name = get_plant_shape_data(_id, 0)[? "name"]
			array_push(victory_unlocks, {name:_name, kind:"卡片", sprite:_card[? "sprite"], cost:_card[? "cost"], card:true})
		}
		for (var _i = 0; _i < array_length(_reward.weapon_unlock); _i++) {
			var _info = get_weapon_info(_reward.weapon_unlock[_i])
			array_push(victory_unlocks, {name:_info.name, kind:"武器", sprite:_info.icon, cost:0, card:false})
		}
		for (var _i = 0; _i < array_length(_reward.gem_unlock); _i++) {
			var _info = get_gem_info(_reward.gem_unlock[_i])
			array_push(victory_unlocks, {name:_info.name, kind:"宝石", sprite:_info.icon, cost:0, card:false})
		}
		if (_reward.player_level > 0) array_push(victory_milestones, "角色等级  " + string(global.save_data.player.level))
		if (_reward.skill_level > 0) array_push(victory_milestones, "技能等级  " + string(global.save_data.unlocked_items.max_skill_level))
		if (array_get_index(slot_unlock_level_id_list, global.level_data.id) != -1) array_push(victory_milestones, "新的卡槽已解锁")
		switch (global.level_data.id) {
			case "champagne_island_water": array_push(victory_milestones, "精英段已解锁"); break;
			case "abyss": array_push(victory_milestones, "铜铲已解锁"); break;
			case "macchiato_port": array_push(victory_milestones, "银铲已解锁"); break;
			case "snowcap_volcano": array_push(victory_milestones, "金铲已解锁"); break;
			case "tower_cake_35_3": array_push(victory_milestones, "冒险勋章已获得"); break;
		}
	}
	victory_pages = max(1, ceil(array_length(victory_resources) / 4), ceil(array_length(victory_unlocks) / 6))
}

function victory_page_duration() {
	var _resources = min(4, max(0, array_length(victory_resources) - victory_page * 4))
	var _unlocks = min(6, max(0, array_length(victory_unlocks) - victory_page * 6))
	return max(1.5, 0.85 + _resources * 0.15, 1.35 + _unlocks * 0.16)
}

function victory_reveal(_delay) {
	var _t = clamp((victory_time - _delay) / 0.38, 0, 1)
	return 1 - power(1 - _t, 3)
}

function victory_text(_x, _y, _text, _scale, _colour, _alpha, _align, _width) {
	draw_set_font(font_yuan)
	draw_set_halign(_align)
	draw_set_valign(fa_middle)
	draw_set_colour(_colour)
	draw_set_alpha(_alpha)
	_scale = min(_scale, _width / max(1, string_width(_text)))
	draw_text_transformed(_x, _y, _text, _scale, _scale, 0)
}

// Fit the visible art, including sprites whose origin is at the feet.
function victory_icon(_sprite, _frame, _x, _y, _w, _h, _alpha) {
	var _left = sprite_get_bbox_left(_sprite)
	var _top = sprite_get_bbox_top(_sprite)
	var _sw = sprite_get_bbox_right(_sprite) - _left + 1
	var _sh = sprite_get_bbox_bottom(_sprite) - _top + 1
	var _scale = min(_w / _sw, _h / _sh)
	draw_sprite_part_ext(_sprite, _frame, _left, _top, _sw, _sh, _x - _sw * _scale / 2, _y - _sh * _scale / 2, _scale, _scale, c_white, _alpha)
}

function leave_victory_screen() {
	if (global.map_id == "tower_cake" || global.map_id == "delicious_town") {
		global.map_id = "delicious_island"
		global.map_name = "美味岛"
	}
	global.gui_stack.pop()
	global.gui_stack.pop()
	global.menu_screen = true
	obj_world_map_button.world_map = 0
}
