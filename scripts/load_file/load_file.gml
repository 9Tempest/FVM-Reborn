/// Load only validated data; a failed slot switch keeps the prior slot in memory.
function load_file(file_slot) {
    save_state_init();
    if (!save_slot_valid(file_slot)) return false;
    var _old_data = variable_global_exists("save_data") ? global.save_data : undefined;
    var _old_slot = global.loaded_save_slot;
    var _old_ready = global.save_ready;
    var _old_depth = global.save_transaction_depth;
    var _path = "saves/save" + string(file_slot) + ".json";
    var _candidate = save_read_candidate(_path);
    var _recovered = false;
    if (!_candidate.ok) {
        // A completed pending write can survive interruption between the renames.
        _candidate = save_read_candidate(_path + ".pending");
        if (!_candidate.ok) _candidate = save_read_candidate(_path + ".bak");
        _recovered = _candidate.ok;
    }
    var _new = !file_exists(_path) && !file_exists(_path + ".pending") && !file_exists(_path + ".bak");
    if (!_candidate.ok && !_new) {
        // A damaged current slot must not be overwritten by stale RAM after import.
        if (file_slot == _old_slot) global.save_ready = false;
        show_debug_message("存档加载失败，文件与当前存档槽均已保留: " + _path);
        return false;
    }
    global.save_loading = true;
    global.save_transaction_depth++;
    global.save_data = _new ? new_save_data() : _candidate.data;
    try {
		if global.save_data.version == 1.0 || global.save_data.version == "1.1"|| global.save_data.version == "1.2"|| global.save_data.version == "1.3"{
			global.save_data = new_save_data()
		}
		else{
			if global.save_data.version == "1.4"{
				if array_get_index(global.save_data.completed_levels,"cocoa_island_night") != -1{
					unlock_weapon("double_water_gun")
				}
				if array_get_index(global.save_data.completed_levels,"abyss") != -1{
					unlock_card("chocolate_pult",0,0,5)
				}
				global.save_data.version = 1.5
			}
			if global.save_data.version == 1.5{
				global.save_data.attires = []
				global.save_data.version = 1.6
			}
			if global.save_data.version == 1.6{
				global.save_data.player.crown_version = "0.0.0"
				global.save_data.version = 1.7
			}
			if global.save_data.version == 1.7{
				global.save_data.equipped_cookbook = [[],[],[]]
				global.save_data.version = 1.8
			}
		}
        if (!save_data_valid(global.save_data)) throw "invalid migrated save";
    } catch (_error) {
        global.save_data = _old_data;
        global.save_ready = _old_ready && file_slot != _old_slot;
        global.save_loading = false;
        global.save_transaction_depth = _old_depth;
        show_debug_message("存档迁移失败: " + string(_error));
        return false;
    }
    global.save_loading = false;
    global.save_transaction_depth = _old_depth;
    global.save_slot = file_slot;
    global.loaded_save_slot = file_slot;
    global.save_ready = true;
    global.player_name = global.save_data.player.name;
    global.total_time = global.save_data.player.total_time;
    global.save_last_json = _recovered || _new ? "" : _candidate.text;
    global.save_last_progress = save_progress_json();
    global.save_last_check_time = current_time;
    if (_recovered || _new || json_stringify(global.save_data) != global.save_last_json) save_file(file_slot);
    show_debug_message("存档加载成功! slot=" + string(file_slot));
    return true;
}

/// Explicit new/reset operation, never used to replace a damaged save implicitly.
function reset_file(file_slot) {
    save_state_init();
    if (!save_slot_valid(file_slot)) return false;
    global.save_data = new_save_data();
    global.save_slot = file_slot;
    global.loaded_save_slot = file_slot;
    global.save_ready = true;
    global.player_name = global.save_data.player.name;
    global.total_time = global.save_data.player.total_time;
    global.save_last_json = "";
    return save_file(file_slot);
}

function new_save_data() {
    return {
            "version": 1.8,
            "player": {
                "gold": 0,
                "level": 1,
                "experience": 0,
				"name":"Player",
				"total_time":0,
				"crown_version":"0.0.0"
            },
            "unlocked_cards": [
                {"id": "small_fire", "level": 0, "shape": 0,"skill":0,"max_level":0,"max_shape":0},
				{"id": "toast_bread", "level": 0, "shape": 0,"skill":0,"max_level":0,"max_shape":0},
				{"id": "xiao_long_bao", "level": 0, "shape": 0,"skill":0,"max_level":0,"max_shape":0},
				{"id": "flour_sack", "level": 0, "shape": 0,"skill":0,"max_level":0,"max_shape":0}
            ],
            "completed_levels": [],
            "inventory": [],
            "unlocked_items": {
                "max_card_level": 0,
                "max_skill_level": 0,
                "max_gem_level": 0,
				"max_slot":5,
				"max_shape":[],
				"shovel":"normal",
				"elite_unlocked":false,
				"mario_mouse_killed":false,
				"arno_killed":false
            },
            "unlocked_weapons": [
                {"id": "long_bao_gun"}
            ],
			"unlocked_gems":[],
			"equipped_items":{
				"main_weapon":{
					"id":"long_bao_gun",
					"gems":[]
				},
				"secondary_weapon":{
					"id":"",
					"gems":[]
				},
				"super_weapon":{
					"id":"",
					"gems":[]
				}
			},
			"saved_decks":[
				{"name":"卡组1","card_id":[]},
				{"name":"卡组2","card_id":[]},
				{"name":"卡组3","card_id":[]},
				{"name":"卡组4","card_id":[]},
				{"name":"卡组5","card_id":[]},
				{"name":"卡组6","card_id":[]} 
			],
			"tasks":[
				{
					"id":"main_level_0",
					"progress":[0],
					"state":"new"
				},
				{
					"id":"card_upgrade_1",
					"progress":[0],
					"state":"new"
				},
				{
					"id":"flame_save_1",
					"progress":[0,0],
					"state":"new"
				},
				{
					"id":"perfect_challenge_1",
					"progress":[0,0,0],
					"state":"new"
				},
				{
					"id":"hardcore_challenge_1",
					"progress":[0,0,0],
					"state":"new"
				}
			],
			"completed_tasks":[],
			"attires":[],
			"equipped_cookbook":[[],[],[]]
        };
}