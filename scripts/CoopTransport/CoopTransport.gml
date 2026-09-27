/// Standard JSON-over-WebSocket transport for the native GameMaker VM.
/// Forward Async Networking (Other_68) to handle_event(async_load), call tick()
/// from Step, and close() when the owning controller is destroyed.
function coop_transport_parse_url(_url) {
    if (!is_string(_url)) return {ok:false, error:"URL must be a string"};
    var _secure = string_lower(string_copy(_url, 1, 6)) == "wss://";
    var _plain = string_lower(string_copy(_url, 1, 5)) == "ws://";
    if (!_secure && !_plain) return {ok:false, error:"Use a ws:// or wss:// URL"};
    if (string_pos("#", _url) > 0 || string_pos(" ", _url) > 0
        || string_pos(chr(9), _url) > 0 || string_pos(chr(10), _url) > 0
        || string_pos(chr(13), _url) > 0) return {ok:false, error:"Invalid WebSocket URL"};
    var _rest = string_delete(_url, 1, _secure ? 6 : 5);
    var _split = string_pos("/", _rest);
    var _query = string_pos("?", _rest);
    if (_query > 0 && (_split == 0 || _query < _split)) _split = _query;
    var _authority = _split > 0 ? string_copy(_rest, 1, _split - 1) : _rest;
    var _path = _split > 0 ? string_delete(_rest, 1, _split - 1) : "/";
    if (string_copy(_path, 1, 1) == "?") _path = "/" + _path;
    if (_authority == "" || string_pos("@", _authority) > 0) return {ok:false, error:"A host without URL credentials is required"};
    var _host = _authority;
    var _port_text = "";
    if (string_copy(_authority, 1, 1) == "[") {
        var _end = string_pos("]", _authority);
        if (_end < 3) return {ok:false, error:"Invalid IPv6 host"};
        _host = string_copy(_authority, 1, _end);
        var _tail = string_delete(_authority, 1, _end);
        if (_tail != "") {
            if (string_copy(_tail, 1, 1) != ":") return {ok:false, error:"Invalid port"};
            _port_text = string_delete(_tail, 1, 1);
            if (_port_text == "") return {ok:false, error:"Invalid port"};
        }
    } else {
        var _colon = string_pos(":", _authority);
        if (_colon > 0) {
            _host = string_copy(_authority, 1, _colon - 1);
            _port_text = string_delete(_authority, 1, _colon);
            if (_port_text == "" || string_pos(":", _port_text) > 0) return {ok:false, error:"IPv6 hosts must use brackets"};
        }
    }
    if (_host == "") return {ok:false, error:"Host is required"};
    var _port = _secure ? 443 : 80;
    if (_port_text != "") {
        for (var _i = 1; _i <= string_length(_port_text); _i++) {
            var _digit = ord(string_char_at(_port_text, _i));
            if (_digit < 48 || _digit > 57) return {ok:false, error:"Port must contain digits"};
        }
        _port = real(_port_text);
        if (_port < 1 || _port > 65535) return {ok:false, error:"Port is out of range"};
    }
    // Port has its own native API argument; retain the full path and query.
    return {ok:true, secure:_secure, host:_host, port:_port, path:_path,
        connect_url:(_secure ? "wss://" : "ws://") + _host + _path};
}

function CoopTransport(_on_event = undefined) constructor {
    socket = -1;
    state = "closed";
    url = "";
    last_error = "";
    last_event = undefined;
    last_received = 0;
    last_sent = 0;
    last_send_bytes = 0;
    connect_started = 0;
    connect_timeout_ms = 15000;
    // Enable after the session starts its application-level ping/pong loop.
    idle_timeout_ms = 0;
    max_message_bytes = 4194304;
    on_event = _on_event;

    static _emit = function(_event) {
        last_event = _event;
        if (is_callable(on_event)) on_event(_event);
        return _event;
    };
    static _destroy_socket = function() {
        var _old_socket = socket;
        socket = -1;
        if (_old_socket >= 0) network_destroy(_old_socket);
        return _old_socket;
    };
    static _error = function(_code, _message, _fatal = false) {
        last_error = _message;
        var _event_socket = socket;
        if (_fatal) {
            _destroy_socket();
            state = "error";
        }
        return _emit({kind:"error", code:_code, message:_message, fatal:_fatal, socket:_event_socket});
    };
    static close = function(_reason = "client_close") {
        var _old_socket = _destroy_socket();
        state = "closed";
        if (_old_socket < 0) return undefined;
        return _emit({kind:"disconnected", reason:_reason, socket:_old_socket});
    };
    static connect = function(_url) {
        var _parsed = coop_transport_parse_url(_url);
        if (!_parsed.ok) {
            _error("invalid_url", _parsed.error);
            return false;
        }
        if (socket >= 0) close("reconnect");
        url = _url;
        last_error = "";
        socket = network_create_socket(_parsed.secure ? network_socket_wss : network_socket_ws);
        if (socket < 0) {
            state = "error";
            _error("socket_failed", "Could not create a WebSocket");
            return false;
        }
        state = "connecting";
        connect_started = current_time;
        var _result = network_connect_raw_async(socket, _parsed.connect_url, _parsed.port);
        if (_result < 0) {
            _error("connect_failed", "Could not start the WebSocket connection", true);
            return false;
        }
        return true;
    };
    static send = function(_message) {
        if (state != "open" || socket < 0) return false;
        var _text;
        try {
            if (is_string(_message)) {
                // Caller-supplied JSON must still be validated.
                _text = _message; json_parse(_text);
            } else {
                // GameMaker's serializer already produces valid JSON. Parsing
                // the entire snapshot again adds work to every outgoing frame.
                _text = json_stringify(_message);
            }
        } catch (_parse_error) {
            _error("invalid_json", "Outgoing message must be valid JSON");
            return false;
        }
        var _size = string_byte_length(_text);
        if (_size < 1 || _size > max_message_bytes) {
            _error("message_size", "Outgoing message exceeds the configured size limit");
            return false;
        }
        var _buffer = buffer_create(_size, buffer_fixed, 1);
        buffer_write(_buffer, buffer_text, _text);
        // buffer_text adds no NUL terminator; this is a standard UTF-8 text frame.
        var _sent = network_send_raw(socket, _buffer, _size, network_send_text);
        buffer_delete(_buffer);
        last_send_bytes = _sent;
        if (_sent < 0) {
            _error("send_failed", "WebSocket send failed", true);
            return false;
        }
        last_sent = current_time;
        return true;
    };
    static tick = function() {
        if (state == "connecting" && current_time - connect_started >= connect_timeout_ms) {
            return _error("connect_timeout", "WebSocket connection timed out", true);
        }
        if (state == "open" && idle_timeout_ms > 0 && current_time - last_received >= idle_timeout_ms) {
            // Some native runners do not deliver client-side disconnect events.
            // The owner must send application heartbeats so silence is meaningful.
            return _error("activity_timeout", "No WebSocket message arrived before the activity deadline", true);
        }
        return undefined;
    };
    static handle_event = function(_map) {
        if (socket < 0 || !ds_map_exists(_map, "type")) return undefined;
        var _event_id = ds_map_exists(_map, "id") ? _map[? "id"] : -1;
        var _event_socket = ds_map_exists(_map, "socket") ? _map[? "socket"] : -1;
        if (_event_id != socket && _event_socket != socket) return undefined;
        var _type = _map[? "type"];
        if (_type == network_type_non_blocking_connect || _type == network_type_connect) {
            if (ds_map_exists(_map, "succeeded") && _map[? "succeeded"] != 1) {
                return _error("connect_failed", "WebSocket connection was refused or timed out", true);
            }
            if (state == "open") return undefined;
            state = "open";
            last_received = current_time;
            return _emit({kind:"connected", socket:socket});
        }
        if (_type == network_type_disconnect || _type == network_type_down) {
            var _old_socket = _destroy_socket();
            state = "closed";
            return _emit({kind:"disconnected", reason:"remote_close", socket:_old_socket});
        }
        if (_type == network_type_up_failed) return _error("network_failed", "The network connection failed", true);
        if (_type != network_type_data) return undefined;
        if (!ds_map_exists(_map, "buffer") || !ds_map_exists(_map, "size")) return _error("invalid_frame", "WebSocket event has no data buffer");
        if (ds_map_exists(_map, "message_type") && _map[? "message_type"] != network_send_text) {
            return _error("binary_frame", "Expected a JSON text frame");
        }
        var _size = _map[? "size"];
        var _source = _map[? "buffer"];
        if (_size < 1 || _size > max_message_bytes || _size > buffer_get_size(_source)) {
            return _error("message_size", "Incoming message exceeds the configured size limit");
        }
        // async_load and its buffer belong to GameMaker and expire after this
        // event. Copy exactly size bytes into a terminated temporary buffer.
        var _copy = buffer_create(_size + 1, buffer_fixed, 1);
        buffer_copy(_source, 0, _size, _copy, 0);
        buffer_poke(_copy, _size, buffer_u8, 0);
        var _text = buffer_read(_copy, buffer_string);
        buffer_delete(_copy);
        var _data;
        try {
            if (string_byte_length(_text) != _size) throw "Unexpected NUL in frame";
            _data = json_parse(_text);
        } catch (_parse_error) {
            return _error("invalid_json", "Incoming frame is not valid JSON");
        }
        last_received = current_time;
        return _emit({kind:"message", data:_data, text:_text, size:_size, socket:socket});
    };
}
