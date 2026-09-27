/// Save state is bound to the slot that was actually loaded successfully.
function save_state_init() {
    if (variable_global_exists("save_ready")) return;
    global.save_ready = false;
    global.loaded_save_slot = -1;
    global.save_loading = false;
    global.save_transaction_depth = 0;
    global.save_last_json = "";
    global.save_last_progress = "";
    global.save_last_check_time = current_time;
    global.save_error_time = -60000;
}

function save_slot_valid(_slot) {
    return is_real(_slot) && _slot == floor(_slot) && _slot >= 0 && _slot <= 4;
}

function save_data_valid(_data) {
    return is_struct(_data)
        && variable_struct_exists(_data, "version")
        && variable_struct_exists(_data, "player") && is_struct(_data.player)
        && variable_struct_exists(_data.player, "name") && is_string(_data.player.name)
        && variable_struct_exists(_data.player, "level") && is_real(_data.player.level)
        && variable_struct_exists(_data.player, "gold") && is_real(_data.player.gold)
        && variable_struct_exists(_data.player, "total_time") && is_real(_data.player.total_time)
        && variable_struct_exists(_data, "unlocked_cards") && is_array(_data.unlocked_cards)
        && variable_struct_exists(_data, "completed_levels") && is_array(_data.completed_levels)
        && variable_struct_exists(_data, "inventory") && is_array(_data.inventory)
        && variable_struct_exists(_data, "unlocked_items") && is_struct(_data.unlocked_items);
}

function save_read_candidate(_path) {
    var _result = {ok:false, text:"", data:undefined};
    if (!file_exists(_path)) return _result;
    var _file = file_text_open_read(_path);
    if (_file < 0) return _result;
    var _text = "";
    while (!file_text_eof(_file)) {
        _text += file_text_read_string(_file);
        file_text_readln(_file);
    }
    // The native VM reports false when a read handle has reached EOF.
    // Validate the complete JSON below; write handles are still checked on close.
    file_text_close(_file);
    try {
        var _data = json_parse(_text);
        if (save_data_valid(_data)) return {ok:true, text:_text, data:_data};
    } catch (_error) {
        show_debug_message("Invalid save candidate: " + _path);
    }
    return _result;
}

/// Exclude the continuously incremented play timer from the two-second check.
function save_progress_json() {
    var _copy = json_parse(json_stringify(global.save_data));
    _copy.player.total_time = 0;
    return json_stringify(_copy);
}

function save_report_error(_detail) {
    show_debug_message("Save failed: " + _detail);
    if (current_time - global.save_error_time >= 10000) {
        global.save_error_time = current_time;
        show_notice("自动存档失败，旧存档已保留。请检查磁盘空间或写入权限。", 180);
    }
    return false;
}

/// Nested business operations may request saves, but only the outer commit writes.
function save_transaction_begin() {
    save_state_init();
    global.save_transaction_depth++;
}

function save_transaction_end() {
    save_state_init();
    if (global.save_transaction_depth <= 0) return false;
    global.save_transaction_depth--;
    if (global.save_transaction_depth == 0) return save_file(global.save_slot);
    return true;
}

/// Recoverable replace: complete and verify a pending file before rotating the old one.
function save_file(file_slot) {
    save_state_init();
    if (global.save_loading || global.save_transaction_depth > 0) return true;
    if (!global.save_ready || !save_slot_valid(file_slot)
        || file_slot != global.loaded_save_slot || file_slot != global.save_slot) return false;
    if (!save_data_valid(global.save_data)) return save_report_error("invalid in-memory save");

    var _json = json_stringify(global.save_data);
    var _path = "saves/save" + string(file_slot) + ".json";
    var _pending = _path + ".pending";
    var _backup = _path + ".bak";
    if (_json == global.save_last_json && file_exists(_path)) {
        global.save_last_check_time = current_time;
        return true;
    }
    if (!directory_exists("saves")) directory_create("saves");
    var _file = file_text_open_write(_pending);
    if (_file < 0) return save_report_error("cannot open pending save");
    file_text_write_string(_file, _json);
    if (!file_text_close(_file)) return save_report_error("cannot flush pending save");
    var _verified = save_read_candidate(_pending);
    if (!_verified.ok || _verified.text != _json) return save_report_error("pending save verification failed");

    if (file_exists(_path)) {
        var _previous = save_read_candidate(_path);
        if (_previous.ok) {
            if (file_exists(_backup) && !file_delete(_backup)) return save_report_error("cannot rotate backup");
            if (!file_rename(_path, _backup)) return save_report_error("cannot preserve previous save");
        } else {
            // Preserve damaged files for diagnosis instead of overwriting a good backup.
            var _damaged = _path + ".corrupt-" + string(current_time);
            while (file_exists(_damaged)) _damaged += "-1";
            if (!file_rename(_path, _damaged)) return save_report_error("cannot preserve damaged save");
        }
    }
    if (!file_rename(_pending, _path)) {
        if (!file_exists(_path) && file_exists(_backup)) file_copy(_backup, _path);
        return save_report_error("cannot commit pending save");
    }
    var _committed = save_read_candidate(_path);
    if (!_committed.ok || _committed.text != _json) return save_report_error("committed save verification failed");
    global.save_last_json = _json;
    global.save_last_progress = save_progress_json();
    global.save_last_check_time = current_time;
    show_debug_message("存档保存成功! slot=" + string(file_slot));
    return true;
}

function save_autosave_check(_force = false) {
    save_state_init();
    if (!global.save_ready || global.save_loading || global.save_transaction_depth > 0) return false;
    if (_force || save_progress_json() != global.save_last_progress
        || current_time - global.save_last_check_time >= 30000) {
        return save_file(global.save_slot);
    }
    return true;
}
