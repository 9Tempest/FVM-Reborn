if (config_key == "save_slot" && global.save_slot != state) {
    if (!save_file(global.save_slot)) {
        show_notice("当前进度尚未保存，暂时无法切换存档。", 180);
        exit;
    }
    if (!load_file(state)) {
        show_notice("目标存档无法读取，已保留当前存档。", 180);
        exit;
    }
    ini_open("config.ini");
    ini_write_real("settings", "save_slot", global.save_slot);
    ini_close();
    audio_play_sound(snd_button, 0, 0);
    global.gui_stack.to(room_menu);
}
