if (!is_placed) {
	if (coop_battle_active()) {
		if (coop_owner != global.coop.player_id || !global.coop.battle_started) exit;
		var _cell = coop_grid_from_world(mouse_x, mouse_y);
		if (_cell.col >= 0 && _cell.row >= 0) global.coop.send_input("place_player", {row:_cell.row, col:_cell.col});
	} else {
		try_place_player(mouse_x, mouse_y);
	}
}
