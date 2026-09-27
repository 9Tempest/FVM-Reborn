if global.is_paused{
	exit
}
if global.debug && !coop_battle_active(){
	cooldown_timer = 0
}
if cooldown_timer>0 cooldown_timer--