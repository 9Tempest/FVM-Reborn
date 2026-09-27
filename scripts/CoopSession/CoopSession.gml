/// The host owns simulation. The server owns shared progress. Solo saves stay separate.
function coop_get(_value, _key, _fallback = undefined) {
    return is_struct(_value) && variable_struct_exists(_value, _key) ? variable_struct_get(_value, _key) : _fallback;
}
function coop_clone(_value) { return json_parse(json_stringify(_value)); }
function coop_read_text(_path) {
    if (!file_exists(_path)) return undefined;
    var _f = file_text_open_read(_path);
    if (_f < 0) return undefined;
    var _s = "";
    while (!file_text_eof(_f)) { _s += file_text_read_string(_f); file_text_readln(_f); }
    file_text_close(_f);
    return _s;
}
function coop_read_json(_path) {
    var _s = coop_read_text(_path);
    if (!is_string(_s)) return undefined;
    try { return json_parse(_s); } catch (_error) { return undefined; }
}
function coop_write_json(_path, _data) {
    if (!directory_exists("coop")) directory_create("coop");
    var _tmp = _path + ".pending";
    var _f = file_text_open_write(_tmp);
    if (_f < 0) return false;
    var _json = json_stringify(_data);
    file_text_write_string(_f, _json);
    if (!file_text_close(_f) || coop_read_text(_tmp) != _json || !is_struct(coop_read_json(_tmp))) return false;
    var _bak = _path + ".bak";
    if (file_exists(_bak) && !file_delete(_bak)) return false;
    if (file_exists(_path) && !file_rename(_path, _bak)) return false;
    if (!file_rename(_tmp, _path)) {
        if (!file_exists(_path) && file_exists(_bak)) file_copy(_bak, _path);
        return false;
    }
    return true;
}
function coop_is_active() {
    return variable_global_exists("coop") && is_struct(global.coop) && global.coop.active;
}
function coop_campaign_progress(_json) {
    if (_json=="") return "";
    try {
        var _profile=json_parse(_json);
        if (is_struct(coop_get(_profile,"player"))) _profile.player.total_time=0;
        return json_stringify(_profile);
    } catch (_error) { return _json; }
}
function CoopSession() constructor {
    transport = new CoopTransport();
    transport.idle_timeout_ms = 15000;
    active = false;
    connected = false;
    shared_screen_supported = false;
    role = "";
    player_id = "";
    players = [];
    room_id = "";
    match_id = "";
    room_status = "lobby";
    battle_started = false;
    start_request_id = "";
    status = "两台 Mac，异地合作，共同闯关";
    url = "";
    public_url = "";
    resume_token = "";
    invite_code = "";
    entry = "";
    entry_data = undefined;
    host_config = coop_read_json("coop/host.json");
    saved_session = coop_read_json("coop/session.json");
    if (!is_struct(saved_session)) saved_session = coop_read_json("coop/session.json.pending");
    if (!is_struct(saved_session)) saved_session = coop_read_json("coop/session.json.bak");
    solo = undefined;
    latest = undefined;
    previous = undefined;
    received_at = 0;
    request_counter = 0;
    request_prefix = string(get_timer()) + "-" + string(irandom(999999));
    seq = 0;
    snapshot_tick = 0;
    applied_command_id = 0;
    retry_at = 0;
    reconnect_attempt = 0;
    last_ping = 0;
    last_campaign_check = 0;
    campaign_json = "";
    campaign_committed_at = current_time;
    campaign_pending_json = "";
    campaign_request = undefined;
    result_request = undefined;
    outbox_durable = true;
    result_saved = false;
    result_outcome = "";
    inputs_pending = [];
    selected_slot = -1;
    selected_gem = -1;
    shovel_selected = false;
    leaving = false;
    preparation = undefined;
    preparation_revision = -1;
    match_config = {};
    loadout_draft = [];
    loadout_pending = false;
    loadout_request_id = "";
    preparation_request = undefined;
    preparation_queued = undefined;
    loadout_changing_level = false;
    loadout_host_level_ready = false;
    host_level_context = undefined;
    personal_loadouts_supported = false;
    loadout_start_retry_at = 0;
    loadout_attempt = undefined;
    loadout_attempt_view = undefined;
    loadout_attempt_profile = "";
    loadout_retry_count = 0;

    static request = function(_type, _body = undefined) {
        var _p = is_struct(_body) ? coop_clone(_body) : {};
        _p.v = 1; _p.type = _type;
        request_counter++;
        _p.request_id = request_prefix + "-" + string(request_counter);
        return _p;
    };
    static send = function(_type, _body = undefined) { return transport.send(request(_type, _body)); };
    static all_connected = function() {
        if (!connected || array_length(players) != 2) return false;
        for (var _i = 0; _i < array_length(players); _i++) if (!coop_get(players[_i], "connected", false)) return false;
        return true;
    };
    static restore_host_level = function(_preparation_id, _level_id) {
        loadout_host_level_ready = false;
        if (role != "host" || !is_struct(host_level_context)
            || coop_get(host_level_context,"preparation_id","") != _preparation_id
            || coop_get(host_level_context,"level_id","") != _level_id
            || !is_struct(coop_get(host_level_context,"level_data"))
            || coop_get(host_level_context.level_data,"id","") != _level_id
            || !is_struct(coop_get(host_level_context,"level_file"))) return false;
        var _keys = ["level_id","level_data","level_file","map_id","map_name","difficulty","level_index"];
        for (var _i=0; _i<array_length(_keys); _i++) {
            if (variable_struct_exists(host_level_context,_keys[_i])) {
                variable_global_set(_keys[_i],coop_clone(variable_struct_get(host_level_context,_keys[_i])));
            }
        }
        loadout_host_level_ready = true;
        return true;
    };
    static sync_preparation = function(_value, _force_local = false) {
        if (!is_struct(_value)) {
            preparation=undefined; preparation_revision=-1;
            if (!loadout_pending) loadout_draft=[];
            return;
        }
        var _changed = !is_struct(preparation) || coop_get(preparation,"id","") != coop_get(_value,"id","");
        var _revision = coop_get(_value,"revision",0);
        if (!_changed && _revision < preparation_revision) return;
        preparation=coop_clone(_value); preparation_revision=_revision;
        if (_changed || _force_local || !loadout_pending) {
            var _selection=coop_get(coop_get(preparation,"selections"),player_id);
            loadout_draft=coop_clone(coop_get(_selection,"deck",[]));
        }
        if (role=="host") {
            // A newly acknowledged choice binds the persisted level description
            // to this server-generated preparation, never to a stale room state.
            if (is_struct(preparation_request) && is_struct(host_level_context)
                && preparation_request.level_id == preparation.level_id) {
                host_level_context.preparation_id=preparation.id;
                if (!remember()) { loadout_host_level_ready=false; return; }
            }
            restore_host_level(preparation.id,preparation.level_id);
        }
    };
    static prepare_loadout = function(_level_id,_level_name,_limit) {
        if (!active || role!="host" || !all_connected() || room_status=="running") {
            status="需要两位玩家在线，并先结束当前战斗"; return false;
        }
        if (!personal_loadouts_supported) { status="请先更新这台 Mac 的合作服务和双方游戏版本"; return false; }
        if (loadout_pending) return is_struct(preparation_queued) || is_struct(preparation_request);
        if (!variable_global_exists("level_data") || !variable_global_exists("level_file")
            || !is_struct(global.level_data) || !is_struct(global.level_file)) {
            status="请重新选择关卡"; return false;
        }
        host_level_context={level_id:_level_id,preparation_id:""};
        var _keys=["level_data","level_file","map_id","map_name","difficulty","level_index"];
        for (var _i=0;_i<array_length(_keys);_i++) if (variable_global_exists(_keys[_i])) {
            variable_struct_set(host_level_context,_keys[_i],coop_clone(variable_global_get(_keys[_i])));
        }
        loadout_host_level_ready=false;
        if (!remember()) return false;
        preparation_queued={level_id:_level_id,level_name:_level_name,slot_limit:_limit};
        loadout_pending=true; loadout_changing_level=false;
        status="正在保存共同进度并准备双方选卡…";
        flush_preparation();
        return true;
    };
    static flush_preparation = function() {
        if (!is_struct(preparation_queued) || !connected || role!="host" || room_status=="running") return false;
        if (is_struct(result_request) || is_struct(campaign_request)) { flush_outbox(); return false; }
        if (!save_campaign() || is_struct(campaign_request)) return false;
        preparation_request=request("prepare_match",preparation_queued);
        preparation_queued=undefined; loadout_request_id=preparation_request.request_id;
        return transport.send(preparation_request);
    };
    static set_loadout = function(_deck,_ready,_retry=false) {
        if (!active || !connected || !is_struct(preparation) || room_status=="running"
            || loadout_pending || !is_array(_deck) || !is_bool(_ready)) return false;
        if (_ready && (!all_connected() || (role=="host" && !loadout_host_level_ready))) {
            status=role=="host" && !loadout_host_level_ready ? "请房主重新选择关卡" : "等待队友连接后再准备";
            return false;
        }
        var _p=request("set_loadout",{preparation_id:preparation.id,revision:preparation_revision,deck:_deck,ready:_ready});
        loadout_attempt=coop_clone(_p);
        loadout_attempt_view=coop_clone(preparation);
        loadout_attempt_profile=coop_campaign_progress(json_stringify(global.save_data));
        if (!_retry) loadout_retry_count=0;
        loadout_request_id=_p.request_id; loadout_pending=true; loadout_draft=coop_clone(_deck);
        status=_ready ? "正在确认准备…" : "正在保存你的选卡…";
        return transport.send(_p);
    };
    static cancel_preparation = function() {
        if (role!="host" || !connected || !is_struct(preparation) || loadout_pending || room_status=="running") return false;
        var _p=request("cancel_preparation",{preparation_id:preparation.id,revision:preparation_revision});
        loadout_request_id=_p.request_id; loadout_pending=true; loadout_changing_level=true;
        status="正在取消准备，返回选关…";
        return transport.send(_p);
    };
    static both_loadouts_ready = function() {
        if (!all_connected() || !is_struct(preparation) || loadout_pending || loadout_changing_level) return false;
        var _selections=coop_get(preparation,"selections");
        for (var _i=0;_i<array_length(players);_i++) {
            var _s=coop_get(_selections,players[_i].player_id);
            if (!coop_get(_s,"ready",false) || array_length(coop_get(_s,"deck",[]))<1) return false;
        }
        return true;
    };
    static loadout_choices_unchanged = function(_before) {
        if (!is_struct(_before) || !is_struct(preparation) || _before.id!=preparation.id
            || _before.level_id!=preparation.level_id || _before.slot_limit!=preparation.slot_limit
            || loadout_attempt_profile!=coop_campaign_progress(json_stringify(global.save_data))) return false;
        for (var _i=0;_i<array_length(players);_i++) {
            var _id=players[_i].player_id;
            var _a=coop_get(coop_get(coop_get(_before,"selections"),_id),"deck",[]);
            var _b=coop_get(coop_get(coop_get(preparation,"selections"),_id),"deck",[]);
            if (json_stringify(_a)!=json_stringify(_b)) return false;
        }
        return true;
    };
    static launch_prepared_battle = function() {
        if (role!="host" || !coop_get(match_config,"per_player_loadouts",false)) return false;
        if (!restore_host_level(coop_get(match_config,"preparation_id",""),coop_get(match_config,"level_id",""))) {
            status="关卡准备数据缺失，请重新选关"; return false;
        }
        if (!coop_loadout_launch_host()) { status="选卡数据无法加载，请重新选关"; return false; }
        return true;
    };
    static remember = function() {
        if (resume_token == "") return false;
        saved_session = {url:url, public_url:public_url, room_id:room_id, player_id:player_id,
            role:role, resume_token:resume_token, result_request:result_request,
            campaign_request:campaign_request, campaign_pending_json:campaign_pending_json,
            host_level_context:host_level_context};
        outbox_durable = coop_write_json("coop/session.json", saved_session);
        if (!outbox_durable) status = "合作存档未能写入磁盘，请检查空间后重试";
        return outbox_durable;
    };
    static flush_outbox = function() {
        if (!is_struct(result_request) && !is_struct(campaign_request)) return true;
        if (!outbox_durable && !remember()) return false;
        if (!connected) return false;
        return transport.send(is_struct(result_request) ? result_request : campaign_request);
    };
    static reset_entry = function() {
        // Starting another room must never reuse the preceding room's credentials.
        transport.close();
        coop_screen_reset(); shared_screen_supported=false;
        connected=false; resume_token=""; room_id=""; player_id=""; role="";
        players=[]; match_id=""; room_status="lobby"; battle_started=false; start_request_id="";
        seq=0; snapshot_tick=0; applied_command_id=0; inputs_pending=[];
        result_request=undefined; campaign_request=undefined; outbox_durable=true;
        campaign_pending_json=""; campaign_json=""; result_saved=false; result_outcome="";
        latest=undefined; previous=undefined; invite_code=""; retry_at=0; reconnect_attempt=0;
        preparation=undefined; preparation_revision=-1; match_config={}; loadout_draft=[];
        loadout_pending=false; loadout_request_id=""; preparation_request=undefined; preparation_queued=undefined;
        loadout_changing_level=false; loadout_host_level_ready=false; host_level_context=undefined;
        personal_loadouts_supported=false; loadout_start_retry_at=0;
        loadout_attempt=undefined; loadout_attempt_view=undefined; loadout_attempt_profile=""; loadout_retry_count=0;
    };
    static preserve_solo = function() {
        if (is_struct(solo) && active) return true;
        if (!save_file(global.save_slot)) { status = "单人存档保存失败，请先处理后再联机"; return false; }
        solo = {data:coop_clone(global.save_data), slot:global.save_slot, name:global.player_name,
            total_time:global.total_time, last_json:global.save_last_json, last_progress:global.save_last_progress,
            ready:global.save_ready, loaded_slot:global.loaded_save_slot};
        return true;
    };
    static set_campaign = function(_profile) {
        if (!save_data_valid(_profile)) { status = "服务器存档格式不兼容"; return false; }
        global.save_data = coop_clone(_profile);
        global.player_name = global.save_data.player.name;
        global.total_time = global.save_data.player.total_time;
        global.save_last_progress = save_progress_json();
        campaign_json = json_stringify(global.save_data);
        campaign_committed_at = current_time;
        return true;
    };
    static profiles = function() {
        var _p = {};
        for (var _i = 0; _i < array_length(players); _i++) variable_struct_set(_p, players[_i].player_id, coop_clone(global.save_data));
        return _p;
    };
    static connect_transport = function() {
        var _ok=transport.connect(url);
        // DNS/socket failures can happen synchronously, before any async event.
        if (!_ok) event(transport.last_event);
        return _ok;
    };
    static create = function() {
        if (active) return false;
        host_config = coop_read_json("coop/host.json");
        if (!is_struct(host_config) || coop_get(host_config, "token", "") == "") { status = "请先启动这台 Mac 上的合作服务器"; return false; }
        if (!preserve_solo()) return false;
        reset_entry();
        entry = "create"; entry_data = host_config;
        url = coop_get(host_config, "url", "ws://127.0.0.1:8765/game");
        public_url = coop_get(host_config, "public_url", url);
        status = "正在连接本机服务器…";
        leaving = false;
        return connect_transport();
    };
    static join = function(_code) {
        if (active) return false;
        var _d;
        try {
            if (string_copy(_code, 1, 5) != "FVM1:") throw "bad code";
            _d = json_parse(base64_decode(string_delete(_code, 1, 5)));
            var _parse = coop_transport_parse_url(_d.url);
            if (!_parse.ok || !is_string(_d.room_id) || !is_string(_d.invite_token)) throw "bad code";
            // Invitations may use plaintext only on the same machine for development.
            if (!_parse.secure && _parse.host != "127.0.0.1" && _parse.host != "localhost") throw "TLS required";
        } catch (_error) { status = "邀请码无效，请复制完整的 FVM1: 邀请码"; return false; }
        if (coop_get(saved_session,"role","") == "guest" && coop_get(saved_session,"room_id","") == _d.room_id
            && is_string(coop_get(saved_session,"resume_token")) && saved_session.resume_token != "") {
            // A consumed invitation can still carry a new tunnel address. Only the
            // existing guest's local resume credential grants entry to that room.
            saved_session.url = _d.url; saved_session.public_url = _d.url;
            if (!coop_write_json("coop/session.json",saved_session)) {
                status = "新房间地址未能保存，请检查磁盘空间"; return false;
            }
            return resume();
        }
        if (_d.invite_token == "") { status = "这是旧队友的重连地址，请向房主索取新的完整邀请码"; return false; }
        if (!preserve_solo()) return false;
        reset_entry();
        entry = "join"; entry_data = _d; url = _d.url; public_url = url;
        status = "正在连接队友的 Mac…"; leaving = false;
        return connect_transport();
    };
    static resume = function() {
        if (active) return false;
        var _s = saved_session;
        if (!is_struct(_s) || !is_string(coop_get(_s,"resume_token")) || _s.resume_token == ""
            || !is_string(coop_get(_s,"room_id")) || !is_string(coop_get(_s,"player_id"))
            || !is_string(coop_get(_s,"url")) || (coop_get(_s,"role","") != "host" && coop_get(_s,"role","") != "guest")) {
            status = "没有可以重连的房间"; return false;
        }
        var _parsed = coop_transport_parse_url(_s.url);
        if (!_parsed.ok || (!_parsed.secure && _parsed.host != "127.0.0.1" && _parsed.host != "localhost")) {
            status = "房间地址无效或缺少安全连接"; return false;
        }
        if (!preserve_solo()) return false;
        reset_entry();
        entry = "resume"; entry_data = saved_session;
        room_id = saved_session.room_id; player_id = saved_session.player_id;
        role = saved_session.role; resume_token = saved_session.resume_token;
        url = saved_session.url; public_url = coop_get(saved_session,"public_url",url);
        if (role == "host") {
            host_config = coop_read_json("coop/host.json");
            public_url = coop_get(host_config,"public_url",public_url);
        }
        result_request = coop_get(saved_session,"result_request",undefined);
        result_outcome = coop_get(coop_get(result_request,"result"),"outcome","");
        campaign_request = coop_get(saved_session,"campaign_request",undefined);
        campaign_pending_json = coop_get(saved_session,"campaign_pending_json","");
        host_level_context = coop_get(saved_session,"host_level_context",undefined);
        status = "正在恢复合作房间…"; leaving = false;
        return connect_transport();
    };
    static network_lost = function() {
        connected = false;
        coop_screen_reset();
        // Server state is authoritative after reconnect. Never replay Ready or
        // an old selection onto a possibly different preparation automatically.
        loadout_pending=false; loadout_request_id=""; loadout_attempt=undefined;
        preparation_request=undefined; preparation_queued=undefined;
        loadout_changing_level=false; start_request_id="";
        if (leaving) return;
        status = active ? "连接中断，战斗已暂停，正在重连…" : "暂时无法连接，正在重试房间地址…";
        retry_at = current_time + min(1000 * power(2,reconnect_attempt),10000);
        reconnect_attempt++;
    };
    static event = function(_e) {
        if (!is_struct(_e)) return;
        if (_e.kind == "connected") {
            if (resume_token != "" && active) send("resume",{room_id:room_id,resume_token:resume_token});
            else if (entry == "create") send("auth_host",{token:entry_data.token});
            else if (entry == "join") send("join_room",{room_id:entry_data.room_id,invite_token:entry_data.invite_token,name:global.player_name});
            else if (entry == "resume") send("resume",{room_id:room_id,resume_token:resume_token});
            return;
        }
        if (_e.kind == "disconnected" || (_e.kind == "error" && _e.fatal)) { network_lost(); return; }
        if (_e.kind == "message") packet(_e.data);
    };
    static update_state = function(_s, _initial = false) {
        if (!is_struct(_s)) return;
        players = coop_get(_s,"players",players);
        room_status = coop_get(_s,"room_status",room_status);
        personal_loadouts_supported=coop_get(coop_get(_s,"features"),"personal_loadouts",false);
        shared_screen_supported=coop_get(coop_get(_s,"features"),"shared_screen",false);
        match_config=coop_clone(coop_get(_s,"config",{}));
        var _level=coop_get(_s,"level_id","");
        if (is_string(_level)) match_config.level_id=_level;
        sync_preparation(coop_get(_s,"preparation"),_initial);
        var _screen=coop_get(_s,"shared_screen");
        if (role=="guest" && room_status!="running" && !is_struct(preparation) && is_struct(_screen)) {
            battle_started=false;
            if (coop_screen_receive(_screen)) { latest=undefined; previous=undefined; }
        }
        else coop_screen_reset();
        var _m = coop_get(_s,"match_id","");
        match_id = is_string(_m) ? _m : "";
        for (var _i = 0; _i < array_length(players); _i++) {
            if (players[_i].player_id == player_id) {
                seq = max(seq,players[_i].last_seq);
                if (_initial || role == "guest") set_campaign(players[_i].profile);
            }
        }
        var _cp = coop_get(_s,"checkpoint");
        if (role == "guest") {
            battle_started = room_status == "running";
            if (is_struct(_cp)) receive_snapshot(_cp.state);
            var _result = coop_get(_s,"result");
            if (room_status == "finished" && is_struct(_result)) {
                result_saved = true; result_outcome = coop_get(_result,"outcome","");
            }
        }
        if (role == "host" && battle_started) {
            var _commands = coop_get(_s,"pending_commands",[]);
            for (var _i = 0; _i < array_length(_commands); _i++) apply_command(_commands[_i]);
            if (coop_get(_s,"pending_commands_more",false)) send("get_state",{after_command_id:applied_command_id});
        }
    };
    static packet = function(_p) {
        if (!is_struct(_p)) return;
        var _kind = coop_get(_p,"type","");
        switch (_kind) {
        case "host_authenticated":
            send("create_room",{profile:solo.data,name:"双人合作冒险",player_name:global.player_name});
            break;
        case "room_created": case "room_joined": case "resumed":
            var _was_active = active;
            role = coop_get(_p,"role",_kind == "room_created" ? "host" : role);
            if (_kind == "room_joined") role = "guest";
            room_id = _p.room_id; player_id = _p.player_id;
            resume_token = coop_get(_p,"resume_token",resume_token);
            active = true; connected = true; reconnect_attempt = 0; retry_at = 0;
            update_state(_p.state,!_was_active);
            // On process restart the durable request may contain newer progress than
            // the server response (including a result committed before its lost ACK).
            if (!_was_active && role == "host") {
                var _pending = is_struct(result_request) ? result_request : campaign_request;
                var _pending_profiles = coop_get(_pending,"profiles");
                var _pending_profile = coop_get(_pending_profiles,player_id);
                if (is_struct(_pending_profile)) set_campaign(_pending_profile);
            }
            if (variable_struct_exists(_p,"invite_token")) make_invite(_p.invite_token);
            if (_kind == "resumed" && role == "host" && array_length(players) == 1) send("refresh_invite");
            status = all_connected() ? "两位玩家已连接，可以选择关卡" : "房间已就绪，等待队友加入";
            if (!_was_active) global.gui_stack.to(room_coop);
            // Persist credentials and the exact request before any durable operation.
            remember();
            flush_outbox();
            // A restarted host cannot resume a live simulation from render snapshots.
            // Settle an interrupted match once, retaining the last committed campaign.
            if (role == "host" && room_status == "running" && !battle_started && !is_struct(result_request)) {
                if (instance_exists(obj_battle)) {
                    // The start ACK was lost, but the original simulation still exists.
                    battle_started = true; coop_battle_ready();
                } else if (!is_struct(coop_get(_p.state,"checkpoint"))
                    && coop_get(match_config,"per_player_loadouts",false)
                    && restore_host_level(coop_get(match_config,"preparation_id",""),coop_get(match_config,"level_id",""))) {
                    // start_match committed but its ACK was lost before entering
                    // the battle. No snapshot means no simulation is being restored.
                    battle_started=true;
                    if (!launch_prepared_battle()) { battle_started=false; submit_result("defeat"); }
                } else {
                    submit_result("defeat");
                    status = "上局因主机退出结束，已恢复最近的共同进度";
                }
            }
            for (var _i = 0; _i < array_length(inputs_pending); _i++) transport.send(inputs_pending[_i]);
            remember();
            break;
        case "invite_created": case "room_invite": make_invite(_p.invite_token); break;
        case "player_joined": case "player_connected": case "player_disconnected": case "state":
            update_state(_p.state);
            status = all_connected() ? "两位玩家已连接" : "等待队友连接，战斗暂停";
            break;
        case "loadout_state":
            var _loadout_ack=coop_get(_p,"request_id","")==loadout_request_id;
            var _changing=loadout_changing_level && _loadout_ack;
            if (_loadout_ack) { loadout_pending=false; loadout_request_id=""; }
            update_state(_p.state);
            if (_loadout_ack) { preparation_request=undefined; loadout_attempt=undefined; }
            if (_changing && !is_struct(preparation)) {
                loadout_changing_level=false; loadout_host_level_ready=false;
                global.gui_stack.to(room_menu); status="请选择下一关";
            } else status=both_loadouts_ready() ? "双方已准备，正在开始…" : "分别选择卡牌，然后点击准备";
            break;
        case "match_started":
            coop_screen_reset();
            var _new_match = match_id != _p.match_id || !battle_started;
            update_state(_p.state);
            match_id = _p.match_id; room_status = "running";
            if (_new_match) { seq = 0; applied_command_id = 0; snapshot_tick = 0; inputs_pending = []; }
            result_saved = false; result_request = undefined; result_outcome = "";
            battle_started = true;
            start_request_id="";
            if (role == "host") {
                if (instance_exists(obj_battle)) coop_battle_ready();
                else if (!launch_prepared_battle()) { battle_started=false; submit_result("defeat"); break; }
            }
            if (role == "guest") global.gui_stack.to(room_coop);
            status = "先分别放置自己的角色，再共同布阵";
            remember();
            break;
        case "command": apply_command(_p); break;
        case "input_ack":
            for (var _i = array_length(inputs_pending)-1; _i >= 0; _i--) if (inputs_pending[_i].seq == _p.seq) array_delete(inputs_pending,_i,1);
            break;
        case "snapshot": if (_p.match_id == match_id) receive_snapshot(_p.state); break;
        case "screen_frame":
            if (role=="guest" && room_status!="running" && !is_struct(preparation)) {
                // A validated menu frame means the host has left the result
                // screen. Follow it without requiring a guest-side extra click.
                var _was_battle=battle_started; battle_started=false;
                if (coop_screen_receive(_p)) { latest=undefined; previous=undefined; }
                else battle_started=_was_battle;
            }
            break;
        case "screen_frame_ack": coop_screen_ack(_p); break;
        case "screen_cleared": coop_screen_reset(); break;
        case "campaign_updated":
            if (role == "guest") {
                var _updated = coop_get(coop_get(_p,"profiles"),player_id);
                var _profile = coop_get(_updated,"profile");
                if (is_struct(_profile)) set_campaign(_profile);
            }
            break;
        case "campaign_saved":
            if (is_struct(campaign_request) && coop_get(_p,"request_id","") == campaign_request.request_id) {
                campaign_json = campaign_pending_json; campaign_request = undefined; campaign_committed_at = current_time;
                status = "共同进度已保存到主机"; remember();
            }
            if (is_struct(coop_get(_p,"state"))) update_state(_p.state);
            break;
        case "match_result_ack":
            if (_p.match_id == match_id && _p.committed) {
                result_saved = true; room_status = "finished";
                var _committed = coop_get(coop_get(_p,"profiles"),player_id);
                var _profile = coop_get(_committed,"profile");
                if (is_struct(_profile)) campaign_json = json_stringify(_profile);
                else if (is_struct(result_request)) campaign_json = json_stringify(coop_get(result_request.profiles,player_id,global.save_data));
                result_request = undefined; campaign_committed_at = current_time;
                status = "通关数据已保存到主机"; remember();
            }
            break;
        case "match_finished":
            if (_p.match_id != match_id) break;
            result_saved = true; room_status = "finished"; result_outcome = _p.result.outcome;
            if (role == "guest" && variable_struct_exists(_p.profiles,player_id)) set_campaign(variable_struct_get(_p.profiles,player_id).profile);
            status = "战斗结果和共同进度已保存到主机";
            break;
        case "error":
            var _code = coop_get(_p,"code","");
            var _request_id=coop_get(_p,"request_id","");
            var _retry_edit=undefined;
            if (loadout_request_id!="" && _request_id==loadout_request_id) {
                if (_code=="preparation_conflict" && is_struct(loadout_attempt)) _retry_edit=loadout_attempt;
                loadout_pending=false; loadout_request_id=""; loadout_changing_level=false;
                preparation_request=undefined; preparation_queued=undefined;
            }
            if (is_struct(coop_get(_p,"state"))) update_state(_p.state);
            if (start_request_id != "" && coop_get(_p,"request_id","") == start_request_id
                && variable_global_exists("coop_battle") && is_struct(global.coop_battle)
                && coop_get(global.coop_battle,"start_requested",false) && !battle_started) {
                global.coop_battle.start_requested = false;
            }
            if (start_request_id!="" && _request_id==start_request_id) {
                start_request_id=""; loadout_start_retry_at=current_time+1000;
                if (!is_struct(coop_get(_p,"state"))) send("get_state");
            }
            status = "联机提示：" + string(coop_get(_p,"message",_code));
            if (is_struct(_retry_edit) && is_struct(preparation)
                && _retry_edit.preparation_id==preparation.id && loadout_retry_count<3) {
                loadout_retry_count++;
                // Simultaneous Ready clicks can retry against a newer revision
                // only when neither choices nor library changed in the meantime.
                var _still_approved=_retry_edit.ready && loadout_choices_unchanged(loadout_attempt_view);
                set_loadout(_retry_edit.deck,_still_approved,true);
            }
            if (_code == "unauthorized" || _code == "invite_invalid" || _code == "resume_invalid"
                || _code == "room_not_found" || _code == "room_unavailable" || _code == "room_full") {
                leaving = true; retry_at = 0; transport.close(); connected = false;
            }
            break;
        }
    };
    static copy_invite = function() {
        if (!active || role != "host") return "";
        host_config = coop_read_json("coop/host.json");
        public_url = coop_get(host_config,"public_url",public_url);
        var _token = "";
        if (array_length(players) < 2 && invite_code != "") {
            try { _token = coop_get(json_parse(base64_decode(string_delete(invite_code,1,5))),"invite_token",""); }
            catch (_error) { _token = ""; }
        }
        make_invite(_token);
        clipboard_set_text(invite_code);
        status = array_length(players) < 2 ? "邀请码已复制，请发给队友" : "最新房间地址已复制，队友可用它恢复连接";
        return invite_code;
    };
    static make_invite = function(_token) {
        invite_code = "FVM1:" + base64_encode(json_stringify({url:public_url,room_id:room_id,invite_token:_token}));
    };
    static apply_command = function(_p) {
        if (role != "host" || !battle_started || _p.match_id != match_id || _p.command_id <= applied_command_id) return;
        coop_battle_command(_p);
        applied_command_id = _p.command_id;
        if (variable_global_exists("coop_battle") && is_struct(global.coop_battle)) global.coop_battle.snapshot_requested = true;
    };
    static send_input = function(_action,_payload) {
        if (!active || !connected || !battle_started || room_status != "running") return false;
        seq++;
        var _p = request("input",{match_id:match_id,seq:seq,action:_action,payload:_payload});
        array_push(inputs_pending,_p);
        return transport.send(_p);
    };
    static start_battle = function(_level_id) {
        if (role != "host" || !all_connected()) { status = "需要两位玩家在线才能开始"; return false; }
        if (room_status == "running") return false;
        if (!both_loadouts_ready() || !loadout_host_level_ready || preparation.level_id!=_level_id) {
            status="请双方分别选卡并点击准备"; return false;
        }
        if (start_request_id!="") return true;
        if (is_struct(result_request) || is_struct(campaign_request)) {
            status = "请等待共同进度保存完成后开始"; flush_outbox(); return false;
        }
        if (!save_campaign() || is_struct(campaign_request)) {
            status = "正在保存共同进度，请稍后开始"; return false;
        }
        battle_started = false;
        var _request = request("start_match",{level_id:_level_id,preparation_id:preparation.id,revision:preparation_revision,
            config:{shared_campaign:true,client_version:global.game_version}});
        start_request_id = _request.request_id;
        return transport.send(_request);
    };
    static send_snapshot = function(_state) {
        if (!connected || role != "host" || !battle_started || room_status != "running") return false;
        snapshot_tick++;
        return send("snapshot",{match_id:match_id,tick:snapshot_tick,applied_command_id:applied_command_id,state:_state});
    };
    static receive_snapshot = function(_state) {
        previous = latest; latest = _state; received_at = current_time;
    };
    static save_campaign = function() {
        if (role != "host") return true;
        global.save_last_progress = save_progress_json(); global.save_last_check_time = current_time;
        if (room_status == "running") return true;
        var _j = json_stringify(global.save_data);
        if (_j == campaign_json) return true;
        // The play timer changes every Step. It must not continually enqueue
        // new transactions and prevent start_match from ever reaching its ACK.
        if (coop_campaign_progress(_j)==coop_campaign_progress(campaign_json)
            && current_time-campaign_committed_at<30000) return true;
        if (is_struct(campaign_request)) return outbox_durable || remember();
        campaign_pending_json = _j;
        campaign_request = request("save_campaign",{profiles:profiles()});
        if (!remember()) return false;
        status = "正在保存共同进度…";
        flush_outbox();
        return true;
    };
    static submit_result = function(_outcome) {
        if (role != "host" || match_id == "" || result_saved) return false;
        if (!is_struct(result_request)) {
            result_outcome = _outcome;
            result_request = request("match_result",{match_id:match_id,result:{outcome:_outcome},profiles:profiles()});
            // Keep the exact, idempotent result until SQLite durability is acknowledged.
            if (!remember()) return false;
        }
        if (!outbox_durable && !remember()) return false;
        status = "正在保存战斗结果…";
        return flush_outbox();
    };
    static tick = function() {
        event(transport.tick());
        // send() may also fail synchronously; consume its fatal event once.
        if (transport.state=="error" && retry_at==0 && !leaving && is_struct(transport.last_event)) event(transport.last_event);
        if (retry_at > 0 && current_time >= retry_at && !leaving) {
            retry_at = 0;
            if (resume_token != "") { entry = "resume"; entry_data = saved_session; }
            connect_transport();
        }
        if (connected && current_time-last_ping >= 5000) { last_ping=current_time; send("ping"); }
        if (connected && role=="host") {
            if (is_struct(preparation_queued)) flush_preparation();
            if (room_status!="running" && !battle_started && both_loadouts_ready()
                && loadout_host_level_ready && current_time>=loadout_start_retry_at) start_battle(preparation.level_id);
        }
        if (active && role == "host" && current_time-last_campaign_check >= 2000) {
            last_campaign_check=current_time;
            if (is_struct(result_request) || is_struct(campaign_request)) flush_outbox();
            else save_campaign();
        }
        if (active && role == "host" && instance_exists(obj_battle)) {
            coop_battle_tick();
            if (global.game_over && instance_exists(obj_game_over) && obj_game_over.sprite_index == spr_lose) submit_result("defeat");
        }
    };
    static leave = function() {
        if (active && role == "host") {
            if (room_status == "running") submit_result("defeat"); else save_campaign();
            if (is_struct(result_request) || is_struct(campaign_request)) { status = "正在等待主机确认存档，请稍后再退出"; return false; }
        }
        leaving=true; send("leave"); transport.close(); connected=false; active=false;
        coop_screen_reset(); shared_screen_supported=false;
        if (is_struct(solo)) {
            global.save_data=solo.data; global.save_slot=solo.slot; global.player_name=solo.name; global.total_time=solo.total_time;
            global.save_last_json=solo.last_json; global.save_last_progress=solo.last_progress;
            global.save_ready=solo.ready; global.loaded_save_slot=solo.loaded_slot; solo=undefined;
        }
        resume_token=""; battle_started=false; latest=undefined;
        preparation=undefined; match_config={}; loadout_draft=[]; loadout_pending=false;
        loadout_request_id=""; preparation_request=undefined; preparation_queued=undefined;
        loadout_changing_level=false; loadout_host_level_ready=false; host_level_context=undefined;
        global.gui_stack.to(room_menu);
        status="已返回单人模式";
        return true;
    };
}
