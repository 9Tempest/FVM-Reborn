// Real CoopSession and CoopTransport in an isolated native VM and real server.
// Only save validation / UI / simulation are stubbed; no production saves used.
#macro room_coop room_transport_test
#macro room_menu room_transport_test
#macro spr_lose -1
function save_file(_slot) { global.fixture_solo_saves++; return true; }
function save_data_valid(_p) { return is_struct(_p) && is_struct(coop_get(_p,"player")) && is_real(coop_get(_p,"coins")); }
function save_progress_json() { return json_stringify(global.save_data); }
function coop_battle_ready() { global.fixture_ready++; }
function coop_battle_tick() { global.fixture_ticks++; }
function coop_battle_command(_p) { global.fixture_commands++; }
function fixture_profile(_coins) { return {coins:_coins,player:{name:"会话测试",total_time:0}}; }
function fixture_globals(_coins) {
    global.save_data=fixture_profile(_coins); global.save_slot=3;
    global.player_name="会话测试"; global.total_time=0;
    global.save_last_json=json_stringify(global.save_data); global.save_last_progress=global.save_last_json;
    global.save_ready=true; global.loaded_save_slot=3; global.save_last_check_time=0;
    global.gui_stack={to:function(_room) { global.fixture_navigation++; }};
    global.game_version="session-test"; global.game_over=false;
}
function fixture_expect(_name,_ok) {
    array_push(global.fixture_tests,{name:_name,passed:_ok});
    show_debug_message((_ok?"PASS ":"FAIL ")+_name);
}
function fixture_fake_transport() {
    return {send:function(_p) { array_push(global.fixture_sent,coop_clone(_p)); return true; },
        close:function() {},connect:function(_url) { return true; },tick:function() { return undefined; }};
}
function fixture_unit_session() {
    var _s=new CoopSession(); _s.transport=fixture_fake_transport();
    _s.role="host";_s.player_id="host-test";_s.room_id="room-test";_s.resume_token="resume-test";
    _s.url=@SERVER_URL@;_s.public_url=_s.url;_s.active=true;_s.connected=true;
    _s.players=[{player_id:"host-test",last_seq:0,connected:true,profile:fixture_profile(100)},
        {player_id:"guest-test",last_seq:0,connected:true,profile:fixture_profile(100)}];
    _s.campaign_json=json_stringify(global.save_data);
    return _s;
}
function fixture_units() {
    fixture_globals(100);
    var _s=fixture_unit_session();
    fixture_expect("methods bind to the session struct",_s.request("ping").request_id==_s.request_prefix+"-1");
    fixture_expect("solo snapshot stores the original slot",_s.preserve_solo() && _s.solo.slot==3 && _s.solo.data.coins==100);
    global.save_data.coins=120; global.fixture_write_fail=true; var _before=array_length(global.fixture_sent);
    fixture_expect("campaign disk failure returns false",!_s.save_campaign());
    fixture_expect("campaign disk failure cannot send before persistence",array_length(global.fixture_sent)==_before && !_s.outbox_durable && is_struct(_s.campaign_request));
    fixture_expect("retries also honor the disk failure",!_s.flush_outbox() && array_length(global.fixture_sent)==_before);
    global.fixture_write_fail=false;
    fixture_expect("campaign retry persists before sending",_s.flush_outbox() && _s.outbox_durable && array_length(global.fixture_sent)==_before+1);
    var _saved=coop_read_json("coop/session.json");
    fixture_expect("exact campaign request survives native disk roundtrip",_saved.campaign_request.request_id==_s.campaign_request.request_id && variable_struct_get(_saved.campaign_request.profiles,"host-test").coins==120);
    fixture_expect("starting a match never discards an unacknowledged campaign",!_s.start_battle("test-level") && is_struct(_s.campaign_request));
    global.save_data.coins=130;
    _s.packet({type:"campaign_saved",request_id:_s.campaign_request.request_id});
    fixture_expect("campaign ACK preserves newer RAM changes",global.save_data.coins==130 && json_parse(_s.campaign_json).coins==120);
    fixture_expect("next autosave captures changes after the pending revision",_s.save_campaign() && variable_struct_get(_s.campaign_request.profiles,"host-test").coins==130);
    _s.packet({type:"campaign_saved",request_id:_s.campaign_request.request_id});
    _s.match_id="match-unit";_s.room_status="running";global.save_data.coins=180;
    global.fixture_write_fail=true;_before=array_length(global.fixture_sent);
    fixture_expect("result disk failure cannot send a reward commit",!_s.submit_result("victory") && array_length(global.fixture_sent)==_before && is_struct(_s.result_request));
    global.fixture_write_fail=false;
    fixture_expect("exact result is durable before retry",_s.submit_result("victory") && _s.outbox_durable);
    var _outbox=coop_read_json("coop/session.json");
    fixture_globals(100);
    var _restored=new CoopSession();_restored.transport=fixture_fake_transport();
    fixture_expect("a new native session can resume the stored result",_restored.resume() && is_struct(_restored.result_request));
    var _state={players:_s.players,room_status:"running",match_id:"match-unit",checkpoint:undefined,pending_commands:[]};
    _restored.packet({type:"resumed",role:"host",room_id:"room-test",player_id:"host-test",state:_state});
    fixture_expect("restart restores reward outbox instead of old server profile",global.save_data.coins==180 && _restored.result_request.request_id==_outbox.result_request.request_id);
    global.save_data.coins=190;
    _restored.packet({type:"match_result_ack",match_id:"match-unit",committed:true,profiles:{"host-test":{profile:fixture_profile(180),revision:3}}});
    fixture_expect("result ACK records only committed progress",global.save_data.coins==190 && json_parse(_restored.campaign_json).coins==180 && _restored.result_saved && !is_struct(_restored.result_request));
    _restored.save_campaign();
    fixture_expect("post-result changes become another durable campaign",variable_struct_get(_restored.campaign_request.profiles,"host-test").coins==190);
    // Restore a campaign request after a second process restart.
    fixture_globals(100);
    var _campaign=new CoopSession();_campaign.transport=fixture_fake_transport();_campaign.resume();
    _state.room_status="finished";
    _campaign.packet({type:"resumed",role:"host",room_id:"room-test",player_id:"host-test",state:_state});
    fixture_expect("restart restores unacknowledged campaign rather than old server data",global.save_data.coins==190 && is_struct(_campaign.campaign_request));
    _campaign.packet({type:"campaign_saved",request_id:_campaign.campaign_request.request_id});
    fixture_expect("ACK after restart does not schedule a rollback",_campaign.save_campaign() && !is_struct(_campaign.campaign_request));
    _campaign.update_state({players:_campaign.players,room_status:"lobby",match_id:undefined});
    fixture_expect("JSON null match clears the previous match identifier",_campaign.match_id=="");
    _campaign.packet({type:"error",code:"resume_invalid",message:"test"});
    fixture_expect("invalid resume credentials stop automatic retry",_campaign.leaving && !_campaign.connected && _campaign.retry_at==0);
    _campaign.active=false;_campaign.saved_session={resume_token:"malformed"};
    fixture_expect("malformed cached credentials are rejected safely",!_campaign.resume());
    _s.campaign_request=undefined;_s.result_request=undefined;_s.room_status="finished";_s.campaign_json=json_stringify(global.save_data);
    fixture_expect("leaving restores isolated solo state",_s.leave() && global.save_data.coins==100 && global.save_slot==3 && global.loaded_save_slot==3);
    _s.reset_entry();
    fixture_expect("new room state drops old room and result identifiers",_s.match_id=="" && _s.room_id=="" && _s.resume_token=="" && array_length(_s.inputs_pending)==0);
    // Actual guest state handling uses server response shapes, including JSON null.
    fixture_globals(100);
    var _guest=fixture_unit_session();_guest.role="guest";_guest.player_id="guest-test";
    var _guest_state={players:_guest.players,room_status:"running",match_id:"guest-match",checkpoint:{state:{flame:42}},pending_commands:[]};
    _guest.update_state(_guest_state,true);
    fixture_expect("guest resume restores running input state and checkpoint",_guest.battle_started && _guest.match_id=="guest-match" && _guest.latest.flame==42);
    fixture_expect("resumed guest can submit its next authoritative input",_guest.send_input("place_player",{row:1,col:1}) && _guest.inputs_pending[0].seq==1);
    _guest.packet({type:"campaign_updated",profiles:{"guest-test":{profile:fixture_profile(210),revision:9}}});
    fixture_expect("guest receives campaign upgrades before the next battle",global.save_data.coins==210);
    _guest_state.room_status="finished";_guest_state.result={outcome:"victory"};_guest.update_state(_guest_state);
    fixture_expect("guest resume restores completed result state",_guest.result_saved && _guest.result_outcome=="victory" && !_guest.battle_started);
    _guest.active=false;_guest.saved_session={url:@SERVER_URL@,public_url:@SERVER_URL@,role:"guest",room_id:"room-test",player_id:"guest-test",resume_token:"guest-private"};
    var _address="FVM1:"+base64_encode(json_stringify({url:"wss://new-address.example/game",room_id:"room-test",invite_token:""}));
    fixture_expect("returning guest uses its private resume token with updated public address",_guest.join(_address) && _guest.entry=="resume" && _guest.url=="wss://new-address.example/game" && _guest.resume_token=="guest-private");
    var _stranger=new CoopSession();_stranger.transport=fixture_fake_transport();_stranger.saved_session=undefined;
    fixture_expect("address-only code cannot admit a new guest",!_stranger.join(_address));
    var _host=fixture_unit_session();coop_write_json("coop/host.json",{public_url:"wss://new-address.example/game"});
    var _copied=_host.copy_invite();var _decoded=json_parse(base64_decode(string_delete(_copied,1,5)));
    fixture_expect("host address code refreshes tunnel without exposing resume credential",_decoded.url=="wss://new-address.example/game" && _decoded.invite_token=="" && !variable_struct_exists(_decoded,"resume_token"));
    fixture_expect("copy method uses the current invitation",global.fixture_clipboard==_copied);
    // A live battle instance distinguishes lost start ACK from process restart.
    var _instance=instance_create_depth(0,0,0,obj_battle);
    _host.active=false;_host.match_id="lost-ack";_host.battle_started=false;
    _guest_state.match_id="lost-ack";_guest_state.room_status="running";
    _host.packet({type:"resumed",role:"host",room_id:"room-test",player_id:"host-test",state:_guest_state});
    fixture_expect("lost start ACK resumes the existing simulation instead of committing defeat",_host.battle_started && global.fixture_ready>0 && !is_struct(_host.result_request));
    _host.battle_started=false;global.coop_battle={start_requested:true};var _ticks=global.fixture_ticks;_host.tick();
    fixture_expect("bridge tick runs while the start ACK is pending",global.fixture_ticks==_ticks+1);
    _host.start_request_id="start-retry";
    _host.packet({type:"error",request_id:"start-retry",code:"players_not_ready",message:"retry"});
    fixture_expect("rejected start request releases bridge retry gate",!global.coop_battle.start_requested);
    instance_destroy(_instance);
    // Clear only this unique test app's credentials before the live protocol test.
    for(var _i=0;_i<3;_i++) {var _path=["coop/session.json","coop/session.json.pending","coop/session.json.bak"][_i];if(file_exists(_path))file_delete(_path);}
}
function fixture_finish() {
    if(global.fixture_done)return;global.fixture_done=true;
    global.session.transport.close();global.fixture_peer.close();
    var _passed=0;for(var _i=0;_i<array_length(global.fixture_tests);_i++)if(global.fixture_tests[_i].passed)_passed++;
    show_debug_message("FVM_TRANSPORT_RESULT="+json_stringify({kind:"real_coop_session",passed:_passed,total:array_length(global.fixture_tests),tests:global.fixture_tests}));
    game_end();
}
function fixture_peer_request(_type,_id,_body=undefined) {
    var _p=is_struct(_body)?_body:{};_p.v=1;_p.type=_type;_p.request_id=_id;global.fixture_peer.send(_p);
}
function fixture_peer_event(_e) {
    if(global.fixture_done)return;
    if(_e.kind=="error"){fixture_expect("live peer transport: "+_e.code,false);fixture_finish();return;}
    if(_e.kind=="connected"){
        var _code=json_parse(base64_decode(string_delete(global.session.invite_code,1,5)));
        fixture_peer_request("join_room","peer-join",{room_id:_code.room_id,invite_token:_code.invite_token,name:"真实原生队友"});return;
    }
    if(_e.kind!="message")return;
    var _p=_e.data;
    if(_p.type=="error"){fixture_expect("live peer protocol: "+_p.code,false);fixture_finish();return;}
    if(_p.type=="room_joined"){
        global.fixture_peer_id=_p.player_id;
        fixture_expect("actual CoopSession invitation admits native peer",array_length(_p.state.players)==2);
        global.fixture_stage=2;
    } else if(_p.type=="match_started"){
        fixture_expect("actual session starts a real server match",_p.state.room_status=="running");
        fixture_peer_request("input","peer-input",{match_id:_p.match_id,seq:1,action:"place_player",payload:{row:2,col:3}});
    } else if(_p.type=="input_ack"){
        fixture_expect("peer input is acknowledged by real server",_p.seq==1);global.fixture_input_ack=true;
    } else if(_p.type=="snapshot"){
        fixture_expect("session snapshot reaches the native peer",_p.state.test_label=="中文快照" && _p.state.flame==123);
        global.fixture_snapshot_seen=true;
    } else if(_p.type=="match_finished"){
        fixture_expect("native peer receives committed session rewards",variable_struct_get(_p.profiles,global.fixture_peer_id).profile.coins==180);
        global.fixture_result_seen=true;
    }
}
function transport_test_start() {
    global.fixture_tests=[];global.fixture_sent=[];global.fixture_solo_saves=0;global.fixture_navigation=0;
    global.fixture_commands=0;global.fixture_ready=0;global.fixture_ticks=0;global.fixture_clipboard="";global.fixture_write_fail=false;global.fixture_done=false;
    global.fixture_peer_id="";global.fixture_stage=0;global.fixture_input_ack=false;global.fixture_snapshot_seen=false;global.fixture_result_seen=false;
    global.fixture_start=current_time;global.fixture_deadline=current_time+25000;
    fixture_units();fixture_globals(100);
    coop_write_json("coop/host.json",{url:@SERVER_URL@,public_url:@SERVER_URL@,token:@HOST_TOKEN@});
    global.session=new CoopSession();global.coop=global.session;
    global.fixture_peer=new CoopTransport(fixture_peer_event);
    fixture_expect("actual session opens a standard WebSocket",global.session.create());
}
function transport_test_step() {
    if(global.fixture_done)return;
    global.session.tick();global.fixture_peer.tick();
    if(current_time>global.fixture_deadline){fixture_expect("live session completes before deadline (stage "+string(global.fixture_stage)+")",false);fixture_finish();return;}
    switch(global.fixture_stage){
    case 0:
        if(global.session.active && global.session.invite_code!=""){
            fixture_expect("actual session authenticates and creates room",global.session.role=="host" && global.session.connected && global.session.solo.data.coins==100);
            global.fixture_stage=1;global.fixture_peer.connect(@SERVER_URL@);
        }break;
    case 2:
        if(global.session.all_connected()){
            global.save_data.coins=120;
            fixture_expect("actual campaign is queued for durable save",global.session.save_campaign() && is_struct(global.session.campaign_request));
            global.fixture_stage=3;
        }break;
    case 3:
        if(!is_struct(global.session.campaign_request)){
            fixture_expect("actual campaign ACK updates session baseline",json_parse(global.session.campaign_json).coins==120);
            fixture_expect("session can start after campaign ACK",global.session.start_battle("session-test-level"));
            global.fixture_stage=4;
        }break;
    case 4:
        if(global.fixture_commands==1 && global.fixture_input_ack){
            fixture_expect("actual session applies the authoritative input once",global.session.applied_command_id>0 && global.session.battle_started);
            fixture_expect("session emits a standard JSON snapshot",global.session.send_snapshot({test_label:"中文快照",flame:123}));
            global.fixture_stage=5;
        }break;
    case 5:
        if(global.fixture_snapshot_seen){
            global.save_data.coins=180;
            fixture_expect("session result is stored before sending",global.session.submit_result("victory") && is_struct(coop_read_json("coop/session.json").result_request));
            global.fixture_stage=6;
        }break;
    case 6:
        if(global.session.result_saved && global.fixture_result_seen){
            fixture_expect("session accepts durable result ACK",!is_struct(global.session.result_request) && global.session.room_status=="finished" && json_parse(global.session.campaign_json).coins==180);
            fixture_expect("real session leaves without changing solo progress",global.session.leave() && global.save_data.coins==100 && global.save_slot==3);
            fixture_finish();
        }break;
    }
}
