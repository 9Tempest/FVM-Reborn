/// Only long-running battle music and the existing result cue are mirrored.
/// Sound instances retain their normal music/sound audio-group volume settings.
function coop_audio_snapshot() {
    var _audio = {music:"", playing:false, paused:false, result:"", result_paused:false};
    if (instance_exists(obj_battle_music_controller)) {
        var _sound = obj_battle_music_controller.battle_music;
        if (asset_get_type(_sound) == asset_sound) {
            _audio.music = audio_get_name(_sound);
            _audio.playing = audio_is_playing(_sound);
            _audio.paused = global.is_paused || audio_is_paused(_sound);
        }
    }
    if (global.game_over) {
        var _result = audio_is_playing(snd_win) ? snd_win : (audio_is_playing(snd_lose) ? snd_lose : -1);
        if (_result != -1) {
            _audio.result = audio_get_name(_result);
            _audio.result_paused = audio_is_paused(_result);
        }
    }
    return _audio;
}

function coop_audio_state() {
    if (!variable_global_exists("coop_audio")) {
        global.coop_audio = {match_id:"", music:"", music_handle:-1, result:"", result_handle:-1};
    }
    return global.coop_audio;
}

function coop_audio_stop() {
    var _audio = coop_audio_state();
    if (_audio.music_handle != -1) audio_stop_sound(_audio.music_handle);
    if (_audio.result_handle != -1) audio_stop_sound(_audio.result_handle);
    _audio.match_id=""; _audio.music=""; _audio.music_handle=-1;
    _audio.result=""; _audio.result_handle=-1;
}

function coop_audio_pause(_handle, _paused) {
    if (_handle == -1 || !audio_is_playing(_handle)) return;
    if (_paused && !audio_is_paused(_handle)) audio_pause_sound(_handle);
    else if (!_paused && audio_is_paused(_handle)) audio_resume_sound(_handle);
}

function coop_audio_apply(_snapshot, _match_id, _local_pause) {
    var _audio = coop_audio_state();
    if (_audio.match_id != _match_id) { coop_audio_stop(); _audio.match_id=_match_id; }
    var _name=coop_get(_snapshot,"music","");
    if (!is_string(_name) || string_copy(_name,1,4)!="mus_" || asset_get_type(_name)!=asset_sound) _name="";
    if (_audio.music != _name) {
        if (_audio.music_handle != -1) audio_stop_sound(_audio.music_handle);
        _audio.music=_name; _audio.music_handle=-1;
    }
    if (_name=="" || !coop_get(_snapshot,"playing",false)) {
        if (_audio.music_handle != -1) audio_stop_sound(_audio.music_handle);
        _audio.music_handle=-1;
    } else {
        if (_audio.music_handle==-1 || !audio_is_playing(_audio.music_handle)) {
            _audio.music_handle=audio_play_sound(asset_get_index(_name),0,true);
        }
        coop_audio_pause(_audio.music_handle,_local_pause || coop_get(_snapshot,"paused",false));
    }
    // Result snapshots repeat at 10 Hz. Play the existing cue once per match,
    // including after its natural end; a reconnect must not repeatedly award a fanfare.
    var _result=coop_get(_snapshot,"result","");
    if (_result!="snd_win" && _result!="snd_lose") _result="";
    if (_result!="" && _audio.result=="" && asset_get_type(_result)==asset_sound) {
        _audio.result=_result;
        _audio.result_handle=audio_play_sound(asset_get_index(_result),0,false);
    }
    if (_result=="" && _audio.result_handle!=-1) {
        audio_stop_sound(_audio.result_handle); _audio.result_handle=-1;
    }
    coop_audio_pause(_audio.result_handle,_local_pause || coop_get(_snapshot,"result_paused",false));
}

function coop_audio_guest_active() {
    if (!variable_global_exists("coop")) return false;
    var _c=global.coop;
    return room==room_coop && _c.active && _c.role=="guest" && _c.battle_started && is_struct(_c.latest);
}

function coop_audio_tick() {
    if (!coop_audio_guest_active()) {
        coop_audio_stop(); return;
    }
    var _c=global.coop;
    var _local_pause=!_c.all_connected();
    if (variable_global_exists("lose_focus_pause") && global.lose_focus_pause && !window_has_focus()) _local_pause=true;
    coop_audio_apply(coop_get(_c.latest,"audio",{}),_c.match_id,_local_pause);
}
