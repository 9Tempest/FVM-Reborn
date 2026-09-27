audio_play_sound(snd_button,0,0)
if btn_type == "cancel"{
	instance_destroy(obj_edit_menu)
	obj_player_info_ui.menu_type = 0
}
else if btn_type == "save"{
	with obj_edit_menu{
		event_user(0)
	}
	global.save_data.player.name = global.player_name
	save_file(global.save_slot)
	instance_destroy(obj_edit_menu)
	obj_player_info_ui.menu_type = 0
}
else if btn_type == "open_save_folder"{
	var _target = global.native_util.get_path_in_local_appdata("\\FVM_Reborn\\saves")
	var ret = native_open_folder(_target)
	if (ret != 0) {
		global.native_util.show_error(ret, "打开存档文件夹失败")
	}
}
else if btn_type == "export_save_backup" {
	if (!save_file(global.save_slot)) {
		show_message_async("当前存档保存失败，未导出备份")
		exit
	}
	var _saves_target = global.native_util.get_path_in_local_appdata("\\FVM_Reborn\\saves")
	var ret = native_start_backup(_saves_target)
	if (ret == -3) exit
	if (ret != 0) {
		global.native_util.show_error(ret, "导出存档备份失败")
		exit
	}
	show_message_async("存档已导出")
}
else if btn_type == "import_save_backup" {
	if (!save_file(global.save_slot)) {
		show_message_async("当前存档保存失败，未执行导入")
		exit
	}
	var _saves_target = global.native_util.get_path_in_local_appdata("\\FVM_Reborn\\saves")
	var _backup_target = global.native_util.get_path_in_local_appdata("\\FVM_Reborn\\backups")
	var _now = date_current_datetime()
	var _stamp = string(date_get_year(_now)) + "-" + string(date_get_month(_now))
		+ "-" + string(date_get_day(_now)) + "-" + string(date_get_hour(_now))
		+ "-" + string(date_get_minute(_now)) + "-" + string(date_get_second(_now))
		+ "-" + string(current_time)
	var _snapshot = global.native_util.to_native_absolute("backups/before-import-" + _stamp + ".json")
	var _snapshot_result = native_start_backup_with_target_file(_saves_target, _snapshot)
	if (_snapshot_result != 0) {
		global.native_util.show_error(_snapshot_result, "导入前备份失败，未执行导入")
		exit
	}
	var ret = native_restore_backup(_saves_target, _backup_target)
	if (ret == -3) exit
	if (ret != 0) {
		global.native_util.show_error(ret, "导入存档备份失败")
		exit
	}
	if (!load_file(global.save_slot)) {
		show_message_async("导入文件无法加载，未重置存档。导入前备份保存在：\n" + _snapshot)
		exit
	}
	show_message_async("导入存档成功")
}
