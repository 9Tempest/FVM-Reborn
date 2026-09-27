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

Trusted public WSS was also verified with the native runner and the actual `CoopSession`: **10/10 assertions passed** against a Cloudflare HTTPS tunnel. This checked TLS handshakes, standard JSON text, unauthenticated-request rejection, invalid-token rejection, stopped retries, and preservation of solo state. The test creates no room and uses no valid credential. Cloudflare Quick Tunnel addresses change after service restarts, so pass the currently running endpoint:

```sh
python3 tools/macos/test-coop-wss.py --url 'wss://current-host/game'
```

For the complete echo suite over TLS, forward a trusted WSS endpoint to a chosen local echo port and use `test-coop-transport.py --echo-port PORT --url 'wss://host/game?transport_test=1'`. The full echo suite has been exercised on local WS; the separate public WSS suite covers TLS and authentication rejection without modifying production game data.

## Real server and session tests

```sh
python3 -m venv "$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv"
"$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv/bin/python" -m pip install -r server/requirements.txt
"$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv/bin/python" tools/macos/test-coop-server.py
"$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv/bin/python" tools/macos/test-coop-session.py
```

The real-server test runs two native transport sockets against an immutable copy of the repository's Python server, a loopback listener, a disposable host token, and a separate SQLite database. It passed **28/28 assertions** for host/guest admission, input sequence handling and deduplication, checkpoints, result commits and retries, and guest resume. The post-run SQLite checks verify that retries created only one input and one result, both synthetic profiles received the reward once, and the checkpoint was durable.

The session test compiles the actual `CoopSession` and `CoopTransport`. It passed **59/59 assertions** covering method binding, native file round trips, durable campaign/result outboxes, disk-write failure, restart recovery without progress rollback, ACKs arriving after newer local changes, separate solo progress, guest checkpoints and campaign updates, address-only reconnect codes, lost start ACK recovery, synchronous DNS/send failures with a single scheduled retry, and a complete live host/guest protocol exchange followed by SQLite verification. Save validation, UI, and battle callbacks are small fixture stubs. Only the temporary test source receives deterministic disk-failure and clipboard seams; the user's clipboard, installed app, real credentials, and real saves are untouched. This verifies networking/session behavior, not rendered battle gameplay.

Each run retains source hashes, logs, compiled test app, and JSON results in its own cache directory and uses a new dedicated test bundle identifier. The loopback server fixtures run against synthetic data; the public WSS fixture sends only requests that must be rejected before room membership.

## Native keepalive compatibility

On macOS 14.5 with runtime 2026.0.0.23, the native runner responds to RFC WebSocket control PING with an incorrectly masked control frame. Python `websockets` then rejects it with close code **1002, `incorrect masking`**. A 72-second native comparison reproduced the failure for both random binary and ASCII ping payloads at the first 20-second ping; the application-JSON-only connection stayed alive for more than 71 seconds. This is distinct from a keepalive timeout or an application background pause.

The server therefore keeps strict WebSocket frame validation but sets `ping_interval=None`. Authenticated connections must send valid application messages within the server's idle deadline (30 seconds by default); `CoopSession` sends JSON `ping` every five seconds and detects missing server responses after 15 seconds. Disabling control PING is a compatibility workaround, not permission to accept unmasked client frames.

A separate native stress fixture passed **20/20 assertions** with simultaneous local WS and public trusted WSS connections. It sent both 100 KiB and 1 MiB JSON payloads in both directions and held JSON heartbeats for at least 65 seconds within a 75-second test run. These sizes test transport framing; they do not change the production protocol's smaller profile/state/message limits.

```sh
"$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv/bin/python" tools/macos/test-coop-long.py

# Optional: use an installed official cloudflared to test the same fixture over WSS.
"$HOME/Library/Caches/FVM-Reborn/coop-server-test-venv/bin/python" tools/macos/test-coop-long.py \
  --cloudflared /absolute/path/to/cloudflared
```

The optional argument creates a temporary public tunnel to a test-only loopback service. It serves only synthetic messages, has no game database or file endpoint, and shuts down after the run. New Quick Tunnel domains may take time to resolve; the fixture waits for actual DNS and trusted TLS readiness before starting the native test timer. It does not change DNS settings, certificate checks, or the production tunnel.

## API references

- [GameMaker LTS networking and raw protocols](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/Networking.htm)
- [Asynchronous networking event and received-buffer lifetime](https://manual.gamemaker.io/lts/en/The_Asset_Editors/Object_Properties/Async_Events/Networking.htm)
- [Raw asynchronous connect](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/network_connect_raw_async.htm)
- [Raw text-frame send](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/network_send_raw.htm)

The signatures, `network_socket_wss`, `network_send_text`, `buffer_text`, and `ev_async_web_networking` were also checked against the installed runtime's `GmlSpec.xml`; event number 68 was verified in the running VM.
