#macro room_coop room_transport_test
#macro room_menu room_transport_test
#macro spr_lose -1
function save_file(_slot){return true;}
function save_data_valid(_p){return is_struct(_p);}
function save_progress_json(){return json_stringify(global.save_data);}
function coop_battle_ready(){}
function coop_battle_tick(){}
function coop_battle_command(_p){}
function wss_expect(_name,_ok){array_push(global.wss_tests,{name:_name,passed:_ok});show_debug_message((_ok?"PASS ":"FAIL ")+_name);}
function wss_finish(){
    if(global.wss_done)return;global.wss_done=true;
    global.transport.close();global.session.transport.close();
    var _passed=0;for(var _i=0;_i<array_length(global.wss_tests);_i++)if(global.wss_tests[_i].passed)_passed++;
    show_debug_message("FVM_TRANSPORT_RESULT="+json_stringify({kind:"trusted_public_wss",tls_verified:_passed==array_length(global.wss_tests),passed:_passed,total:array_length(global.wss_tests),tests:global.wss_tests}));game_end();
}
function wss_raw_event(_e){
    if(global.wss_done)return;
    if(_e.kind=="error"){wss_expect("public WSS transport "+_e.code,false);wss_finish();return;}
    if(_e.kind=="connected"){
        wss_expect("native runner completes public TLS WebSocket handshake",true);
        wss_expect("native runner sends standard JSON text over WSS",global.transport.send({v:1,type:"get_state",request_id:"native-wss-no-token",test_label:"中文握手测试"}));
    }else if(_e.kind=="message"){
        wss_expect("public server rejects unauthenticated native WSS request",_e.data.type=="error" && _e.data.code=="authentication_required" && _e.data.request_id=="native-wss-no-token");
        global.transport.close();
        wss_expect("actual CoopSession initiates WSS with invalid test credential",global.session.create());
    }
}
function wss_session_event(_e){
    if(!is_struct(_e)||global.wss_done)return;
    global.session.event(_e);
    if(_e.kind=="connected")wss_expect("actual CoopSession completes native public WSS handshake",true);
    if(_e.kind=="error"){wss_expect("session WSS transport "+_e.code,false);wss_finish();}
    if(_e.kind=="message" && _e.data.type=="error"){
        wss_expect("actual session receives invalid-token rejection",_e.data.code=="unauthorized");
        wss_expect("rejected session remains inactive and stops retries",!global.session.active && !global.session.connected && global.session.leaving && global.session.retry_at==0);
        wss_expect("rejected authentication preserves the synthetic solo profile",global.save_data.coins==100 && global.save_slot==4);
        wss_finish();
    }
}
function transport_test_start(){
    global.wss_tests=[];global.wss_done=false;global.wss_deadline=current_time+20000;
    global.save_data={coins:100,player:{name:"TLS测试",total_time:0}};global.save_slot=4;global.loaded_save_slot=4;
    global.player_name="TLS测试";global.total_time=0;global.save_ready=true;global.save_last_json=json_stringify(global.save_data);global.save_last_progress=global.save_last_json;
    global.gui_stack={to:function(_r){}};global.game_version="wss-test";global.game_over=false;
    coop_write_json("coop/host.json",{url:@SERVER_URL@,public_url:@SERVER_URL@,token:"deliberately-invalid-native-test-token"});
    global.session=new CoopSession();global.transport=new CoopTransport(wss_raw_event);
    wss_expect("trusted WSS URL selects secure native socket",coop_transport_parse_url(@SERVER_URL@).secure);
    wss_expect("public WSS connection is accepted for asynchronous connect",global.transport.connect(@SERVER_URL@));
}
function transport_test_step(){
    if(global.wss_done)return;
    global.transport.tick();wss_session_event(global.session.transport.tick());
    if(current_time>global.wss_deadline){wss_expect("public WSS completes before deadline",false);wss_finish();}
}
