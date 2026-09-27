# Local two-player co-op service (protocol 1)

This Python service stores co-op rooms, two player identities, campaign profiles,
input commands, checkpoints and match results on the host Mac. The host GameMaker
client runs the authoritative battle simulation; the guest sends permitted inputs
and renders host snapshots. Co-op shares campaign progress and the host's unlocked
card library. Each player selects a separate deck and controls an avatar, with
independent card cooldowns and flame balances. Both must confirm their decks before
the host can start a match.
Both identities have separate persisted profile rows, even when their shared
campaign snapshots are identical. Existing single-player save files are untouched.

Update both game clients and the installed service together. The wire envelope
remains protocol 1, and new state replies advertise
`features.personal_loadouts:true` and `features.shared_screen:true`. The new client requires the loadout feature; the new
server rejects the old direct `start_match` flow. Updating the checkout does not
update the installed LaunchAgent service; rerun `manage.py install` after ending
the current session, as described below.

## Run on the host Mac

Python 3.11+ is required. The tested environment is Python 3.13.1, SQLite 3.51.1
and the pinned `websockets==15.0.1` package. From the repository root:

```sh
server/setup.sh
server/.venv/bin/python server/test_server.py
server/run.sh
```

`FVM_PYTHON=/opt/homebrew/bin/python3 server/setup.sh` chooses a particular Python.
The service listens **only on `127.0.0.1:8765`**; there is no public bind option.
`--port 0` chooses an ephemeral test port. Startup prints one JSON readiness line
containing the actual port. Stop with Ctrl-C. It does not install a background job.

`server/serverdata/` and `server/.venv/` are ignored by Git. By default, persistent
data is `server/serverdata/coop.sqlite3`; `--data-dir PATH` changes its location.
The directory is mode `0700`, database/token/backups are `0600`. Never put this
directory into a public web root or copy its credentials into a shareable invite.

The game host configuration is generated separately, after the game's actual
`save_directory` is known:

```sh
server/.venv/bin/python server/configure_host.py \
  --game-data-dir '/absolute/GameMaker/save_directory' \
  --url ws://127.0.0.1:8765/game \
  --public-url wss://your-game-endpoint.example/game
```

This atomically writes `coop/host.json` with `{url, public_url, token}`, permissions
`0600`; the secret is never printed. `--public-url` is optional and does not create
or configure a tunnel. `setup.sh` also accepts these same configuration arguments.
Only the host needs this file. A guest receives the public URL, room ID and one-use
invitation; it must never receive the host admin credential.

## Transport and authentication

Use standard UTF-8 JSON **text WebSocket frames**, without the GameMaker packet
header. GameMaker uses `network_connect_raw_async` and
`network_send_raw(..., network_send_text)`. Connect to `/game` exactly. All requests
have `{v:1, type:"...", request_id:"...", ...}`. Replies repeat `request_id`; events
omit it. Every message has `v:1`. Integer-valued JSON numbers such as `1.0` from
GameMaker are accepted; booleans, fractional values and non-finite values are not.
Use a random session prefix plus a counter for request IDs. Retry a campaign
transaction or preparation operation with the **same ID**; never reuse that ID
for a different operation, including after reconnecting or restarting a client.

Authenticate within 5 seconds using exactly one of these first messages:

| Request | Reply |
| --- | --- |
| `auth_host {token}` | `host_authenticated` |
| `join_room {room_id,invite_token,name?}` | `room_joined {room_id,player_id,role:"guest",resume_token,state}` |
| `resume {room_id,resume_token}` | `resumed {room_id,player_id,role,state}` |

The host token is randomly generated in `serverdata/host-token`, persists across
restarts and is local administrator authority. The room host's resume credential
can manage its existing room but cannot create another room or request backups.
Invite and resume tokens are cryptographically random; SQLite contains only their
SHA-256 hashes. An invitation expires after 600 seconds by default and is consumed
by one successful join. `--invite-ttl` can set 1 second to 1 hour (fractions are
accepted for tests). A room has at most one host and one guest. A consumed guest
seat cannot be replaced by another invitation. Resume credentials survive process
restarts; the newest connection replaces the previous connection for that identity.

After `auth_host`, send:

```json
{"v":1,"type":"create_room","request_id":"session-a:1","name":"Our campaign","player_name":"Host","profile":{"player":{"name":"Host","total_time":0},"unlocked_cards":[{"id":"small_fire","level":1,"shape":0},{"id":"toast_bread","level":1,"shape":0}],"unlocked_items":{"max_slot":2}}}
```

Reply: `room_created {room_id,player_id,role:"host",resume_token,invite_token,
invite_expires_at,state}`. The guest's initial profile is copied from the host's
shared campaign profile when joining. Store each device's resume token privately.
This abbreviated profile illustrates the server's library fields; the game sends
its complete save data so that game-side validation and campaign rules can run.

## Room and campaign operations

| Request | Reply / behavior |
| --- | --- |
| `get_state {after_command_id?}` | `state {state}` |
| `ping {}` | `pong {server_time}`; use application heartbeats to detect lost GameMaker connections |
| `leave {}` | `left`, then closes the connection; progress and seat persist |
| Host `refresh_invite {}` | `invite_created {room_id,invite_token,invite_expires_at}`; only before the guest seat is occupied |
| Host `save_campaign {profiles,revisions?}` | `campaign_saved {committed:true,duplicate,profiles,state}`; commits outside an active match only |
| Host `prepare_match {level_id,level_name?,slot_limit}` | `loadout_state {state,duplicate}`; opens a new preparation for the room's two members |
| Either player `set_loadout {preparation_id,revision,deck,ready}` | `loadout_state {state,duplicate}`; edits only the sender's selection |
| Host `cancel_preparation {preparation_id,revision}` | `loadout_state {state,duplicate}` with `state.preparation:null` |
| Host `start_match {level_id,preparation_id,revision,config?:{}}` | `match_started {match_id,state,duplicate}`; requires both players connected and ready |
| Host `screen_frame {seq,room,width,height,encoding,image,title?}` | `screen_frame_ack {seq,accepted,duplicate,dropped?}`; volatile menu image, outside preparation/battle only |
| Host `screen_clear {}` | `screen_cleared {room_id,stream_id}`; clears cached/pending menu images in any phase; guest gets the same event without request ID |
| Local admin `backup {}` | `backup_created {filename}` |

`new_invite` is an alias returning `room_invite`. `profiles` in requests maps every
current room player ID to that player's complete authoritative campaign snapshot.
The host is responsible for game-rule validation. Guest profile writes are
forbidden. An optional `revisions` map in `save_campaign` must contain every player
ID and its expected revision; a stale revision returns `revision_conflict` without
writing anything. The response's `profiles` maps IDs to `{profile,revision}`.

Campaign saves atomically update every supplied profile and persist request-ID
deduplication before acknowledging. Replaying the same transaction returns its
original committed response with `duplicate:true`. Reusing that ID with a different
payload returns `request_conflict`. Guest receives `campaign_updated {profiles}`.
Actual campaign changes clear both ready flags and refresh valid cards/slot limits
in any active preparation, increment its revision, and broadcast `loadout_state`.
Changes only to `player.total_time` preserve readiness. Campaign saves remain
available while preparing because preparation does not change `room_status`.

## Individual loadouts and mutual readiness

The host's authoritative profile defines the shared library through
`unlocked_cards:[{id,level,shape,...}]` and the per-player slot limit through
`unlocked_items.max_slot` (protocol bound 1–31). `prepare_match.slot_limit` is
validated but never overrides the authoritative limit. Both room members must
already exist. A preparation is stored durably and returned by `get_state`:

```json
{
  "id":"PREPARATION_ID","level_id":"1-1","level_name":"First level",
  "slot_limit":2,"revision":1,
  "selections":{
    "HOST_PLAYER_ID":{"deck":["small_fire"],"ready":false,"cached":true},
    "GUEST_PLAYER_ID":{"deck":["toast_bread"],"ready":false,"cached":true}
  }
}
```

Each accepted `set_loadout` validates an ordered array of unique, unlocked card ID
strings. An unready deck may be empty; a ready deck requires 1–`slot_limit` cards.
The two players may select the same card. Every accepted edit saves that player's
deck under the room, player and level, and increments the shared preparation
revision. Changing a deck clears both ready flags before applying the sender's
explicit `ready` value. The game sends `ready:false` while editing, then a separate
confirmation with `ready:true`.

`set_loadout`, `cancel_preparation` and `start_match` require the current
`preparation_id` and `revision`. An old ID returns `stale_preparation`; an old
revision returns `preparation_conflict`. Both errors include current `state`.
Concurrent confirmations can therefore require a retry against the new revision.
The client must not restore a previous ready confirmation if either player's deck,
the level, slot limit or campaign library has changed.

On a new preparation, each player's last deck for this level is restored; if there
is no level-specific cache, their most recently edited deck is used. Unavailable
cards are filtered and the restored list is clamped to the current slot limit.
`cached:true` indicates a restored cache, including one filtered to an empty deck.
Ready flags are never restored. Disconnect, connection takeover and server restart
clear both players' ready flags and advance the revision, retaining the decks.

Preparation changes and their request-ID receipts commit in the same transaction.
A duplicate accepted request returns current state with `duplicate:true` without
reapplying an old edit, cancellation or preparation. Changed data under the same
ID returns `request_conflict`. A duplicate accepted start returns the same match
while it remains the room's current match, including after a server restart; an
older match's start receipt returns `stale_preparation`.

The server never starts automatically. `start_match` additionally requires the
prepared level, two connected players, two ready flags and two valid nonempty
decks. It freezes these server-owned config fields, ignoring supplied overrides:

```json
{
  "level_id":"1-1","preparation_id":"PREPARATION_ID",
  "loadouts":{"HOST_PLAYER_ID":["small_fire"],"GUEST_PLAYER_ID":["toast_bread"]},
  "per_player_loadouts":true,"flame_ratio":0.6,"shared_campaign":true
}
```

Start persists a new `match_id`, resets input sequences, and clears the active
preparation. It does not mutate campaign profiles. Clients should omit the legacy
`profiles` field; if supplied, it must equal the stored profiles except play time,
otherwise `profiles_changed` is returned. Campaign mutations go through
`save_campaign` before preparing. After a match, a new preparation restores cached
decks and requires fresh confirmation from both players.

The game host enforces individual card ownership, cooldowns and spending. Each
player gets `floor(value * 0.6)` of the level's initial flame and each collected
flame award, capped at 15,000 per player. Spending affects the acting player's
balance. Other campaign resources, unlocks and rewards remain shared.

## Battle commands

Both host and guest submit:

```json
{"v":1,"type":"input","request_id":"session-b:9","match_id":"MATCH_ID","seq":1,"action":"place_card","payload":{"row":2,"col":3,"card_id":"toast_bread","slot_index":1}}
```

The server returns `input_ack {seq,command_id,duplicate}` **after** committing the
command. A new command emits `command {match_id,player_id,seq,command_id,action,
payload}` to the host only. The host validates resources, card ownership, cooldowns,
terrain and turn/battle state, then applies it exactly once. Persisted commands
record attempted input, not a promise that the host's game rules will accept it.
The guest never mutates authoritative battle state directly.

| Action | Required payload | Optional payload |
| --- | --- | --- |
| `place_player` | `row,col` | — |
| `place_card` | `row,col,card_id` | `slot_index,shape,deck_slot` |
| `shovel` | `row,col` | — |
| `use_gem` | `gem_index` | `row,col,gem_id` |
| `pause_vote` | `paused` (boolean) | — |

Rows are `0..63`, columns `0..127`, slot/gem indices `0..31`, shape `0..32`.
`deck_slot` is a compatibility alias accepted as an optional field; the game
integration uses the owner's **1-based** `slot_index` from the snapshot, while
`gem_index` is zero-based. Coordinates are logical grid cells; host
simulation translates moving-platform coordinates using its own authoritative
platform offset. IDs match `[A-Za-z0-9_.:-]{1,80}`. Unknown fields/actions are rejected.

Sequence numbers are independent per player and match, start at `1` and increase
by exactly one. Repeating the same sequence with identical action/payload returns
the existing command ID and does not broadcast or execute it again. Changed data
returns `sequence_conflict`, skipped sequences `sequence_gap`. A match permits at
most 100,000 commands and a sequence is at most 2,147,483,647. Inputs are rejected
while the host is disconnected. The host must pause simulation while either player
is disconnected and the guest must display a waiting state.

## Shared menu images

The host may share only `room_menu`, `room_map`, `room_tower_cake` and
`room_laboratory`, while the room is `lobby` or `finished` and has no preparation.
The co-op lobby containing invitation controls, the loadout screen and battle are
not eligible. The game captures its own render surface, not the desktop, and the
guest views it without remote input control. Frames never write campaign data.

`screen_frame` uses a positive integer `seq`, dimensions up to 960×540,
`encoding:"jpeg"` or `"png"`, and raw base64 `image` (no data-URI prefix, at most
700 KiB of encoded text). The optional title is at most 160 characters. The service
validates image format headers and dimensions, and accepts at most four frames per
second. A guest receives `screen_frame` with those fields plus `stream_id`, a new
identifier for each host connection. Deduplicate by `(stream_id,seq)` because the
host sequence may restart after reconnecting. Same-sequence identical retries are
acknowledged without rebroadcast; changed content returns `screen_conflict`.
Older or over-rate frames return `accepted:false` with `dropped:"out_of_order"`
or `"rate_limited"`, respectively.

`state.shared_screen` is the latest accepted image or null. This cache holds at
most 32 recent rooms in memory, supports guest reconnection and is lost on server
restart. Preparing or starting a match clears it. When leaving a shared menu for
the private co-op lobby, the host sends `screen_clear`. This clears the room cache
and pending menu frame, then sends a reliable `screen_cleared` event behind any
already in-flight image. Thus an old image cannot arrive after its clear event.
Only the room host may clear; it is allowed in every room phase and changes no
profile, preparation, ready state or battle checkpoint. The host ACK repeats its
request ID. A client/server update is needed to use this explicit clear message.

## Snapshots, results and recovery

Host snapshot:

```json
{"v":1,"type":"snapshot","request_id":"session-a:20","match_id":"MATCH_ID","tick":120,"applied_command_id":3,"state":{"entities":[],"hud":{"flame":100}},"durable":false}
```

Reply: `snapshot_ack {tick,persisted,duplicate}`; guest event:
`snapshot {match_id,tick,applied_command_id,state}`. Ticks increase, and the highest
contiguously applied command ID cannot move backwards. The command must belong to
the current match or be zero. Identical repeated snapshots are idempotent. A
`state` object is opaque to the service; the host must include enough simulation
state for any recovery it promises. A rendering-only snapshot cannot restore a
complete host simulation after the game itself crashes.

The current game snapshot includes `per_player_loadouts:true`,
`balances:{player_id:flame}`, and `slots` with an `owner` player ID and that owner's
1-based `slot_index`. The guest filters slots and reads the balance by its own
identity. The top-level legacy `flame` field remains the host's balance.

The game schedules ordinary battle snapshots at approximately 33 ms intervals
(about 30 Hz), sends confirmed inputs on the next game step, and advertises
`snapshot_interval_ms` for guest interpolation. This is a scheduling interval,
not an end-to-end network latency guarantee. The first snapshot is durable, subsequent updates
are cached in memory and flushed at most approximately every second during normal
streaming. `durable:true` requests an immediate SQLite commit. The ack's
`persisted:true` means that snapshot is on disk; `false` means only memory/broadcast.
The latest cache is used for reconnect/get_state, and flushed on disconnect and
graceful server shutdown. After abrupt server termination, at most approximately
one second of the visual checkpoint stream can be lost; every acknowledged input,
campaign save and match result remains committed independently.

Ordinary battle snapshots and menu images share a bounded visual sender: at most
one frame is in flight and one newer pending frame replaces any older pending
frame. Reliable messages use the same send lock. Terminal `game_over` snapshots
are reliable; preparation, match start and match result transitions discard stale
pending visuals. A direct defeat result without a terminal image also clears old
battle frames. Input commands are committed before being forwarded to the host,
and that forwarding precedes waiting for a slow guest's ACK write. These changes
retain SQLite FULL durability and bound stale-frame backlog under backpressure.

Host result:

```json
{"v":1,"type":"match_result","request_id":"session-a:30","match_id":"MATCH_ID","result":{"outcome":"victory","rewards":{"coins":50}},"profiles":{"HOST_PLAYER_ID":{"coins":150},"GUEST_PLAYER_ID":{"coins":150}}}
```

`outcome` is `victory` or `defeat`. The service commits **both profiles, their
revisions, the unique match result and finished status in one SQLite transaction**,
then returns `match_result_ack {match_id,committed:true,duplicate,profiles}`. It
broadcasts `match_finished {match_id,result,profiles}` to both players. Retrying the
same match result, even after a restart or a later match, returns the original
committed profiles with `duplicate:true` and never reapplies rewards. Conflicting
data returns `result_conflict`. On storage failure the client receives no success
ack and should retry the same payload; tests inject failure during the second
player's update to verify that the first player's update also rolls back.

State has this exact shape:

```json
{
  "room_id":"ROOM_ID","name":"Our campaign","room_status":"running",
  "match_id":"MATCH_ID","level_id":"1-1","config":{},
  "players":[{"player_id":"PLAYER_ID","role":"host","name":"Host","profile":{},"revision":1,"last_seq":0,"connected":true}],
  "checkpoint":{"tick":120,"applied_command_id":3,"state":{}},
  "pending_commands":[],"pending_commands_more":false,"result":null,
  "features":{"personal_loadouts":true,"shared_screen":true},"preparation":null,"shared_screen":null
}
```

`room_status` is `lobby`, `running` or `finished`; `match_id`, `level_id`,
`checkpoint`, `result` and `preparation` can be null. Preparation is separate from
the prior match's `level_id` and `config`; use `preparation.level_id` when selecting
the next level. It is cleared during a running match. `pending_commands` are commands after the
checkpoint's applied ID, or after explicitly requested `after_command_id`, ordered
by command ID. Each has the same fields as a `command` event. Pages hold at most
256; use the last command ID as the next cursor when `pending_commands_more` is
true. Restore the checkpoint before replaying pending commands, and deduplicate
the live command stream against the last applied command ID.

`player_joined`, `player_connected` and `player_disconnected` events include
`{player_id,state}` with current `players[].connected` flags. The guest also gets
`match_started {match_id,state}`. Resume provides current state and the player's
last accepted sequence, so the next new input is `last_seq+1`.

## Security, durability and operational limits

Only `/game` offers a WebSocket. Plain HTTP there returns 426. `/health` returns
only `{"ok":true,"protocol":1}`; all other paths return 404. There is no static
file server, arbitrary file operation, remote shell or host desktop endpoint.
Inputs are JSON data, never executable code. Errors are
`{v:1,type:"error",request_id?,code,message}`; server tracebacks and credentials
are not sent to clients.

Incoming frames are limited to 1 MiB, profiles to 256 KiB each, snapshot state to
768 KiB, JSON depth to 32, and config to 16 KiB. Client receivers should allow
**4 MiB** to accommodate both profiles and a checkpoint in one state reply. At
most 32 connections exist concurrently. Each connection has a 120-message burst
and 60 messages/second refill rate. The server does not initiate RFC WebSocket
control PING frames: the tested GameMaker LTS 2026 runner replies with an unmasked
control PONG, correctly rejected as protocol error 1002. Standard masking and
frame validation remain enabled. Instead, clients send JSON `ping` every five
seconds and expect JSON `pong`; authenticated connections are closed with code
1008 after 30 seconds without an incoming application message (`--idle-timeout`
can adjust this up to 120 seconds). The initial authentication deadline remains
five seconds. This keeps silent clients from occupying connection slots without
triggering the runner's control-frame interoperability bug.

SQLite uses WAL, `synchronous=FULL`, and macOS `fullfsync=ON`. Backup uses the
SQLite online backup API, not a copy of a live database file. A snapshot is made
every five minutes (configure `--backup-every`, zero disables the schedule), on
admin request and on clean shutdown. The most recent 48 generated backups are
retained under `serverdata/backups/`; they remain on this Mac. To restore, stop the
service, preserve the existing database/WAL/SHM files, then restore a checked backup
as `coop.sqlite3` without stale WAL/SHM files. The `host-token` file is separate and
must also be retained privately when moving the service.

The standalone `run.sh` does not deploy public access. The optional macOS manager
below adds an outbound WSS reverse proxy to this loopback service. The reverse proxy
supplies trusted TLS; plain `ws://` is only suitable for loopback testing.
Remote use requires the host Mac, game and service to remain available. Invitation
tokens are bearer credentials and should be shared only with the invited player.
The server trusts authenticated host simulation; it does not independently verify
game balance or prevent a host administrator from changing their own database.

The 23 server integration tests exercise real socket clients, authorization, one-use/expired invitations,
role restrictions, sequence deduplication, snapshots, presence/resume, forced
process restart, durable campaign writes, duplicate results, transaction rollback,
safe HTTP routes, frame limits, consistent backups, application heartbeats and
silent authenticated-client expiry. New cases also cover authoritative card/slot
validation, readiness and revision conflicts, independent level caches and last
deck fallback, disconnect/takeover/restart invalidation, immutable match config,
duplicate start receipts across restarts, transaction rollback of edits and their
receipts, campaign changes versus play time, and additive migration of existing
rooms. The schema adds preparation/cache/receipt tables and advances to version 2
without replacing profiles, rooms, matches or credentials. Streaming cases cover
image authorization/format/dimensions/rate, volatile reconnect caching, preparation
and battle isolation, controlled slow socket writes, latest-frame replacement,
input delivery before a held ACK, final result ordering, and explicit screen clear
without changing game state or restoring stale images after reconnect.

The new protocol has also passed 38/38 checks from a real native GameMaker client
and 122/122 `CoopSession` native checks using isolated projects and databases.
The native loadout UI has passed 23/23 checks and shared-screen/codec fixtures
27/27. Two isolated full-game clients on one Mac have passed 52/52 local WS checks,
including actual menu/map/laboratory image sharing and battle settlement. Final
public WSS full-game regression for this revision is still in progress; these
checks do not establish two-machine or all-level gameplay acceptance.

## Optional Mac login service and free external connectivity

This is an explicit opt-in installation. It does not ask for administrator access,
change firewall rules, publish any files or enable SSH/desktop access. The installed
HTTP service still has only `/game` and the minimal `/health` endpoint; other paths
return an error. Cloudflared connects outward and uses encrypted HTTP/2 to Cloudflare.
Its management diagnostic routes are disabled and its metrics listener is loopback.

```sh
server/.venv/bin/python server/manage.py install \
  --game-data-dir '/absolute/GameMaker/save_directory'
server/.venv/bin/python server/manage.py status
server/.venv/bin/python server/manage.py stop
server/.venv/bin/python server/manage.py start
```

`install` copies the required Python files into
`~/Library/Application Support/FVM-Reborn/co-op/service`, creates an isolated venv
there, installs the pinned dependency, and starts the user LaunchAgent
`io.github.9tempest.fvmreborn.coop`. The database, token, backups, runtime logs and
status JSON live in `~/Library/Application Support/FVM-Reborn/co-op`, outside Git.
The background service does not depend on the source checkout continuing to exist.
Re-running `install` safely stops the old service, updates code and starts it again;
existing co-op data and credentials are retained.

The installer accepts `--cloudflared /absolute/path` for an existing installation.
Otherwise it installs the official Cloudflare macOS binary, release `2026.9.3`,
into the private application data directory and verifies the archive SHA-256
against the official GitHub release metadata before running it. Cloudflare's
documented Homebrew alternative is `brew install cloudflared`; this Mac's Homebrew
has no compatible bottle, so the checksum-verified official download is used.
No Cloudflare account, domain purchase or paid plan is created.

On every launcher start, a new free Quick Tunnel domain is obtained and the game's
`coop/host.json` is atomically updated with the current `wss://.../game` public URL.
The launcher supervises both child processes and reconnects after an exit. Each
restart may change the domain; clients must refresh the host configuration before
copying invitations. Room IDs and private resume credentials remain valid against
the same local database. Existing client sessions must reconnect to the new URL.
While reconnecting/stopped, the public URL is cleared to avoid advertising a dead
endpoint. Private tokens are never written to logs or status output.

The service automatically starts **after this macOS user logs in**, while enabled.
It can operate only while this Mac is awake, online and running the host game.
It does not prevent sleep or alter power settings. `stop` stops the service and
disables automatic login startup; `start` re-enables it. `uninstall` removes the
LaunchAgent but deliberately preserves the database/backups. Logs rotate at 2 MiB
with three older files retained. `status` shows the public URL without credentials.

Quick Tunnels are a free first-version connectivity/testing option, **not a
permanent address or an uptime guarantee**. Cloudflare documents a 200-concurrent-
request cap and no Server-Sent Events support; this game uses WebSockets. A stable
named tunnel is a later option requiring explicit account/domain setup. No such
setup is performed here.

Official operational references:
[Quick Tunnel limits](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/),
[Cloudflare macOS installation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/),
[official release](https://github.com/cloudflare/cloudflared/releases/tag/2026.9.3).

Primary API references: [Python sqlite3 backup](https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.backup),
[SQLite synchronous](https://sqlite.org/pragma.html#pragma_synchronous),
[websockets asyncio server](https://websockets.readthedocs.io/en/stable/reference/asyncio/server.html),
[GameMaker raw network send](https://manual.gamemaker.io/lts/en/GameMaker_Language/GML_Reference/Networking/network_send_raw.htm).
