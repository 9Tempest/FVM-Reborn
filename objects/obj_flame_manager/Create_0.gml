var _starting_flame = global.level_file.starting_flame
if global.difficulty == 0{
	_starting_flame += 150
}
coop_flame_initialize(_starting_flame);
// 放置植物成功后调用
//global.selected_slot.cooldown_timer = 0;
//global.selected_slot.is_selected = false;

global.auto_collect = true
global.auto_collect_delay = 60
flame_natural_growth_cycle = 12*60
flame_natural_growth_timer = 0

var slot_length =0.5* ds_list_size(global.player_deck)
//show_debug_message("slot_length:"+string(slot_length))