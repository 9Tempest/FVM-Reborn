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
	if (rewards_committed) return
	if (!global.game_over || !instance_exists(obj_game_over)) return
	if (obj_game_over.sprite_index != spr_win) return
	rewards_committed = true

	// Legacy/custom stages keep their existing reward rules. Flush battle gains.
	if (global.level_file.version == "1.0.0" || global.laboretory_room) {
		save_file(global.save_slot)
		return
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
}
