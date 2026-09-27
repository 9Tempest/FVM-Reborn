if global.is_paused{
	exit
}

event_inherited(); 
var current_flash_speed = flash_speed
if is_slowdown{
	current_flash_speed *= 2
}

attack_timer++

var _ice_owner = variable_instance_exists(id,"coop_owner") ? coop_owner : "";
if attack_timer == 1{
	if shape <= 1{
		with obj_card_parent{
			if plant_id != "player"{
				if(other.shape == 0 && grid_row == other.grid_row && grid_col == other.grid_col)
				||(other.shape == 1 && grid_row >= other.grid_row-1 && grid_row <= other.grid_row+1 && grid_col >= other.grid_col-1 && grid_col <= other.grid_col+1)
				{
					if array_get_index(other.ignore_list,plant_id) == -1{
						with obj_card_slot{
							if card_id == other.plant_id && (!coop_personal_loadouts() || coop_owner == _ice_owner){
								cooldown_timer = cooldown
							}
						}
					}
				}
			}
		}
	}
	else{
		with obj_card_slot{
			if array_get_index(other.ignore_list,card_id) == -1 && (!coop_personal_loadouts() || coop_owner == _ice_owner){
				cooldown_timer = cooldown
			}
		}
	}
}
if attack_timer > current_flash_speed * idle_anim-1{
	instance_destroy()
}