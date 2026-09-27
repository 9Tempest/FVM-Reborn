function transport_test_expect(_name, _passed) {
    array_push(global.transport_tests, {name:_name, passed:_passed});
    show_debug_message((_passed ? "PASS " : "FAIL ") + _name);
}
function transport_test_finish() {
    if (global.transport_finished) return;
    global.transport_finished = true;
    global.transport.close("test_finished");
    var _passed = 0;
    for (var _i = 0; _i < array_length(global.transport_tests); _i++) if (global.transport_tests[_i].passed) _passed++;
    show_debug_message("FVM_TRANSPORT_RESULT=" + json_stringify({passed:_passed,total:array_length(global.transport_tests),tests:global.transport_tests,connections:global.transport_connections,network_event:ev_async_web_networking}));
    game_end();
}
function transport_test_event(_event) {
    if (global.transport_finished) return;
    show_debug_message("TRANSPORT_EVENT kind=" + _event.kind + (variable_struct_exists(_event, "code") ? " code=" + _event.code : ""));
    if (_event.kind == "connected") {
        global.transport_connections++;
        transport_test_expect("native WebSocket connection opens", global.transport.state == "open");
        if (global.transport_phase == "first") {
            transport_test_expect("Chinese JSON sends as text", global.transport.send({v:1,type:"echo",request_id:"unicode",text:"你好，异地合作 🐭"}));
        } else if (global.transport_phase == "second") {
            transport_test_expect("reconnected socket can send", global.transport.send({v:1,type:"echo",request_id:"reconnected",text:"第二次连接"}));
        }
        return;
    }
    if (_event.kind == "message") {
        var _message = _event.data;
        if (_message.type == "closing") {
            global.transport_probe_at = current_time + 500;
            return;
        }
        var _payload = _message.payload;
        if (_payload.request_id == "unicode") {
            transport_test_expect("UTF-8 Chinese and emoji round trip", _payload.text == "你好，异地合作 🐭");
            transport_test_expect("full /game path and query reach standard server", _message.path == "/game?transport_test=1");
            transport_test_expect("server receives text without private header or NUL", _message.text_frame && _message.valid_json);
            global.transport_large = string_repeat("芝士小火炉", 1024);
            transport_test_expect("multi-kilobyte JSON sends", global.transport.send({v:1,type:"echo",request_id:"large",text:global.transport_large}));
        } else if (_payload.request_id == "large") {
            transport_test_expect("multi-kilobyte frame is complete", _payload.text == global.transport_large && _message.byte_count > 4096);
            transport_test_expect("received data survives async buffer ownership", _event.size == string_byte_length(_event.text));
            global.transport_phase = "invalid_json";
            global.transport.send({type:"invalid_json"});
        } else if (_payload.request_id == "reconnected") {
            transport_test_expect("reconnection round trip succeeds", _payload.text == "第二次连接" && global.transport_connections == 2);
            global.transport_phase = "local_close";
            global.transport.close();
            transport_test_expect("local close releases socket", global.transport.socket == -1 && global.transport.state == "closed");
            global.transport_phase = "refused";
            global.transport.connect(@REFUSED_URL@);
        }
        return;
    }
    if (_event.kind == "error") {
        if (global.transport_phase == "invalid_json" && _event.code == "invalid_json") {
            transport_test_expect("malformed incoming JSON becomes a readable error", !_event.fatal && global.transport.state == "open");
            global.transport_phase = "binary";
            global.transport.send({type:"binary"});
        } else if (global.transport_phase == "binary" && _event.code == "binary_frame") {
            transport_test_expect("binary frame is rejected without destroying text socket", !_event.fatal && global.transport.state == "open");
            global.transport_phase = "closing";
            global.transport.send({type:"server_close"});
        } else if (global.transport_phase == "closing" && _event.fatal) {
            transport_test_expect("closed peer is detected by activity timeout or native error", global.transport.socket == -1);
            global.transport_phase = "reconnect_wait";
            global.transport_reconnect_at = current_time + 100;
        } else if (global.transport_phase == "refused") {
            transport_test_expect("connection failure reports readable fatal error", _event.fatal && global.transport.state == "error" && global.transport.socket == -1);
            transport_test_finish();
        } else {
            transport_test_expect("unexpected transport error: " + _event.code, false);
            transport_test_finish();
        }
        return;
    }
    if (_event.kind == "disconnected") {
        if (global.transport_phase == "closing") {
            transport_test_expect("server initiated close is reported", global.transport.state == "closed" && global.transport.socket == -1);
            global.transport_phase = "reconnect_wait";
            global.transport_reconnect_at = current_time + 100;
        } else if (global.transport_phase == "local_close") {
            transport_test_expect("explicit close emits disconnected", _event.reason == "client_close");
        }
    }
}
function transport_test_start() {
    global.transport_tests = [];
    global.transport_finished = false;
    global.transport_connections = 0;
    global.transport_phase = "first";
    global.transport_probe_at = -1;
    global.transport_deadline = current_time + 25000;
    global.transport_url = @ECHO_URL@;
    transport_test_expect("native networking event is Other_68", ev_async_web_networking == 68);
    var _parsed = coop_transport_parse_url("wss://example.com/game?room=test");
    transport_test_expect("WSS URL preserves path and uses port 443", _parsed.ok && _parsed.secure && _parsed.port == 443 && _parsed.path == "/game?room=test");
    _parsed = coop_transport_parse_url("ws://[::1]:8765/game");
    transport_test_expect("bracketed IPv6 URL parses explicit port", _parsed.ok && _parsed.host == "[::1]" && _parsed.port == 8765);
    transport_test_expect("non-WebSocket URL rejected", !coop_transport_parse_url("https://example.com/game").ok);
    transport_test_expect("URL credentials and fragments rejected", !coop_transport_parse_url("ws://user:secret@example.com/game").ok && !coop_transport_parse_url("ws://example.com/game#bad").ok);
    global.transport = new CoopTransport(transport_test_event);
    global.transport.idle_timeout_ms = 1500;
    transport_test_expect("send before connection is rejected", !global.transport.send({type:"test"}));
    transport_test_expect("async raw connection starts", global.transport.connect(global.transport_url));
}
function transport_test_step() {
    if (global.transport_finished) return;
    global.transport.tick();
    if (global.transport_phase == "closing" && global.transport_probe_at >= 0 && current_time >= global.transport_probe_at) {
        global.transport_probe_at = current_time + 500;
        global.transport.send({type:"after_close_probe"});
    }
    if (global.transport_phase == "reconnect_wait" && current_time >= global.transport_reconnect_at) {
        global.transport_phase = "second";
        transport_test_expect("same transport reconnects after remote close", global.transport.connect(global.transport_url));
    }
    if (current_time > global.transport_deadline) {
        transport_test_expect("transport test completed before timeout (phase=" + global.transport_phase + ")", false);
        transport_test_finish();
    }
}
