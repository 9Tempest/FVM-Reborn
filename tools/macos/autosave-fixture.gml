// Test-only code: copied into a separate, minimal GameMaker project.
function show_notice(_message, _duration) {
    show_debug_message("AUTOSAVE_NOTICE: " + string(_message));
}
function unlock_card(_id, _level, _shape, _skill) { }
function unlock_weapon(_id) { }

// The copied save/load sources delegate their I/O here. Successful operations
// still use the VM's real filesystem; only explicitly requested failures are
// injected. Production scripts are never edited.
function harness_file_text_open_write(_path) {
    global.harness_write_count++;
    var _handle = file_text_open_write(_path);
    if (_handle >= 0) array_push(global.harness_write_handles, _handle);
    return _handle;
}
function harness_file_text_close(_handle) {
    var _index = array_get_index(global.harness_write_handles, _handle);
    var _writing = (_index >= 0);
    if (_writing) array_delete(global.harness_write_handles, _index, 1);
    var _result = file_text_close(_handle);
    if (_writing && global.harness_fail_close) {
        global.harness_fail_close = false;
        return false;
    }
    return _result;
}
function harness_file_rename(_source, _destination) {
    global.harness_rename_count++;
    if (global.harness_fail_rename_target != "" && filename_name(_destination) == global.harness_fail_rename_target) {
        global.harness_fail_rename_target = "";
        return false;
    }
    return file_rename(_source, _destination);
}
function harness_read(_path) {
    if (!file_exists(_path)) return undefined;
    var _handle = file_text_open_read(_path);
    if (_handle < 0) return undefined;
    var _text = "";
    while (!file_text_eof(_handle)) {
        _text += file_text_read_string(_handle);
        file_text_readln(_handle);
    }
    file_text_close(_handle);
    return _text;
}
function harness_write(_path, _text) {
    var _handle = file_text_open_write(_path);
    file_text_write_string(_handle, _text);
    return file_text_close(_handle);
}
function harness_expect(_name, _condition) {
    array_push(global.harness_results, {name: _name, passed: _condition});
    show_debug_message((_condition ? "PASS " : "FAIL ") + _name);
}
function harness_run() {
    global.harness_results = [];
    global.harness_write_count = 0;
    global.harness_rename_count = 0;
    global.harness_write_handles = [];
    global.harness_fail_close = false;
    global.harness_fail_rename_target = "";
    global.save_slot = 0;
    save_state_init();
    global.player_name = "";
    global.total_time = 0;
    try {
        var _isolated = string_pos("autosave-tests", string_lower(game_save_id)) > 0;
        harness_expect("sandbox is the autosave test application", _isolated);
        if (!_isolated) throw "Refusing filesystem tests outside the dedicated test application.";
        directory_create("saves");
        for (var _slot = 0; _slot <= 4; _slot++) {
            var _base = "saves/save" + string(_slot) + ".json";
            var _suffixes = ["", ".bak", ".pending"];
            for (var _s = 0; _s < array_length(_suffixes); _s++) {
                if (file_exists(_base + _suffixes[_s])) file_delete(_base + _suffixes[_s]);
            }
        }
        harness_expect("create and load empty slot", load_file(0));
        harness_expect("loaded slot is tracked", global.save_ready && global.loaded_save_slot == 0 && global.save_slot == 0);
        global.save_data.player.gold = 1000;
        harness_expect("initial snapshot saves", save_file(0));
        var _before = harness_read("saves/save0.json");
        var _initial = json_parse(_before);
        var _old_level = _initial.unlocked_cards[0].level;

        save_transaction_begin();
        global.save_data.unlocked_cards[0].level = _old_level + 1;
        save_file(0);
        harness_expect("upgrade cannot persist before its price", harness_read("saves/save0.json") == _before);
        global.save_data.player.gold -= 100;
        save_file(0);
        harness_expect("transaction remains deferred until end", harness_read("saves/save0.json") == _before);
        save_transaction_end();
        var _committed = json_parse(harness_read("saves/save0.json"));
        harness_expect("upgrade and price commit together", _committed.player.gold == 900 && _committed.unlocked_cards[0].level == _old_level + 1);

        _before = harness_read("saves/save0.json");
        save_transaction_begin();
        save_transaction_begin();
        global.save_data.player.gold = 850;
        save_file(0);
        save_transaction_end();
        harness_expect("inner transaction cannot commit outer transaction", harness_read("saves/save0.json") == _before);
        save_transaction_end();
        harness_expect("outer transaction commits nested progress", json_parse(harness_read("saves/save0.json")).player.gold == 850);

        global.save_data.player.gold = 950;
        harness_expect("autosave detects direct state mutation", save_autosave_check(false) && json_parse(harness_read("saves/save0.json")).player.gold == 950);
        var _timer_writes = global.harness_write_count;
        global.save_data.player.total_time += 120;
        harness_expect("timer-only change is deferred", save_autosave_check(false) && global.harness_write_count == _timer_writes);
        global.save_last_check_time = current_time - 30001;
        harness_expect("timer checkpoint persists after interval", save_autosave_check(false) && global.harness_write_count > _timer_writes);

        var _writes = global.harness_write_count;
        harness_expect("unchanged save succeeds", save_file(0));
        harness_expect("unchanged save performs no write", global.harness_write_count == _writes);
        harness_expect("wrong slot write rejected", !save_file(1) && !file_exists("saves/save1.json"));
        global.save_slot = 1;
        harness_expect("selected slot cannot bypass loaded slot guard", !save_file(1) && !file_exists("saves/save1.json"));
        global.save_slot = 0;
        harness_expect("out of range slot rejected", !save_file(-1) && !save_file(5));

        _before = harness_read("saves/save0.json");
        global.save_data.player.gold = 800;
        global.harness_fail_close = true;
        var _saved = save_file(0);
        harness_expect("close failure reported", !_saved && !global.harness_fail_close);
        harness_expect("close failure preserves previous primary", harness_read("saves/save0.json") == _before);
        harness_expect("failed save remains retryable", save_file(0));
        harness_expect("retry saves pending progress", json_parse(harness_read("saves/save0.json")).player.gold == 800);

        _before = harness_read("saves/save0.json");
        global.save_data.player.gold = 700;
        global.harness_fail_rename_target = "save0.json";
        _saved = save_file(0);
        harness_expect("primary rename failure reported", !_saved && global.harness_fail_rename_target == "");
        harness_expect("rename failure preserves or restores primary", harness_read("saves/save0.json") == _before);
        harness_expect("rename failure remains retryable", save_file(0));

        var _backup = harness_read("saves/save0.json.bak");
        harness_expect("previous valid snapshot retained", !is_undefined(_backup));
        var _backup_data = json_parse(_backup);
        harness_write("saves/save0.json", "{broken-json");
        harness_expect("corrupted primary recovers backup", load_file(0));
        harness_expect("backup recovery restores saved progress", global.save_data.player.gold == _backup_data.player.gold && global.loaded_save_slot == 0);

        var _current = json_stringify(global.save_data);
        var _current_name = global.player_name;
        var _current_time = global.total_time;
        harness_write("saves/save1.json", "{broken-json");
        harness_write("saves/save1.json.bak", "{also-broken");
        harness_expect("invalid target slot fails to load", !load_file(1));
        harness_expect("load failure preserves selected and loaded slots", global.save_slot == 0 && global.loaded_save_slot == 0 && global.save_ready);
        harness_expect("load failure preserves in-memory progress", json_stringify(global.save_data) == _current && global.player_name == _current_name && global.total_time == _current_time);
        harness_expect("load failure never overwrites target slot", harness_read("saves/save1.json") == "{broken-json");

        harness_expect("fresh second slot loads", load_file(2));
        global.save_data.player.name = "Second Slot";
        global.save_data.player.total_time = 4321;
        global.save_data.player.gold = 222;
        harness_expect("second slot saves independently", save_file(2));
        harness_expect("first slot reloads", load_file(0));
        harness_expect("second slot reloads", load_file(2));
        harness_expect("slot load synchronizes display globals", global.player_name == "Second Slot" && global.total_time == 4321 && global.save_slot == 2 && global.loaded_save_slot == 2);
        harness_expect("slot progress stays separate", global.save_data.player.gold == 222 && json_parse(harness_read("saves/save0.json")).player.gold != 222);

        var _known_good = json_stringify(global.save_data);
        harness_write("saves/save2.json", "{broken-primary");
        harness_write("saves/save2.json.pending", "{broken-pending");
        harness_write("saves/save2.json.bak", "{broken-backup");
        harness_expect("damaged active slot is not silently reset", !load_file(2));
        harness_expect("damaged active slot blocks stale-RAM autosave", !global.save_ready && !save_file(2) && harness_read("saves/save2.json") == "{broken-primary");
        harness_write("saves/save2.json", _known_good);
        harness_expect("valid restored active slot can load again", load_file(2) && global.save_ready);

        var _pending_data = new_save_data();
        _pending_data.player.gold = 333;
        _pending_data.player.name = "Pending Recovery";
        harness_write("saves/save3.json.pending", json_stringify(_pending_data));
        var _older_data = new_save_data();
        _older_data.player.gold = 300;
        harness_write("saves/save3.json.bak", json_stringify(_older_data));
        harness_expect("interrupted commit recovers completed pending file", load_file(3) && global.save_data.player.gold == 333 && global.player_name == "Pending Recovery");
        harness_expect("pending recovery repairs primary", json_parse(harness_read("saves/save3.json")).player.gold == 333);

        _current = json_stringify(global.save_data);
        global.harness_fail_close = true;
        harness_expect("new slot creation reports write failure", !load_file(4) && !global.harness_fail_close);
        harness_expect("new slot write failure preserves active slot", global.save_ready && global.save_slot == 3 && global.loaded_save_slot == 3 && json_stringify(global.save_data) == _current);
    } catch (_error) {
        array_push(global.harness_results, {name: "unhandled test exception", passed: false, detail: string(_error)});
    }
    var _passed = 0;
    for (var _i = 0; _i < array_length(global.harness_results); _i++) {
        if (global.harness_results[_i].passed) _passed++;
    }
    var _report = {passed: _passed, total: array_length(global.harness_results), save_directory: game_save_id, tests: global.harness_results};
    var _json = json_stringify(_report);
    harness_write("autosave-test-results.json", _json);
    show_debug_message("FVM_AUTOSAVE_RESULT=" + _json);
    game_end();
}
