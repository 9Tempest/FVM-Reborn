// All progress is synthetic and in memory. Any save call is counted, never written.
function save_file(_slot) { global.fixture_saves++; return true }
function save_transaction_begin() { }
function save_transaction_end() { }
function show_notice(_text, _frames) { }
function complete_level(_id) { array_push(global.save_data.completed_levels, _id) }
function add_material_amount(_id, _amount) { global.fixture_materials += _amount }
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
	global.difficulty = "普通"
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
	var _task = instance_create_depth(0, 0, 0, obj_task_manager)
	_task.card_loss = 3
	_task.cat_loss = 0
	_task.refresh_task_progress = function() { }
	instance_create_depth(0, 0, -3001, obj_game_over).sprite_index = spr_win
	instance_create_depth(0, 0, 0, obj_world_map_button)
	global.game_over = true
	var _ui = instance_create_depth(0, 0, -3000, obj_battle_pause_manager)
	global.is_paused = true
	_ui.commit_victory_rewards()
	_ui.commit_victory_rewards()
	fixture_expect("win commits once", global.save_data.player.gold == 1000 && global.fixture_saves == 1)
	fixture_expect("all unlocks and materials committed", global.fixture_grants == 6 && global.fixture_materials == 20)
	fixture_expect("first clear and presentation flags", _ui.rewards_committed && _ui.victory_started && _ui.first_complete)
	fixture_expect("real card art collected", array_length(_ui.victory_unlocks) == 6 && _ui.victory_unlocks[0].sprite == spr_double_long_bao)
	global.fixture_saves = 0
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
	show_debug_message("FVM_VICTORY_ASSERT=" + string(_condition) + " " + _name)
}
