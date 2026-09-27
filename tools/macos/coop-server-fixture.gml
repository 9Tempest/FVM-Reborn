// Real native VM clients exercising the real Python server; no game saves used.
function server_test_expect(_name, _passed) {
    array_push(global.server_tests, {name:_name, passed:_passed});
    show_debug_message((_passed ? "PASS " : "FAIL ") + _name);
}
function server_test_request(_peer, _type, _request_id, _fields = undefined) {
    var _packet = is_undefined(_fields) ? {} : _fields;
    _packet.v = 1;
    _packet.type = _type;
    _packet.request_id = _request_id;
    if (!_peer.send(_packet)) {
        server_test_expect("send " + _type + " accepted", false);
        server_test_finish();
    }
}
function server_test_finish() {
    if (global.server_finished) return;
    global.server_finished = true;
    global.transport.close("test_finished");
    global.server_guest.close("test_finished");
    var _passed = 0;
    for (var _i=0; _i<array_length(global.server_tests); _i++) if (global.server_tests[_i].passed) _passed++;
    show_debug_message("FVM_TRANSPORT_RESULT=" + json_stringify({kind:"real_server_protocol",passed:_passed,total:array_length(global.server_tests),tests:global.server_tests}));
    game_end();
}
function server_test_maybe_snapshot() {
    if (global.server_command_received && global.server_inputs_checked && !global.server_snapshot_sent) {
        global.server_snapshot_sent = true;
        server_test_request(global.transport, "snapshot", "snapshot-1", {match_id:global.server_match_id,tick:50,applied_command_id:global.server_command_id,durable:true,state:{entities:[{kind:"player",row:2,col:3,name:"合作客人"}],hud:{flame:123}}});
    }
}
function server_test_maybe_result() {
    if (global.server_snapshot_ack && global.server_guest_snapshot && global.server_guest_forbidden && !global.server_result_sent) {
        global.server_result_sent = true;
        var _profiles = {};
        variable_struct_set(_profiles, global.server_host_id, {coins:150,level:2,name:"原生主机"});
        variable_struct_set(_profiles, global.server_guest_id, {coins:150,level:2,name:"原生客人"});
        global.server_result_packet = {match_id:global.server_match_id,result:{outcome:"victory",reward:{coins:50}},profiles:_profiles};
        server_test_request(global.transport, "match_result", "result-1", global.server_result_packet);
    }
}
function server_test_maybe_resume() {
    if (global.server_result_duplicate && global.server_guest_finished && !global.server_resume_started) {
        global.server_resume_started = true;
        server_test_request(global.server_guest, "ping", "guest-ping");
    }
}
function server_test_host_event(_event) { server_test_event("host", _event); }
function server_test_guest_event(_event) { server_test_event("guest", _event); }
function server_test_event(_role, _event) {
    if (global.server_finished) return;
    if (_event.kind == "error") {
        server_test_expect(_role + " transport error: " + _event.code, false);
        server_test_finish();
        return;
    }
    if (_event.kind == "connected") {
        if (_role == "host") {
            server_test_request(global.transport, "auth_host", "host-auth", {token:@HOST_TOKEN@});
        } else if (global.server_resume_started) {
            server_test_request(global.server_guest, "resume", "guest-resume", {room_id:global.server_room_id,resume_token:global.server_guest_resume});
        } else {
            server_test_request(global.server_guest, "join_room", "guest-join", {room_id:global.server_room_id,invite_token:global.server_invite,name:"合作客人"});
        }
        return;
    }
    if (_event.kind != "message") return;
    var _message = _event.data;
    var _request_id = variable_struct_exists(_message, "request_id") ? _message.request_id : "";
    // Deliberately don't print tokens, invitations, or complete packets.
    show_debug_message("SERVER_PACKET role=" + _role + " type=" + _message.type + " request=" + _request_id);
    if (_message.type == "error") {
        if (_request_id == "input-gap") {
            server_test_expect("server rejects sequence gaps", _message.code == "sequence_gap");
            global.server_inputs_checked = true;
            server_test_maybe_snapshot();
        } else if (_request_id == "guest-snapshot") {
            server_test_expect("guest cannot publish authoritative snapshots", _message.code == "forbidden");
            global.server_guest_forbidden = true;
            server_test_maybe_result();
        } else {
            server_test_expect(_role + " unexpected protocol error " + _message.code, false);
            server_test_finish();
        }
        return;
    }
    switch (_request_id) {
        case "host-auth":
            server_test_expect("native host authenticates with disposable credential", _message.type == "host_authenticated");
            server_test_request(global.transport, "create_room", "host-create", {profile:{coins:100,level:1,name:"原生测试存档",cards:["toast_bread"]},name:"原生合作测试",player_name:"原生主机"});
            break;
        case "host-create":
            server_test_expect("native host creates a two-player room", _message.type == "room_created" && _message.role == "host");
            global.server_room_id = _message.room_id;
            global.server_host_id = _message.player_id;
            global.server_invite = _message.invite_token;
            server_test_expect("host profile survives JSON/SQLite round trip", _message.state.players[0].profile.coins == 100 && _message.state.players[0].profile.name == "原生测试存档");
            server_test_expect("native guest connection begins", global.server_guest.connect(@SERVER_URL@));
            break;
        case "guest-join":
            server_test_expect("native guest joins with the one-use invitation", _message.type == "room_joined" && _message.role == "guest" && array_length(_message.state.players) == 2);
            global.server_guest_id = _message.player_id;
            global.server_guest_resume = _message.resume_token;
            server_test_request(global.transport, "start_match", "match-start", {level_id:"cocoa_island_daytime",config:{shared_campaign:true}});
            break;
        case "match-start":
            server_test_expect("host starts authoritative match", _message.type == "match_started" && _message.state.room_status == "running");
            global.server_match_id = _message.match_id;
            break;
        case "input-1":
            server_test_expect("native floating-point sequence accepted as integer", _message.type == "input_ack" && _message.seq == 1 && !_message.duplicate);
            global.server_input_ack_id = _message.command_id;
            server_test_request(global.server_guest, "input", "input-duplicate", {match_id:global.server_match_id,seq:1,action:"place_player",payload:{row:2,col:3}});
            break;
        case "input-duplicate":
            server_test_expect("repeated native input is idempotent", _message.type == "input_ack" && _message.duplicate && _message.command_id == global.server_input_ack_id);
            server_test_request(global.server_guest, "input", "input-gap", {match_id:global.server_match_id,seq:3,action:"place_player",payload:{row:2,col:3}});
            break;
        case "snapshot-1":
            server_test_expect("host checkpoint commits durably", _message.type == "snapshot_ack" && _message.persisted);
            global.server_snapshot_ack = true;
            server_test_maybe_result();
            break;
        case "result-1":
            server_test_expect("native match result commits once", _message.type == "match_result_ack" && _message.committed && !_message.duplicate);
            var _host_profile = variable_struct_get(_message.profiles, global.server_host_id);
            var _guest_profile = variable_struct_get(_message.profiles, global.server_guest_id);
            server_test_expect("both committed profiles returned to native client", _host_profile.profile.coins == 150 && _guest_profile.profile.coins == 150);
            global.server_result_revision = _host_profile.revision;
            server_test_request(global.transport, "match_result", "result-retry", global.server_result_packet);
            break;
        case "result-retry":
            var _host_profile = variable_struct_get(_message.profiles, global.server_host_id);
            server_test_expect("result retry does not grant rewards twice", _message.type == "match_result_ack" && _message.duplicate && _host_profile.revision == global.server_result_revision);
            global.server_result_duplicate = true;
            server_test_maybe_resume();
            break;
        case "guest-ping":
            server_test_expect("application heartbeat gets pong", _message.type == "pong");
            global.server_guest.close("reconnect_test");
            global.server_reconnect_at = current_time + 100;
            break;
        case "guest-resume":
            server_test_expect("native guest resumes the same identity", _message.type == "resumed" && _message.player_id == global.server_guest_id);
            server_test_expect("resume restores checkpoint and finished result", _message.state.room_status == "finished" && _message.state.result.outcome == "victory" && _message.state.checkpoint.state.hud.flame == 123);
            server_test_finish();
            break;
    }
    if (_request_id == "" && _role == "guest" && _message.type == "match_started") {
        global.server_match_id = _message.match_id;
        server_test_expect("guest receives match start broadcast", _message.state.room_status == "running");
        server_test_request(global.server_guest, "input", "input-1", {match_id:global.server_match_id,seq:1,action:"place_player",payload:{row:2,col:3}});
    } else if (_request_id == "" && _role == "host" && _message.type == "command") {
        server_test_expect("guest input reaches native authoritative host", _message.player_id == global.server_guest_id && _message.action == "place_player" && _message.payload.row == 2 && _message.payload.col == 3);
        global.server_command_id = _message.command_id;
        global.server_command_received = true;
        server_test_maybe_snapshot();
    } else if (_request_id == "" && _role == "guest" && _message.type == "snapshot") {
        server_test_expect("guest receives authoritative entity and HUD snapshot", _message.state.hud.flame == 123 && _message.state.entities[0].name == "合作客人");
        global.server_guest_snapshot = true;
        server_test_request(global.server_guest, "snapshot", "guest-snapshot", {match_id:global.server_match_id,tick:51,applied_command_id:global.server_command_id,state:{}});
        server_test_maybe_result();
    } else if (_request_id == "" && _role == "guest" && _message.type == "match_finished") {
        server_test_expect("guest receives committed match completion", _message.result.outcome == "victory");
        global.server_guest_finished = true;
        server_test_maybe_resume();
    }
}
function transport_test_start() {
    global.server_tests = [];
    global.server_finished = false;
    global.server_resume_started = false;
    global.server_command_received = false;
    global.server_inputs_checked = false;
    global.server_snapshot_sent = false;
    global.server_snapshot_ack = false;
    global.server_guest_snapshot = false;
    global.server_guest_forbidden = false;
    global.server_result_sent = false;
    global.server_result_duplicate = false;
    global.server_guest_finished = false;
    global.server_reconnect_at = -1;
    global.server_deadline = current_time + 20000;
    global.transport = new CoopTransport(server_test_host_event);
    global.server_guest = new CoopTransport(server_test_guest_event);
    server_test_expect("native host connection begins", global.transport.connect(@SERVER_URL@));
}
function transport_test_step() {
    if (global.server_finished) return;
    global.transport.tick();
    global.server_guest.tick();
    if (global.server_reconnect_at >= 0 && current_time >= global.server_reconnect_at) {
        global.server_reconnect_at = -1;
        server_test_expect("native guest reconnect begins", global.server_guest.connect(@SERVER_URL@));
    }
    if (current_time > global.server_deadline) {
        server_test_expect("native server protocol completes before timeout", false);
        server_test_finish();
    }
}
