// All progress is synthetic and in memory. Any save call is counted, never written.
function save_file(_slot) {
	global.fixture_saves++
	global.fixture_saved = json_stringify(global.save_data)
	if (global.fixture_coop_active) global.fixture_coop_saves++; else global.fixture_solo_saves++;
	return true
}
function save_transaction_begin() { global.fixture_transactions++; global.fixture_transaction_depth++ }
function save_transaction_end() { global.fixture_transaction_depth-- }
function show_notice(_text, _frames) { }
function complete_level(_id) { array_push(global.save_data.completed_levels, _id) }
function add_material_amount(_id, _amount) {
	global.fixture_materials += _amount
	variable_struct_set(global.fixture_inventory, _id, _amount)
}
function unlock_card(_id, _level, _shape, _skill) { global.fixture_grants++ }
function unlock_weapon(_id) { global.fixture_grants++ }
function unlock_gem(_id) { global.fixture_grants++ }
function deck_get_card_data(_id, _shape) { return global.fixture_cards[? _id] }
function get_plant_shape_data(_id, _shape) { return global.fixture_cards[? _id] }
function get_material_info(_id) { return {name:"天然香料", icon:0} }
function get_weapon_info(_id) { return _id == "star_gun" ? {name:"星星枪", icon:FIXTURE_WEAPON_A} : {name:"饼干盾牌", icon:FIXTURE_WEAPON_B} }
function get_gem_info(_id) { return {name:"攻击宝石", icon:FIXTURE_GEM} }

function fixture_init() {
	window_set_size(1280, 720)
	window_center()
	global.fixture_saves = 0
	global.fixture_grants = 0
	global.fixture_materials = 0
	global.fixture_failed = 0
	global.fixture_tests = []
	global.fixture_coop_active = false
	global.game_version = "fixture-version"
	global.fixture_cards = ds_map_create()
	var _ids = ["double_long_bao", "coke_bomb", "mouse_clip"]
	var _names = ["双层小笼包", "可乐炸弹", "老鼠夹子"]
	var _sprites = [spr_double_long_bao, spr_coke_bomb, spr_mouse_clip]
	var _costs = [200, 150, 25]
	for (var _i = 0; _i < 3; _i++) {
		var _data = ds_map_create()
		_data[? "name"] = _names[_i]
		_data[? "sprite"] = _sprites[_i]
		_data[? "cost"] = _costs[_i]
		global.fixture_cards[? _ids[_i]] = _data
	}
	global.save_slot = 0
	global.save_data = {player:{level:1, gold:0}, completed_levels:[], unlocked_cards:[], unlocked_items:{max_skill_level:0, max_slot:5}}
	global.laboretory_room = false
	global.difficulty = 3
	global.level_data = {id:"cookie_island", name:"曲奇岛"}
	global.level_file = {version:"1.1.0", rewards:[
		{gold:350, items:[{id:"natural_spices", amount:10}]},
		{gold:1000, items:[{id:"natural_spices", amount:20}], player_level:2, skill_level:1,
		card_unlock:_ids, weapon_unlock:["star_gun", "cookie_shield"], gem_unlock:["attack_gem"]}
	]}
	global.gui_stack = {pop: function() { show_debug_message("FVM_VICTORY_CONTINUE"); game_end() }}
	global.map_id = "delicious_island"
	var _battle = instance_create_depth(0, 0, 0, obj_battle)
	_battle.battle_time = 9600
	_battle.reward_difficulty = 3
	var _task = instance_create_depth(0, 0, 0, obj_task_manager)
	_task.card_loss = 3
	_task.cat_loss = 0
	_task.refresh_task_progress = function() { global.fixture_task_refreshes++ }
	instance_create_depth(0, 0, -3001, obj_game_over).sprite_index = spr_win
	instance_create_depth(0, 0, 0, obj_world_map_button)
	fixture_reward_regressions()
	fixture_reset(3, false, false)
	global.level_file.rewards = [
		{gold:350, items:[{id:"natural_spices", amount:10}]},
		{gold:1000, items:[{id:"natural_spices", amount:20}], player_level:2, skill_level:1,
		card_unlock:_ids, weapon_unlock:["star_gun", "cookie_shield"], gem_unlock:["attack_gem"]}
	]
	global.save_data.player.gold = 0
	global.game_over = true
	var _ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	global.is_paused = true
	_ui.commit_victory_rewards()
	_ui.commit_victory_rewards()
	fixture_expect("win commits once", global.save_data.player.gold == 2000 && global.fixture_saves == 1)
	fixture_expect("all unlocks and materials committed", global.fixture_grants == 6 && global.fixture_materials == 40)
	fixture_expect("first clear and presentation flags", _ui.rewards_committed && _ui.victory_started && _ui.first_complete)
	fixture_expect("real card art collected", array_length(_ui.victory_unlocks) == 6 && _ui.victory_unlocks[0].sprite == spr_double_long_bao)
	global.fixture_saves = 0
}


function fixture_reset(_difficulty, _repeat, _coop) {
	with (obj_battle_pause_manager) instance_destroy()
	global.fixture_saves = 0
	global.fixture_solo_saves = 0
	global.fixture_coop_saves = 0
	global.fixture_saved = ""
	global.fixture_transactions = 0
	global.fixture_transaction_depth = 0
	global.fixture_task_refreshes = 0
	global.fixture_grants = 0
	global.fixture_materials = 0
	global.fixture_inventory = {}
	global.fixture_coop_active = _coop
	global.laboretory_room = false
	global.difficulty = (_difficulty + 1) mod 4
	obj_battle.reward_difficulty = _difficulty
	global.level_data = {id:"cookie_island", name:"曲奇岛"}
	global.level_file = {version:"1.1.0", rewards:[
		{gold:37, items:[{id:"natural_spices", amount:5}, {id:"secret_spices", amount:1}]},
		{gold:101, items:[{id:"natural_spices", amount:3}, {id:"secret_spices", amount:"7"}], player_level:2, skill_level:1,
		card_unlock:["double_long_bao", "coke_bomb", "mouse_clip"], weapon_unlock:["star_gun", "cookie_shield"], gem_unlock:["attack_gem"]}
	]}
	global.save_data = {player:{level:1, gold:71}, completed_levels:_repeat ? ["cookie_island"] : [],
		unlocked_cards:[], unlocked_items:{max_skill_level:0, max_slot:5}}
	global.game_over = true
	obj_game_over.sprite_index = spr_win
}

function fixture_reward_regressions() {
	// Explicit expected tables keep the assertions independent of production helpers.
	var _multipliers = [1, 1.25, 1.5, 2]
	var _gold_first = [101,126,151,202]
	var _gold_repeat = [37,46,55,74]
	var _natural_first = [3,3,4,6]
	var _natural_repeat = [5,6,7,10]
	var _secret_first = [7,8,10,14]
	var _secret_repeat = [1,1,1,2]
	var _mode_results = []
	for (var _mode = 0; _mode < 2; _mode++) {
		for (var _difficulty = 0; _difficulty < 4; _difficulty++) {
			for (var _repeat = 0; _repeat < 2; _repeat++) {
				fixture_reset(_difficulty, _repeat == 1, _mode == 1)
				var _original = json_stringify(global.level_file)
				var _ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
				// Both values can change after Create, without changing this result.
				global.difficulty = (3 - _difficulty)
				obj_battle.reward_difficulty = (3 - _difficulty)
				_ui.commit_victory_rewards()
				var _expected_gold = _repeat ? _gold_repeat[_difficulty] : _gold_first[_difficulty]
				var _expected_natural = _repeat ? _natural_repeat[_difficulty] : _natural_first[_difficulty]
				var _expected_secret = _repeat ? _secret_repeat[_difficulty] : _secret_first[_difficulty]
				var _label = (_mode ? "coop " : "solo ") + string(_difficulty) + (_repeat ? " repeat: " : " first: ")
				fixture_expect(_label + "opening difficulty stays frozen", _ui.reward_difficulty == _difficulty && _ui.reward_multiplier == _multipliers[_difficulty] && _ui.reward_scaling_applied)
				fixture_expect(_label + "gold scales with floor, existing battle gains unchanged", global.save_data.player.gold == 71 + _expected_gold)
				fixture_expect(_label + "each material scales with floor", global.fixture_inventory.natural_spices == _expected_natural && global.fixture_inventory.secret_spices == _expected_secret)
				fixture_expect(_label + "presentation exactly matches grants", array_length(_ui.victory_resources) == 3 && _ui.victory_resources[0].amount == _expected_gold && _ui.victory_resources[1].amount == _expected_natural && _ui.victory_resources[2].amount == _expected_secret)
				fixture_expect(_label + "stable resource IDs and base counts", _ui.victory_resources[0].id == "gold" && _ui.victory_resources[0].base_amount == (_repeat ? 37 : 101) && _ui.victory_resources[1].id == "natural_spices" && _ui.victory_resources[1].base_amount == (_repeat ? 5 : 3) && _ui.victory_resources[2].id == "secret_spices" && _ui.victory_resources[2].base_amount == (_repeat ? 1 : 7))
				fixture_expect(_label + "unlock and level rules do not multiply", global.fixture_grants == (_repeat ? 0 : 6) && global.save_data.player.level == (_repeat ? 1 : 2) && global.save_data.unlocked_items.max_skill_level == (_repeat ? 0 : 1) && global.save_data.unlocked_items.max_slot == (_repeat ? 5 : 6) && array_length(global.save_data.completed_levels) == 1)
				fixture_expect(_label + "one complete transaction", global.fixture_saves == 1 && global.fixture_transactions == 1 && global.fixture_transaction_depth == 0 && global.fixture_task_refreshes == 1 && global.fixture_saved == json_stringify(global.save_data))
				var _committed = json_stringify(global.save_data)
				var _materials = global.fixture_materials
				_ui.commit_victory_rewards()
				_ui.start_victory_presentation()
				fixture_expect(_label + "repeated commit and presentation do not grant twice", json_stringify(global.save_data) == _committed && global.fixture_saves == 1 && global.fixture_materials == _materials && array_length(_ui.victory_resources) == 3)
				fixture_expect(_label + "source map reward JSON untouched", json_stringify(global.level_file) == _original)
				if (_mode == 0) array_push(_mode_results, _committed); else fixture_expect(_label + "same campaign result as solo", _committed == _mode_results[_difficulty * 2 + _repeat]);
			}
		}
	}
	fixture_reset(3, false, false)
	obj_game_over.sprite_index = spr_lose
	var _ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	_ui.commit_victory_rewards()
	fixture_expect("defeat never grants victory rewards", global.save_data.player.gold == 71 && global.fixture_saves == 0 && !_ui.rewards_committed && !_ui.victory_started)
	obj_game_over.sprite_index = spr_win
	global.game_over = false
	_ui.commit_victory_rewards()
	fixture_expect("unfinished battle never grants rewards", global.fixture_saves == 0 && !_ui.rewards_committed)

	for (var _excluded = 0; _excluded < 2; _excluded++) {
		fixture_reset(3, false, false)
		if (_excluded == 0) global.level_file = {version:"1.0.0"}; else global.laboretory_room = true;
		_ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
		_ui.commit_victory_rewards()
		_ui.commit_victory_rewards()
		fixture_expect((_excluded == 0 ? "legacy without reward schema" : "laboratory with rewards") + " retains no-clear-reward rule", global.save_data.player.gold == 71 && global.fixture_materials == 0 && global.fixture_grants == 0 && array_length(global.save_data.completed_levels) == 0 && global.fixture_saves == 1 && !_ui.reward_scaling_applied && array_length(_ui.victory_resources) == 0)
	}

	fixture_reset(3, false, false)
	global.level_file.version = 1.5
	global.level_data = {id:"tower_cake_35_3", name:"蛋糕塔终章"}
	global.level_file.rewards = [{gold:1000, items:[]}, {gold:0, items:[], player_level:0, skill_level:0, card_unlock:[], weapon_unlock:[], gem_unlock:[]}]
	_ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	_ui.commit_victory_rewards()
	fixture_expect("numeric-format tower first clear keeps zero gold and one crown", global.save_data.player.gold == 71 && global.save_data.player.crown_version == global.game_version && global.fixture_grants == 0 && array_length(global.save_data.completed_levels) == 1 && array_length(_ui.victory_resources) == 0)
	with (obj_battle_pause_manager) instance_destroy()
	_ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	_ui.commit_victory_rewards()
	fixture_expect("tower repeat scales gold without duplicating milestones", global.save_data.player.gold == 2071 && ! _ui.first_complete && array_length(global.save_data.completed_levels) == 1 && array_length(_ui.victory_milestones) == 0 && global.fixture_grants == 0)
}

function fixture_report() {
	show_debug_message("FVM_VICTORY_RESULT=" + json_stringify({total:array_length(global.fixture_tests), passed:array_length(global.fixture_tests) - global.fixture_failed, tests:global.fixture_tests}))
}

function fixture_show(_mode) {
	with (obj_battle_pause_manager) instance_destroy()
	var _ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	_ui.first_complete = _mode != 2
	_ui.rewards_committed = true
	global.game_over = true
	global.is_paused = true
	_ui.start_victory_presentation()
	if (_mode == 3) {
		for (var _i = 0; _i < 5; _i++) array_push(_ui.victory_unlocks, _ui.victory_unlocks[_i])
		_ui.victory_pages = 2
	}
}

function fixture_expect(_name, _condition) {
	if (!_condition) global.fixture_failed++
	array_push(global.fixture_tests, {name:_name, passed:_condition})
	show_debug_message("FVM_VICTORY_ASSERT=" + string(_condition) + " " + _name)
}

// Saves remain synthetic for both modes; the same real reward commit code runs.
function coop_is_active() { return global.fixture_coop_active; }
function coop_ui_hit(_x,_y,_w,_h) { return false; }
