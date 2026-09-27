# CoopTransport

Native GameMaker JSON text transport for standard WebSocket servers. This script uses `network_connect_raw_async` and `network_send_raw(..., network_send_text)` and never adds GameMaker's private packet header.

```gml
// Create: a persistent owner is recommended.
transport = new CoopTransport();
transport.connect("wss://your-server.example/game");

// Async Networking: eventType 7, eventNum 68, Other_68.gml.
var event = transport.handle_event(async_load);
if (!is_undefined(event)) {
    switch (event.kind) {
        case "connected":
            // Start the session's authentication/room protocol here.
            break;
        case "message":
            var packet = event.data;
            // Handle the decoded JSON object; event.text retains original JSON.
            break;
        case "disconnected":
        case "error":
            // Show connection state and schedule a session-level retry.
            break;
    }
}

// Step:
transport.tick();

// Send: an object/array or already-encoded, valid JSON text.
var accepted = transport.send({v:1, type:"ping", request_id:"heartbeat-1"});

// Cleanup / Game End:
transport.close();
```

`new CoopTransport(callback)` optionally invokes a callback for the same events returned by `handle_event`. Choose a callback or consume the returned event to avoid processing messages twice. Returned structs and strings remain valid after the asynchronous event. The original `async_load` map and received buffer remain owned by GameMaker; the transport copies the bytes and deletes only its temporary buffer.

The public state is `closed`, `connecting`, `open`, or `error`; `.socket` is `-1` when released. `connect(url)` and `send(packet)` return booleans. A successful send means the networking API accepted it, not that the server committed a game action. Use the protocol's acknowledgements for durable operations.

Events use `kind: "connected"`, `"message"`, `"disconnected"`, or `"error"`. Messages include `data`, `text`, `size`, and `socket`. Errors include `code`, `message`, `fatal`, and `socket`. Unrelated networking events return `undefined`. Explicit `close(reason)` emits `disconnected` when a socket existed.

`.connect_timeout_ms` defaults to 15000; `.max_message_bytes` defaults to 4 MiB. `.idle_timeout_ms` defaults to 0 (disabled). The session should send its defined `ping` messages regularly, check `pong`/other server responses, and enable `.idle_timeout_ms = 15000` after the heartbeat protocol is active. `tick()` reports fatal `activity_timeout` when no valid JSON message arrives in that interval. The verified macOS runner does not reliably raise client disconnect events when a remote server closes a WebSocket, and a send can still report acceptance after that closure; application heartbeats are necessary.

URL parsing preserves paths and queries, handles explicit ports and bracketed IPv6, and uses port 80 for `ws` and 443 for `wss`. Certificate validation is left to the native `wss` implementation; the transport does not disable it. JSON numbers from GameMaker may be encoded as `1.0`; servers should accept mathematically integral values where the protocol expects integer counters.

## Native VM integration test

The harness compiles a minimal project containing the actual transport and connects its isolated, sandboxed app to a Python standards-based echo server on loopback. It never launches the installed game or touches its saves.

```sh
python3 -m venv "$HOME/Library/Caches/FVM-Reborn/coop-transport-venv"
"$HOME/Library/Caches/FVM-Reborn/coop-transport-venv/bin/python" -m pip install 'websockets==16.0'
"$HOME/Library/Caches/FVM-Reborn/coop-transport-venv/bin/python" tools/macos/test-coop-transport.py
```

Requires the same installed runtime and signed-in account as `tools/macos/build.sh`; `FVM_GAMEMAKER_RUNTIME` and `FVM_GAMEMAKER_USER` are supported. Each run creates a unique test app identifier and retains its source hash, compiler/runtime logs, and JSON results under `~/Library/Caches/FVM-Reborn/coop-transport-tests/`.

Verified on macOS 14.5 / Apple Silicon / runtime 2026.0.0.23: 25 native assertions passed, including `Other_68`, `/game` plus query, Chinese and emoji, approximately 15 KiB messages, text frame format, malformed JSON/binary rejection, connection timeout, server-close detection by activity timeout, reconnect, and explicit cleanup.

**WSS over a trusted TLS connection has not yet been exercised.** Only WSS URL parsing is covered by the local run. To exercise TLS later, forward a trusted WSS endpoint to a chosen local echo port and run the harness with `--echo-port PORT --url 'wss://host/game?transport_test=1'`; its result separately records whether a trusted TLS endpoint was tested successfully.

## API references

- [GameMaker LTS networking and raw protocols](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/Networking.htm)
- [Asynchronous networking event and received-buffer lifetime](https://manual.gamemaker.io/lts/en/The_Asset_Editors/Object_Properties/Async_Events/Networking.htm)
- [Raw asynchronous connect](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/network_connect_raw_async.htm)
- [Raw text-frame send](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/network_send_raw.htm)

The signatures, `network_socket_wss`, `network_send_text`, `buffer_text`, and `ev_async_web_networking` were also checked against the installed runtime's `GmlSpec.xml`; event number 68 was verified in the running VM.
