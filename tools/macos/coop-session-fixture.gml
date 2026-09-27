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
function fixture_profile(_coins) {
    return {coins:_coins,player:{name:"会话测试",total_time:0},unlocked_items:{max_slot:2},
        unlocked_cards:[{id:"small_fire",shape:0,level:0},{id:"toast_bread",shape:0,level:0}]};
}
function coop_loadout_launch_host() { global.fixture_launches++; return true; }
function fixture_level(_id) {
    global.level_id=_id; global.level_data={id:_id,name:"准备关卡"};
    global.level_file={starting_flame:350,map_rows:5};
    global.map_id="fixture-map"; global.map_name="Fixture Map"; global.difficulty=1; global.level_index=2;
}
function fixture_preparation(_level,_revision,_host_ready=false,_guest_ready=false) {
    return {id:"fixture-preparation",level_id:_level,level_name:"准备关卡",slot_limit:2,revision:_revision,
        selections:{"host-test":{deck:["small_fire"],ready:_host_ready,cached:false},
                    "guest-test":{deck:["toast_bread"],ready:_guest_ready,cached:false}}};
}
function fixture_prepared_state(_s,_prep) {
    return {players:coop_clone(_s.players),room_status:"lobby",match_id:undefined,checkpoint:undefined,pending_commands:[],
        features:{personal_loadouts:true},preparation:coop_clone(_prep),config:{}};
}
function fixture_seed_ready(_s,_level) {
    fixture_level(_level);
    _s.host_level_context={preparation_id:"fixture-preparation",level_id:_level,
        level_data:coop_clone(global.level_data),level_file:coop_clone(global.level_file),map_id:global.map_id,difficulty:global.difficulty};
    _s.update_state(fixture_prepared_state(_s,fixture_preparation(_level,5,true,true)));
}
function fixture_sent_count(_type) {
    var _n=0; for(var _i=0;_i<array_length(global.fixture_sent);_i++) if(global.fixture_sent[_i].type==_type) _n++;
    return _n;
}
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
    return {state:"open",last_event:undefined,send:function(_p) { array_push(global.fixture_sent,coop_clone(_p)); return true; },
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
    var _failed=new CoopSession();_failed.url=@SERVER_URL@;
    _failed.transport={state:"closed",last_event:undefined,connect:function(_url){state="error";last_event={kind:"error",fatal:true,code:"connect_failed",message:"fixture DNS failure"};return false;},
        send:function(_packet){state="error";last_event={kind:"error",fatal:true,code:"send_failed",message:"fixture send failure"};return false;},
        close:function(){},tick:function(){return undefined;}};
    fixture_expect("synchronous DNS/connect failure schedules session retry",!_failed.connect_transport() && _failed.retry_at>current_time && _failed.reconnect_attempt==1);
    _failed.tick();
    fixture_expect("one synchronous connection failure is consumed once",_failed.reconnect_attempt==1);
    _failed.transport.state="open";_failed.retry_at=0;_failed.reconnect_attempt=0;_failed.connected=true;
    fixture_expect("synchronous send failure is reported to caller",!_failed.send("ping"));
    _failed.tick();
    fixture_expect("synchronous send failure schedules retry on Step",!_failed.connected && _failed.retry_at>current_time && _failed.reconnect_attempt==1);
    _failed.tick();
    fixture_expect("one synchronous send failure is consumed once",_failed.reconnect_attempt==1);
    // Regression: the world map increments play time every Step. Campaign ACKs
    // must leave a window in which the host can actually send start_match.
    fixture_globals(100);
    var _timed=fixture_unit_session();fixture_seed_ready(_timed,"clock-regression");var _sent_before=array_length(global.fixture_sent);
    var _clock_only_ok=true;
    for(var _frame=0;_frame<120;_frame++){
        global.save_data.player.total_time+=1/60;
        _clock_only_ok=_timed.save_campaign() && !is_struct(_timed.campaign_request) && _clock_only_ok;
    }
    fixture_expect("continuous play-clock changes do not enqueue campaign transactions",_clock_only_ok && array_length(global.fixture_sent)==_sent_before);
    fixture_expect("continuous play clock does not prevent starting a match",_timed.start_battle("clock-regression") && !is_struct(_timed.campaign_request));
    var _start=global.fixture_sent[array_length(global.fixture_sent)-1];
    fixture_expect("start uses acknowledged preparation without inline profile mutations",_start.type=="start_match" && _start.preparation_id=="fixture-preparation" && _start.revision==5 && !variable_struct_exists(_start,"profiles"));
    _timed.start_request_id=""; // Fake transport has no server ACK; allow a second start request below.
    _timed.campaign_committed_at=current_time-29999;
    fixture_expect("clock-only save waits until the 30-second deadline",_timed.save_campaign() && !is_struct(_timed.campaign_request));
    _timed.campaign_committed_at=current_time-30000;
    fixture_expect("clock-only save becomes durable at 30 seconds",_timed.save_campaign() && is_struct(_timed.campaign_request) && _timed.outbox_durable);
    fixture_expect("periodic clock save contains the complete latest profile",variable_struct_get(_timed.campaign_request.profiles,"host-test").player.total_time==global.save_data.player.total_time && variable_struct_get(_timed.campaign_request.profiles,"host-test").coins==100);
    var _clock_id=_timed.campaign_request.request_id;global.save_data.player.total_time+=1/60;
    _timed.packet({type:"campaign_saved",request_id:_clock_id});
    fixture_expect("clock save ACK resets debounce despite another clock tick",current_time-_timed.campaign_committed_at<1000 && _timed.save_campaign() && !is_struct(_timed.campaign_request));
    fixture_expect("start can proceed immediately after a clock-only ACK",_timed.start_battle("clock-regression") && !is_struct(_timed.campaign_request));
    global.save_data.coins=90;global.save_data.cards=["new-card"];
    fixture_expect("purchase and deduction bypass the clock debounce immediately",_timed.save_campaign() && is_struct(_timed.campaign_request) && variable_struct_get(_timed.campaign_request.profiles,"host-test").coins==90 && variable_struct_get(_timed.campaign_request.profiles,"host-test").cards[0]=="new-card");
    _timed.packet({type:"campaign_saved",request_id:_timed.campaign_request.request_id});
    global.save_data.player.name="改名即时保存";global.save_data.player.total_time+=1/60;
    fixture_expect("other player fields are not hidden by timer-only debounce",_timed.save_campaign() && is_struct(_timed.campaign_request) && variable_struct_get(_timed.campaign_request.profiles,"host-test").player.name=="改名即时保存");
    fixture_loadout_units();
    // Clear only this unique test app's credentials before the live protocol test.
    for(var _i=0;_i<3;_i++) {var _path=["coop/session.json","coop/session.json.pending","coop/session.json.bak"][_i];if(file_exists(_path))file_delete(_path);}
}
function fixture_loadout_units() {
    fixture_globals(100);
    var _s=fixture_unit_session();
    fixture_expect("start is gated before either deck is confirmed",!_s.start_battle("chosen-level"));
    _s.personal_loadouts_supported=true; fixture_level("chosen-level"); global.save_data.coins=101;
    var _before=fixture_sent_count("prepare_match");
    fixture_expect("preparation waits behind the pending campaign commit",_s.prepare_loadout("chosen-level","准备关卡",2) && is_struct(_s.campaign_request) && is_struct(_s.preparation_queued) && fixture_sent_count("prepare_match")==_before);
    var _disk=coop_read_json("coop/session.json");
    fixture_expect("host level context is persisted before prepare is sent",_disk.host_level_context.level_file.starting_flame==350 && _disk.host_level_context.level_data.id=="chosen-level");
    _s.packet({type:"campaign_saved",request_id:_s.campaign_request.request_id});
    fixture_expect("campaign ACK releases the preparation request",_s.flush_preparation() && is_struct(_s.preparation_request) && fixture_sent_count("prepare_match")==_before+1);
    var _prep=fixture_preparation("chosen-level",1); _prep.selections[$ "host-test"].deck=[]; _prep.selections[$ "guest-test"].deck=[];
    _s.packet({type:"loadout_state",request_id:_s.preparation_request.request_id,state:fixture_prepared_state(_s,_prep)});
    fixture_expect("prepare ACK binds level context to its server identity",_s.loadout_host_level_ready && _s.host_level_context.preparation_id==_prep.id && ! _s.loadout_pending);
    fixture_expect("local deck edit becomes pending until its ACK",_s.set_loadout(["small_fire"],false) && _s.loadout_pending && _s.loadout_draft[0]=="small_fire");
    _prep.revision=2; _prep.selections[$ "guest-test"].deck=["toast_bread"];
    _s.packet({type:"loadout_state",state:fixture_prepared_state(_s,_prep)});
    fixture_expect("peer revision does not erase an unacknowledged local draft",_s.loadout_pending && _s.loadout_draft[0]=="small_fire" && _s.preparation_revision==2);
    _prep.revision=3; _prep.selections[$ "host-test"].deck=["small_fire"];
    _s.packet({type:"loadout_state",request_id:_s.loadout_request_id,state:fixture_prepared_state(_s,_prep)});
    fixture_expect("matching deck ACK commits the current revision",!_s.loadout_pending && _s.preparation_revision==3 && _s.loadout_draft[0]=="small_fire");
    _s.set_loadout(["small_fire"],true);
    _prep.revision=4; _prep.selections[$ "guest-test"].deck=["small_fire","toast_bread"];
    _s.packet({type:"error",request_id:_s.loadout_request_id,code:"preparation_conflict",message:"changed",state:fixture_prepared_state(_s,_prep)});
    var _retry=global.fixture_sent[array_length(global.fixture_sent)-1];
    fixture_expect("revision conflict rebases only the edit and never auto-readies",_retry.type=="set_loadout" && _retry.revision==4 && !_retry.ready && _s.loadout_pending && _s.loadout_retry_count==1);
    _prep.revision=5;
    _s.packet({type:"loadout_state",request_id:_s.loadout_request_id,state:fixture_prepared_state(_s,_prep)});
    _s.remember();
    fixture_level("unrelated-level");
    var _resumed=new CoopSession(); _resumed.transport=fixture_fake_transport();
    fixture_expect("saved preparation context survives native session restart",_resumed.resume() && _resumed.host_level_context.level_id=="chosen-level");
    _prep.selections[$ "host-test"].cached=true;
    _resumed.packet({type:"resumed",role:"host",room_id:"room-test",player_id:"host-test",state:fixture_prepared_state(_s,_prep)});
    fixture_expect("reconnect restores exact host level rather than current globals",global.level_data.id=="chosen-level" && global.level_file.starting_flame==350 && _resumed.loadout_host_level_ready);
    _resumed.set_loadout(["toast_bread"],true); _resumed.network_lost();
    var _edits=fixture_sent_count("set_loadout");
    _resumed.packet({type:"resumed",role:"host",room_id:"room-test",player_id:"host-test",state:fixture_prepared_state(_s,_prep)});
    _resumed.tick();
    fixture_expect("reconnect restores cached server draft without replaying Ready",!_resumed.loadout_pending && _resumed.loadout_draft[0]=="small_fire" && !_resumed.both_loadouts_ready() && fixture_sent_count("set_loadout")==_edits);
    _resumed.set_loadout(["small_fire"],false);
    var _replacement=fixture_preparation("different-level",1); _replacement.id="new-preparation";
    _resumed.packet({type:"error",request_id:_resumed.loadout_request_id,code:"stale_preparation",message:"different level",state:fixture_prepared_state(_s,_replacement)});
    fixture_expect("mismatched preparation error refreshes state and invalidates old level",_resumed.preparation.id=="new-preparation" && !_resumed.loadout_pending && !_resumed.loadout_host_level_ready && !_resumed.start_battle("different-level"));
    fixture_globals(100); var _simultaneous=fixture_unit_session(); fixture_seed_ready(_simultaneous,"same-choices");
    var _same=fixture_preparation("same-choices",5);
    _simultaneous.update_state(fixture_prepared_state(_simultaneous,_same));
    _simultaneous.set_loadout(["small_fire"],true);
    _same.revision=6; _same.selections[$ "guest-test"].ready=true;
    _simultaneous.packet({type:"error",request_id:_simultaneous.loadout_request_id,code:"preparation_conflict",message:"simultaneous ready",state:fixture_prepared_state(_simultaneous,_same)});
    _retry=global.fixture_sent[array_length(global.fixture_sent)-1];
    fixture_expect("simultaneous Ready may retry when both decks and campaign are unchanged",_retry.type=="set_loadout" && _retry.ready && _retry.revision==6);
    _same.revision=7; _same.selections[$ "host-test"].ready=true;
    _simultaneous.packet({type:"loadout_state",request_id:_simultaneous.loadout_request_id,state:fixture_prepared_state(_simultaneous,_same)});
    _simultaneous.set_loadout(["small_fire"],true);
    global.save_data.player.total_time+=1/60; _same.revision=8;
    _simultaneous.packet({type:"error",request_id:_simultaneous.loadout_request_id,code:"preparation_conflict",message:"clock only",state:fixture_prepared_state(_simultaneous,_same)});
    _retry=global.fixture_sent[array_length(global.fixture_sent)-1];
    fixture_expect("play-time alone does not revoke deliberate Ready on a revision retry",_retry.ready && _retry.revision==8);
    _same.revision=9;
    _simultaneous.packet({type:"loadout_state",request_id:_simultaneous.loadout_request_id,state:fixture_prepared_state(_simultaneous,_same)});
    _simultaneous.set_loadout(["small_fire"],true);
    global.save_data.unlocked_cards[0].level=1; _same.revision=10;
    _simultaneous.packet({type:"error",request_id:_simultaneous.loadout_request_id,code:"preparation_conflict",message:"library changed",state:fixture_prepared_state(_simultaneous,_same)});
    _retry=global.fixture_sent[array_length(global.fixture_sent)-1];
    fixture_expect("library upgrades require a fresh Ready confirmation",!_retry.ready && _retry.revision==10);
    fixture_globals(100); var _ready=fixture_unit_session(); fixture_seed_ready(_ready,"both-ready");
    var _starts=fixture_sent_count("start_match");
    fixture_expect("both prepared players send a single pending start request",_ready.start_battle("both-ready") && _ready.start_battle("both-ready") && fixture_sent_count("start_match")==_starts+1);
    _ready.tick();
    fixture_expect("automatic ready tick cannot duplicate an unacknowledged start",fixture_sent_count("start_match")==_starts+1);
    _ready.start_request_id=""; _ready.loadout_host_level_ready=false;
    fixture_expect("ready flags cannot launch without matching persisted level context",!_ready.start_battle("both-ready"));
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
    } else if(_p.type=="loadout_state"){
        if(coop_get(_p,"request_id","")=="peer-deck" || coop_get(_p,"request_id","")=="peer-ready") global.fixture_peer_revision=_p.state.preparation.revision;
    } else if(_p.type=="match_started"){
        fixture_expect("actual session starts a real server match",_p.state.room_status=="running" && _p.state.config.per_player_loadouts && variable_struct_get(_p.state.config.loadouts,global.fixture_peer_id)[0]=="toast_bread");
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
    global.fixture_commands=0;global.fixture_launches=0;global.fixture_ready=0;global.fixture_ticks=0;global.fixture_clipboard="";global.fixture_write_fail=false;global.fixture_done=false;
    global.fixture_peer_id="";global.fixture_stage=0;global.fixture_input_ack=false;global.fixture_snapshot_seen=false;global.fixture_result_seen=false;
    global.fixture_start=current_time;global.fixture_deadline=current_time+25000;
    fixture_units();fixture_globals(100);global.fixture_launches=0;global.fixture_peer_revision=0;
    coop_write_json("coop/host.json",{url:@SERVER_URL@,public_url:@SERVER_URL@,token:@HOST_TOKEN@});
    global.session=new CoopSession();global.coop=global.session;
    global.fixture_peer=new CoopTransport(fixture_peer_event);
    fixture_expect("actual session opens a standard WebSocket",global.session.create());
}
function transport_test_step() {
    if(global.fixture_done)return;
    global.save_data.player.total_time+=1/60;global.total_time=global.save_data.player.total_time;
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
            fixture_expect("real Step clock advances beyond the acknowledged campaign",global.save_data.player.total_time>json_parse(global.session.campaign_json).player.total_time);
            fixture_level("session-test-level");
            fixture_expect("session prepares a shared level after campaign ACK",global.session.prepare_loadout("session-test-level","真实准备关卡",2));
            global.fixture_stage=30;
        }break;
    case 30:
        if(is_struct(global.session.preparation) && !global.session.loadout_pending){
            fixture_expect("actual prepare ACK restores the chosen host level",global.session.loadout_host_level_ready && coop_read_json("coop/session.json").host_level_context.preparation_id==global.session.preparation.id);
            fixture_expect("actual host saves its independent draft",global.session.set_loadout(["small_fire"],false));
            global.fixture_stage=31;
        }break;
    case 31:
        if(!global.session.loadout_pending){
            fixture_peer_request("set_loadout","peer-deck",{preparation_id:global.session.preparation.id,revision:global.session.preparation_revision,deck:["toast_bread"],ready:false});
            global.fixture_stage=32;
        }break;
    case 32:
        if(global.fixture_peer_revision>0 && global.session.preparation_revision>=global.fixture_peer_revision){
            fixture_expect("actual host confirms Ready after both drafts are acknowledged",global.session.set_loadout(["small_fire"],true));
            global.fixture_stage=33;
        }break;
    case 33:
        if(!global.session.loadout_pending){
            fixture_peer_request("set_loadout","peer-ready",{preparation_id:global.session.preparation.id,revision:global.session.preparation_revision,deck:["toast_bread"],ready:true});
            global.fixture_stage=34;
        }break;
    case 34:
        if(global.session.battle_started){
            fixture_expect("both Ready confirmations launch the host exactly once",global.fixture_launches==1 && global.session.match_config.per_player_loadouts && variable_struct_get(global.session.match_config.loadouts,global.session.player_id)[0]=="small_fire");
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
