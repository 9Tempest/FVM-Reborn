#macro room_coop room_autosave_tests
function coop_get(_value,_key,_fallback=undefined) {
    return is_struct(_value) && variable_struct_exists(_value,_key) ? variable_struct_get(_value,_key) : _fallback;
}
function audio_expect(_name,_passed) { array_push(global.audio_tests,{name:_name,passed:_passed}); }
function audio_run() {
    global.audio_tests=[]; global.game_over=false; global.is_paused=false; global.lose_focus_pause=false;
    var _state={music:"mus_fixture_pre",playing:true,paused:false,result:"",result_paused:false};
    coop_audio_apply(_state,"first",false);
    var _a=coop_audio_state(),_first=_a.music_handle;
    audio_expect("guest starts the requested music",_first!=-1 && audio_is_playing(_first));
    coop_audio_apply(_state,"first",false);
    audio_expect("repeated snapshots retain the same sound instance",_a.music_handle==_first);
    _state.paused=true; coop_audio_apply(_state,"first",false);
    audio_expect("host pause pauses the existing instance",audio_is_paused(_first));
    _state.paused=false; coop_audio_apply(_state,"first",false);
    audio_expect("host resume preserves the existing instance",_a.music_handle==_first && !audio_is_paused(_first));
    coop_audio_apply(_state,"first",true);
    audio_expect("disconnect or local focus pause pauses audio",audio_is_paused(_first));
    coop_audio_apply(_state,"first",false);
    audio_expect("reconnection resumes audio",!audio_is_paused(_first));
    _state.music="mus_fixture_elite"; coop_audio_apply(_state,"first",false);
    audio_expect("elite transition stops old track and starts new track",!audio_is_playing(_first) && _a.music_handle!=-1 && audio_is_playing(_a.music_handle));
    _state.playing=false; coop_audio_apply(_state,"first",false);
    audio_expect("host stop leaves no guest music",_a.music_handle==-1);
    _state.music="obj_battle_music_controller"; _state.playing=true; coop_audio_apply(_state,"first",false);
    audio_expect("non-sound assets cannot play",_a.music_handle==-1);
    _state.music="missing_music"; coop_audio_apply(_state,"first",false);
    audio_expect("unknown asset names are harmless",_a.music_handle==-1);
    _state.music="mus_fixture_pre"; _state.result="snd_win"; coop_audio_apply(_state,"first",false);
    var _result=_a.result_handle;
    audio_expect("victory cue starts once",_result!=-1 && audio_is_playing(_result));
    coop_audio_apply(_state,"first",false);
    audio_expect("repeated result snapshot never duplicates the fanfare",_a.result_handle==_result);
    audio_stop_sound(_result); coop_audio_apply(_state,"first",false);
    audio_expect("completed fanfare does not restart",_a.result_handle==_result && !audio_is_playing(_result));
    _state.result="snd_lose"; coop_audio_apply(_state,"second",false);
    audio_expect("a new match can play its defeat cue",_a.match_id=="second" && _a.result=="snd_lose" && audio_is_playing(_a.result_handle));
    _state.result_paused=true; coop_audio_apply(_state,"second",false);
    audio_expect("host result cue pause is mirrored",audio_is_paused(_a.result_handle));
    _state.result=""; coop_audio_apply(_state,"second",false);
    audio_expect("host result stop is mirrored",_a.result_handle==-1);
    global.coop={active:true,role:"guest",battle_started:true,latest:{audio:_state},match_id:"second",all_connected:function(){return true;}};
    audio_expect("guest battle suppresses menu music",coop_audio_guest_active());
    coop_audio_tick();
    global.coop.battle_started=false; coop_audio_tick();
    audio_expect("return to lobby releases all guest sound instances",_a.music_handle==-1 && _a.result_handle==-1 && !coop_audio_guest_active());
    global.coop.battle_started=true; coop_audio_tick(); global.coop.active=false; coop_audio_tick();
    audio_expect("leaving co-op releases sound instances",_a.music_handle==-1);
    var _controller=instance_create_depth(0,0,0,obj_battle_music_controller);
    _controller.battle_music=mus_fixture_elite;
    var _host=audio_play_sound(mus_fixture_elite,0,true);
    var _snapshot=coop_audio_snapshot();
    audio_expect("host serializes current track by asset name",_snapshot.music=="mus_fixture_elite" && _snapshot.playing && !_snapshot.paused);
    global.is_paused=true; _snapshot=coop_audio_snapshot();
    audio_expect("host pause is represented before the audio controller ticks",_snapshot.paused);
    global.game_over=true; var _host_result=audio_play_sound(snd_win,0,false);
    _snapshot=coop_audio_snapshot();
    audio_expect("host mirrors the existing victory sound",_snapshot.result=="snd_win");
    audio_stop_sound(_host_result); audio_stop_sound(_host); coop_audio_stop();
    var _passed=0; for(var _i=0;_i<array_length(global.audio_tests);_i++) if(global.audio_tests[_i].passed) _passed++;
    show_debug_message("FVM_AUTOSAVE_RESULT="+json_stringify({passed:_passed,total:array_length(global.audio_tests),tests:global.audio_tests}));
    game_end();
}
