#!/usr/bin/env python3
"""Loopback-only, two-player FVM co-op service. No game simulation runs here."""
import argparse
import asyncio
from dataclasses import dataclass, field
import hashlib
from http import HTTPStatus
import json
import logging
import os
from pathlib import Path
import secrets
import signal
import sqlite3
import time

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from protocol import (MAX_COMMANDS, MAX_MESSAGE, MAX_PROFILE, MAX_STATE, VERSION,
                      MAX_DECK, ProtocolError, campaign_progress, decode, encode,
                      identifier, input_payload, integer, json_object, loadout_deck,
                      require, screen_frame, SCREEN_INTERVAL, string)
from storage import Store, new_id, new_token, token_hash

LOG = logging.getLogger("fvm.coop")


@dataclass
class Client:
    socket: object
    authenticated: bool = False
    admin: bool = False
    room_id: str | None = None
    player_id: str | None = None
    role: str | None = None
    allowance: float = 120.0
    rate_updated: float = 0.0
    send_lock: object = field(default_factory=asyncio.Lock)
    pending_visual: object = None
    visual_task: object = None
    screen_seq: int = 0
    screen_digest: str = ""
    screen_next_at: float = 0.0
    screen_stream: str = field(default_factory=new_id)

    def rate_limit(self):
        now = time.monotonic()
        self.allowance = min(120.0, self.allowance + (now - self.rate_updated) * 60)
        self.rate_updated = now
        require(self.allowance >= 1, "rate_limited", "Message rate exceeded")
        self.allowance -= 1


class GameServer:
    def __init__(self, store, invite_ttl=600, auth_timeout=5, idle_timeout=30):
        self.store = store
        self.invite_ttl = invite_ttl
        self.auth_timeout = auth_timeout
        self.idle_timeout = idle_timeout
        self.clients = {}  # (room_id, player_id) -> authenticated live connection
        self.connections = set()
        self.live_checkpoints = {}
        self.checkpoint_written_at = {}
        self.checkpoint_written_tick = {}
        self.shared_screens = {}  # Volatile UI frames, never written to SQLite.
        self.store.reset_readiness()

    def state(self, client, after=None):
        connected = {player for (room, player) in self.clients if room == client.room_id}
        match_id = self.store.room(client.room_id)["match_id"]
        state = self.store.state(client.room_id, connected, after, self.live_checkpoints.get(match_id))
        state["features"]["shared_screen"] = True
        state["shared_screen"] = self.shared_screens.get(client.room_id) if self.screen_allowed(client.room_id) else None
        return state

    def screen_allowed(self, room_id):
        return self.store.room(room_id)["status"] in ("lobby", "finished") and self.store.preparation(room_id) is None

    def clear_screen(self, room_id):
        self.shared_screens.pop(room_id, None)
        for (room, _), client in self.clients.items():
            if room == room_id and client.pending_visual and client.pending_visual["type"] == "screen_frame":
                client.pending_visual = None

    async def send_message(self, client, message):
        # All sends share one lock so the final battle frame and later reliable
        # state transitions cannot be overtaken by a queued older visual frame.
        if message.get("type") in ("loadout_state", "match_started", "match_finished", "snapshot"):
            client.pending_visual = None
        async with client.send_lock:
            await asyncio.wait_for(client.socket.send(encode({"v": VERSION, **message})), 3)

    async def send_latest_visual(self, client):
        try:
            while client.pending_visual is not None:
                async with client.send_lock:
                    message, client.pending_visual = client.pending_visual, None
                    if message is None:
                        continue
                    if message["type"] == "screen_frame" and not self.screen_allowed(client.room_id):
                        continue
                    if message["type"] == "snapshot":
                        room = self.store.room(client.room_id)
                        if room["match_id"] != message["match_id"] or room["status"] != "running":
                            continue
                    await asyncio.wait_for(client.socket.send(encode({"v": VERSION, **message})), 3)
        except asyncio.TimeoutError:
            await client.socket.close(1013, "Client is not receiving game updates")
        except ConnectionClosed:
            pass
        finally:
            client.visual_task = None

    def queue_visual(self, client, message):
        # One frame in flight + one replaceable pending frame; never accumulate
        # an unbounded FIFO of outdated screenshots or battle snapshots.
        client.pending_visual = message
        if client.visual_task is None:
            client.visual_task = asyncio.create_task(self.send_latest_visual(client))

    def persisted_profiles(self, room_id):
        return {m["player_id"]: {"profile": json.loads(m["profile_json"]), "revision": m["revision"]}
                for m in self.store.members(room_id)}

    def flush_checkpoint(self, match_id, checkpoint=None):
        checkpoint = checkpoint or self.live_checkpoints.get(match_id)
        if checkpoint is None:
            return
        with self.store.transaction():
            self.store.db.execute("INSERT INTO checkpoints VALUES (?,?,?,?,?) ON CONFLICT(match_id) DO UPDATE SET tick=excluded.tick,applied_command_id=excluded.applied_command_id,state_json=excluded.state_json,updated_at=excluded.updated_at",
                                  (match_id,checkpoint["tick"],checkpoint["applied_command_id"],encode(checkpoint["state"]),time.time()))
        self.checkpoint_written_at[match_id] = time.monotonic()
        self.checkpoint_written_tick[match_id] = checkpoint["tick"]

    def flush_pending_checkpoints(self):
        for match_id, checkpoint in self.live_checkpoints.items():
            if self.checkpoint_written_tick.get(match_id) != checkpoint["tick"]:
                self.flush_checkpoint(match_id, checkpoint)

    async def attach(self, client, room_id, player_id, role):
        key = (room_id, player_id)
        previous = self.clients.get(key)
        with self.store.transaction():
            self.store.clear_ready(room_id)
        client.authenticated = True
        client.room_id, client.player_id, client.role = room_id, player_id, role
        self.clients[key] = client
        if previous and previous is not client:
            await previous.socket.close(4001, "Session resumed on another connection")

    async def broadcast(self, room_id, message, role=None, exclude=None):
        targets = [c for (room, _), c in self.clients.items()
                   if room == room_id and c is not exclude and (role is None or c.role == role)]
        ephemeral = message["type"] == "screen_frame" or (
            message["type"] == "snapshot" and not message["state"].get("game_over", False))
        if ephemeral:
            for client in targets:
                self.queue_visual(client, message)
            return
        async def send(client):
            try:
                await self.send_message(client, message)
            except asyncio.TimeoutError:
                await client.socket.close(1013, "Client is not receiving game updates")
        if targets:
            await asyncio.gather(*(send(c) for c in targets), return_exceptions=True)

    def require_member(self, client):
        require(client.room_id is not None, "room_required", "Join or create a room first")
        require(self.clients.get((client.room_id, client.player_id)) is client,
                "session_replaced", "This session has been replaced")

    def require_host(self, client):
        self.require_member(client)
        require(client.role == "host", "forbidden", "Only the room host may perform this action")

    def require_match(self, client, request, running=True):
        self.require_member(client)
        match_id = identifier(request.get("match_id"), "match_id")
        room = self.store.room(client.room_id)
        require(room["match_id"] == match_id, "match_mismatch", "This is not the room's current match")
        if running:
            require(room["status"] == "running", "match_not_running", "Match is not running")
        return match_id

    async def authenticate(self, client, request):
        kind = request["type"]
        if kind == "auth_host":
            token = string(request.get("token"), "token", 128)
            require(secrets.compare_digest(token, self.store.host_token), "unauthorized", "Invalid host credential")
            client.authenticated, client.admin = True, True
            return {"type": "host_authenticated"}, []
        if kind == "join_room":
            room_id = identifier(request.get("room_id"), "room_id")
            token = string(request.get("invite_token"), "invite_token", 128)
            name = string(request.get("name", "Guest"), "name", 48)
            player_id, resume = self.store.join_room(room_id, token, name)
            await self.attach(client, room_id, player_id, "guest")
            state = self.state(client)
            return {"type": "room_joined", "room_id": room_id, "player_id": player_id,
                    "role": "guest", "resume_token": resume, "state": state}, [
                        ({"type": "player_joined", "player_id": player_id, "state": state}, None, client)]
        if kind == "resume":
            room_id = identifier(request.get("room_id"), "room_id")
            member = self.store.resume(room_id, string(request.get("resume_token"), "resume_token", 128))
            await self.attach(client, room_id, member["player_id"], member["role"])
            state = self.state(client)
            return {"type": "resumed", "room_id": room_id, "player_id": client.player_id,
                    "role": client.role, "state": state}, [
                        ({"type": "player_connected", "player_id": client.player_id, "state": state}, None, client)]
        raise ProtocolError("authentication_required", "Authenticate as host, join with an invitation, or resume first")

    def validated_profiles(self, client, supplied, required=True):
        members = self.store.members(client.room_id)
        player_ids = {member["player_id"] for member in members}
        if supplied is None and not required:
            return {member["player_id"]: member["profile_json"] for member in members}
        require(isinstance(supplied, dict) and set(supplied) == player_ids,
                "invalid_profiles", "Supply exactly the room's two player profiles")
        return {player: json_object(profile, "profile", MAX_PROFILE) for player, profile in supplied.items()}

    def loadout_request(self, client, request):
        """All preparation edits and their retry receipts commit atomically."""
        kind, db = request["type"], self.store.db
        if kind != "set_loadout":
            self.require_host(client)
        json_object(request, "preparation request", MAX_MESSAGE)
        canonical = json.dumps(request, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        digest = hashlib.sha256(canonical.encode()).hexdigest()
        with self.store.transaction():
            previous = db.execute("SELECT * FROM preparation_requests WHERE room_id=? AND player_id=? AND request_id=?",
                                  (client.room_id,client.player_id,request["request_id"])).fetchone()
            if previous:
                require(previous["payload_hash"] == digest, "request_conflict", "Request ID was already used with different data")
                response = json.loads(previous["response_json"])
                if response["type"] == "match_started":
                    require(self.store.room(client.room_id)["match_id"] == response["match_id"],
                            "stale_preparation", "This request belongs to an older match")
                response["duplicate"] = True
                return {**response, "state": self.state(client)}, []
            room = self.store.room(client.room_id)
            require(room["status"] in ("lobby", "finished"), "match_already_running", "A match is already running")
            members = self.store.members(client.room_id)
            allowed, limit = self.store.library(client.room_id)
            if kind == "prepare_match":
                require(len(members) == 2, "players_not_ready", "Both room members must join first")
                level = identifier(request.get("level_id"), "level_id")
                level_name = string(request.get("level_name", level), "level_name", 160)
                integer(request.get("slot_limit"), "slot_limit", 1, MAX_DECK)
                selections = {}
                for member in members:
                    deck, cached = self.store.cached_deck(client.room_id, member["player_id"], level, allowed, limit)
                    selections[member["player_id"]] = {"deck": deck, "ready": False, "cached": cached}
                preparation = {"id": new_id(), "level_id": level, "level_name": level_name,
                               "slot_limit": limit, "selections": selections, "revision": 1}
                self.store.write_preparation(client.room_id, preparation)
                response = {"type": "loadout_state", "duplicate": False}
            else:
                preparation_id = identifier(request.get("preparation_id"), "preparation_id")
                preparation = self.store.preparation(client.room_id)
                require(preparation is not None and preparation["id"] == preparation_id,
                        "stale_preparation", "Reload the current preparation")
                revision = integer(request.get("revision"), "revision", 1)
                require(revision == preparation["revision"], "preparation_conflict", "Preparation changed; confirm the latest deck")
                if kind == "cancel_preparation":
                    db.execute("DELETE FROM preparations WHERE room_id=?", (client.room_id,))
                    response = {"type": "loadout_state", "duplicate": False}
                elif kind == "set_loadout":
                    ready = request.get("ready")
                    require(type(ready) is bool, "invalid_loadout", "ready must be boolean")
                    deck = loadout_deck(request.get("deck"), allowed, limit, ready)
                    selection = preparation["selections"][client.player_id]
                    if deck != selection["deck"]:
                        for value in preparation["selections"].values():
                            value["ready"] = False
                        selection["cached"] = False
                    selection.update(deck=deck, ready=ready)
                    preparation["revision"] += 1
                    self.store.cache_deck(client.room_id, client.player_id, preparation["level_id"], deck)
                    self.store.write_preparation(client.room_id, preparation)
                    response = {"type": "loadout_state", "duplicate": False}
                else:
                    require(len(members) == 2 and all((client.room_id,m["player_id"]) in self.clients for m in members),
                            "players_not_ready", "Both players must be connected")
                    level = identifier(request.get("level_id"), "level_id")
                    require(level == preparation["level_id"], "stale_preparation", "Prepared level does not match")
                    loadouts = {}
                    for member in members:
                        selection = preparation["selections"][member["player_id"]]
                        require(selection["ready"], "players_not_ready", "Both players must confirm their decks")
                        loadouts[member["player_id"]] = loadout_deck(selection["deck"], allowed, limit, True)
                    # Profile mutations belong to save_campaign, where they
                    # invalidate readiness. Never allow start to bypass it.
                    if "profiles" in request:
                        profiles = self.validated_profiles(client, request["profiles"])
                        require(all(campaign_progress(json.loads(profiles[m["player_id"]])) == campaign_progress(json.loads(m["profile_json"])) for m in members),
                                "profiles_changed", "Commit campaign changes before preparing a match")
                    json_object(request.get("config", {}), "config", 16384)
                    config = {**request.get("config", {}), "loadouts": loadouts,
                              "per_player_loadouts": True, "flame_ratio": 0.6,
                              "shared_campaign": True, "preparation_id": preparation_id,
                              "level_id": level}
                    config_json = json_object(config, "config", 16384)
                    match_id = new_id()
                    db.execute("INSERT INTO matches VALUES (?,?,?,?, 'running',?)", (match_id,client.room_id,level,config_json,time.time()))
                    db.execute("UPDATE rooms SET status='running',match_id=? WHERE room_id=?", (match_id,client.room_id))
                    db.execute("UPDATE members SET last_seq=0 WHERE room_id=?", (client.room_id,))
                    db.execute("DELETE FROM preparations WHERE room_id=?", (client.room_id,))
                    response = {"type": "match_started", "match_id": match_id, "duplicate": False}
            db.execute("INSERT INTO preparation_requests VALUES (?,?,?,?,?)",
                       (client.room_id,client.player_id,request["request_id"],digest,encode(response)))
        if kind in ("prepare_match", "start_match"):
            self.clear_screen(client.room_id)
        response["state"] = self.state(client)
        return response, [(response, None, client)]

    async def dispatch(self, client, request):
        if not client.authenticated:
            return await self.authenticate(client, request)
        kind = request["type"]
        if kind == "create_room":
            require(client.admin and client.room_id is None, "forbidden", "A local host session is required")
            profile = json_object(request.get("profile"), "profile", MAX_PROFILE)
            name = string(request.get("name", "FVM Co-op"), "name", 64)
            host_name = string(request.get("player_name", "Host"), "player_name", 48)
            room_id, player_id, resume, invite, expires = self.store.create_room(profile, name, host_name, self.invite_ttl)
            await self.attach(client, room_id, player_id, "host")
            return {"type": "room_created", "room_id": room_id, "player_id": player_id, "role": "host",
                    "resume_token": resume, "invite_token": invite, "invite_expires_at": expires,
                    "state": self.state(client)}, []
        if kind == "backup":
            require(client.admin, "forbidden", "Local host authentication is required for a backup")
            return {"type": "backup_created", "filename": self.store.backup()}, []
        self.require_member(client)
        if kind == "get_state":
            after = request.get("after_command_id")
            if after is not None: integer(after, "after_command_id")
            return {"type": "state", "state": self.state(client, after)}, []
        if kind == "ping":
            return {"type": "pong", "server_time": time.time()}, []
        if kind == "leave":
            return {"type": "left"}, []
        if kind == "screen_frame":
            self.require_host(client)
            require(self.screen_allowed(client.room_id), "screen_unavailable", "Screen sharing is paused for card selection or battle")
            seq = integer(request.get("seq"), "seq", 1)
            reply = {"type": "screen_frame_ack", "seq": seq, "accepted": False, "duplicate": False}
            if seq < client.screen_seq:
                return {**reply, "dropped": "out_of_order"}, []
            if seq > client.screen_seq and time.monotonic() < client.screen_next_at:
                return {**reply, "dropped": "rate_limited"}, []
            frame = screen_frame(request)
            digest = hashlib.sha256(encode(frame).encode()).hexdigest()
            if seq == client.screen_seq:
                require(digest == client.screen_digest, "screen_conflict", "Screen sequence was reused with different data")
                return {**reply, "accepted": True, "duplicate": True}, []
            frame["stream_id"] = client.screen_stream
            client.screen_seq, client.screen_digest = seq, digest
            client.screen_next_at = time.monotonic() + SCREEN_INTERVAL
            # Keep at most 32 recent room images (about 22 MiB encoded), including
            # disconnected rooms. Cache eviction never touches durable progress.
            self.shared_screens.pop(client.room_id, None)
            if len(self.shared_screens) >= 32:
                self.shared_screens.pop(next(iter(self.shared_screens)))
            self.shared_screens[client.room_id] = frame
            return {**reply, "accepted": True}, [({"type": "screen_frame", **frame}, "guest", None)]
        if kind in ("prepare_match", "set_loadout", "cancel_preparation", "start_match"):
            return self.loadout_request(client, request)
        if kind in ("new_invite", "refresh_invite"):
            self.require_host(client)
            require(len(self.store.members(client.room_id)) == 1, "room_full", "Room already has two players")
            token, expires = new_token(), time.time() + self.invite_ttl
            with self.store.transaction():
                self.store.db.execute("UPDATE rooms SET invite_hash=?,invite_expires_at=?,invite_used=0 WHERE room_id=?",
                                      (token_hash(token),expires,client.room_id))
            return {"type": "invite_created" if kind == "refresh_invite" else "room_invite", "room_id": client.room_id, "invite_token": token,
                    "invite_expires_at": expires}, []
        if kind == "save_campaign":
            self.require_host(client)
            profiles = self.validated_profiles(client, request.get("profiles"))
            revisions = request.get("revisions")
            if revisions is not None:
                require(isinstance(revisions, dict) and set(revisions) == set(profiles), "invalid_profiles", "Invalid profile revisions")
                for value in revisions.values(): integer(value, "revision", 1)
            canonical = json.dumps({"profiles": request["profiles"], "revisions": revisions}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            digest = hashlib.sha256(canonical.encode()).hexdigest()
            db = self.store.db
            with self.store.transaction():
                previous = db.execute("SELECT * FROM campaign_commits WHERE room_id=? AND request_id=?", (client.room_id,request["request_id"])).fetchone()
                if previous:
                    require(previous["payload_hash"] == digest, "request_conflict", "Request ID was already committed with different data")
                    reply = json.loads(previous["response_json"])
                    reply["duplicate"] = True
                else:
                    require(self.store.room(client.room_id)["status"] in ("lobby", "finished"), "match_running", "Save campaign outside an active match")
                    if revisions is not None:
                        require(all(revisions[m["player_id"]] == m["revision"] for m in self.store.members(client.room_id)), "revision_conflict", "Reload the latest profiles before saving")
                    changed = any(campaign_progress(json.loads(profiles[m["player_id"]])) != campaign_progress(json.loads(m["profile_json"]))
                                  for m in self.store.members(client.room_id))
                    for player, profile in profiles.items():
                        db.execute("UPDATE profiles SET profile_json=?,revision=revision+1,updated_at=? WHERE player_id=?", (profile,time.time(),player))
                    if changed:
                        self.store.clear_ready(client.room_id, refresh_library=True)
                    reply = {"type": "campaign_saved", "committed": True, "duplicate": False, "profiles": self.persisted_profiles(client.room_id)}
                    db.execute("INSERT INTO campaign_commits VALUES (?,?,?,?,?)", (client.room_id,request["request_id"],digest,encode(reply),time.time()))
            events = [] if reply["duplicate"] else [({"type": "campaign_updated", "profiles": reply["profiles"]}, "guest", None)]
            reply["state"] = self.state(client)
            if not reply["duplicate"] and reply["state"]["preparation"] is not None:
                events.append(({"type": "loadout_state", "state": reply["state"]}, None, client))
            return reply, events
        if kind == "input":
            match_id = self.require_match(client, request)
            seq = integer(request.get("seq"), "seq", 1)
            action = identifier(request.get("action"), "action")
            payload = input_payload(action, request.get("payload"))
            db = self.store.db
            with self.store.transaction():
                previous = db.execute("SELECT * FROM commands WHERE match_id=? AND player_id=? AND seq=?", (match_id,client.player_id,seq)).fetchone()
                if previous:
                    require(previous["action"] == action and json.loads(previous["payload_json"]) == request["payload"],
                            "sequence_conflict", "A sequence number cannot be reused for a different input")
                    command, duplicate = self.store.command_dict(previous), True
                else:
                    member = self.store.member(client.room_id, client.player_id)
                    require(seq == member["last_seq"] + 1, "sequence_gap", f"Expected seq {member['last_seq'] + 1}")
                    host = next(m for m in self.store.members(client.room_id) if m["role"] == "host")
                    require((client.room_id,host["player_id"]) in self.clients, "host_unavailable", "Wait for the host to reconnect")
                    count = db.execute("SELECT COUNT(*) FROM commands WHERE match_id=?", (match_id,)).fetchone()[0]
                    require(count < MAX_COMMANDS, "match_input_limit", "Match command limit reached")
                    command_id = db.execute("INSERT INTO commands(match_id,player_id,seq,action,payload_json,created_at) VALUES (?,?,?,?,?,?)",
                                            (match_id,client.player_id,seq,action,payload,time.time())).lastrowid
                    db.execute("UPDATE members SET last_seq=? WHERE room_id=? AND player_id=?", (seq,client.room_id,client.player_id))
                    command = {"match_id": match_id, "player_id": client.player_id, "seq": seq,
                               "command_id": command_id, "action": action, "payload": request["payload"]}
                    duplicate = False
            events = [] if duplicate else [({"type": "command", **command}, "host", None)]
            return {"type": "input_ack", "seq": seq, "command_id": command["command_id"], "duplicate": duplicate}, events
        if kind == "snapshot":
            self.require_host(client)
            match_id = self.require_match(client, request)
            tick = integer(request.get("tick"), "tick")
            applied = integer(request.get("applied_command_id"), "applied_command_id")
            json_object(request.get("state"), "state", MAX_STATE)
            durable = request.get("durable", False)
            require(type(durable) is bool, "invalid_message", "durable must be boolean")
            db = self.store.db
            previous = self.live_checkpoints.get(match_id)
            if previous is None:
                row = db.execute("SELECT * FROM checkpoints WHERE match_id=?", (match_id,)).fetchone()
                if row: previous = {"tick": row["tick"], "applied_command_id": row["applied_command_id"], "state": json.loads(row["state_json"])}
            checkpoint = {"tick": tick, "applied_command_id": applied, "state": request["state"]}
            duplicate = previous == checkpoint
            require(not previous or tick > previous["tick"] or duplicate, "snapshot_out_of_order", "Snapshot tick must increase")
            require(not previous or applied >= previous["applied_command_id"], "snapshot_out_of_order", "Applied command cannot move backwards")
            require(applied == 0 or db.execute("SELECT 1 FROM commands WHERE match_id=? AND command_id=?", (match_id,applied)).fetchone(),
                    "invalid_checkpoint", "Applied command is not in this match")
            persisted = durable or time.monotonic() - self.checkpoint_written_at.get(match_id, 0) >= 1
            if persisted:
                self.flush_checkpoint(match_id, checkpoint)
            self.live_checkpoints[match_id] = checkpoint
            event = {"type": "snapshot", "match_id": match_id, "tick": tick, "applied_command_id": applied, "state": request["state"]}
            return {"type": "snapshot_ack", "tick": tick, "persisted": persisted, "duplicate": duplicate}, ([] if duplicate else [(event, "guest", None)])
        if kind == "match_result":
            self.require_host(client)
            match_id = identifier(request.get("match_id"), "match_id")
            match = self.store.db.execute("SELECT * FROM matches WHERE match_id=? AND room_id=?", (match_id,client.room_id)).fetchone()
            require(match is not None, "match_mismatch", "Match does not belong to this room")
            result_json = json_object(request.get("result"), "result", 65536)
            require(request["result"].get("outcome") in ("victory", "defeat"), "invalid_result", "Invalid match outcome")
            profiles = self.validated_profiles(client, request.get("profiles"))
            canonical = json.dumps({"result": request["result"], "profiles": request["profiles"]}, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            digest = hashlib.sha256(canonical.encode()).hexdigest()
            db = self.store.db
            with self.store.transaction():
                previous = db.execute("SELECT * FROM match_results WHERE match_id=?", (match_id,)).fetchone()
                duplicate = previous is not None
                if previous:
                    require(previous["payload_hash"] == digest, "result_conflict", "Match already committed with another result")
                    persisted = json.loads(previous["profiles_json"])
                else:
                    self.require_match(client, request)
                    for player, profile in profiles.items():
                        db.execute("UPDATE profiles SET profile_json=?,revision=revision+1,updated_at=? WHERE player_id=?", (profile,time.time(),player))
                    persisted = self.persisted_profiles(client.room_id)
                    db.execute("INSERT INTO match_results VALUES (?,?,?,?,?)", (match_id,result_json,encode(persisted),digest,time.time()))
                    db.execute("UPDATE matches SET status='finished' WHERE match_id=?", (match_id,))
                    db.execute("UPDATE rooms SET status='finished' WHERE room_id=?", (client.room_id,))
            reply = {"type": "match_result_ack", "match_id": match_id, "committed": True, "duplicate": duplicate, "profiles": persisted}
            event = {"type": "match_finished", "match_id": match_id, "result": request["result"], "profiles": persisted}
            return reply, ([] if duplicate else [(event, None, None)])
        raise ProtocolError("unknown_message", "Unsupported message type")

    async def handler(self, socket):
        if len(self.connections) >= 32:
            await socket.close(1013, "Server connection limit reached")
            return
        self.connections.add(socket)
        client = Client(socket, rate_updated=time.monotonic())
        try:
            while True:
                request = None
                try:
                    raw = await asyncio.wait_for(socket.recv(), self.auth_timeout if not client.authenticated else self.idle_timeout)
                    client.rate_limit()
                    request = decode(raw)
                    response, events = await self.dispatch(client, request)
                    # A slow input sender's ACK must not hold up forwarding the
                    # already committed command to the authoritative simulation.
                    if request["type"] == "input":
                        for event, role, exclude in events:
                            await self.broadcast(client.room_id, event, role, exclude)
                        events = []
                    await self.send_message(client, {"request_id": request["request_id"], **response})
                    for event, role, exclude in events:
                        await self.broadcast(client.room_id, event, role, exclude)
                    if request["type"] == "leave":
                        await socket.close(1000, "Left room; progress is retained")
                        break
                except ProtocolError as error:
                    reply = {"v": VERSION, "type": "error", "code": error.code, "message": str(error)}
                    if request: reply["request_id"] = request["request_id"]
                    if error.code in ("preparation_conflict", "stale_preparation") and client.room_id:
                        reply["state"] = self.state(client)
                    await self.send_message(client, reply)
                    if not client.authenticated or error.code in ("rate_limited", "session_replaced"):
                        await socket.close(1008, "Protocol or authentication policy")
                        break
                except asyncio.TimeoutError:
                    await socket.close(1008, "Game heartbeat timed out" if client.authenticated else "Authentication timed out")
                    break
                except (sqlite3.Error, OSError):
                    LOG.exception("Storage operation failed")
                    reply = {"v": VERSION, "type": "error", "code": "storage_error", "message": "Could not commit game data; retry the same request"}
                    if request: reply["request_id"] = request["request_id"]
                    await self.send_message(client, reply)
        except ConnectionClosed:
            pass
        except Exception:
            LOG.exception("Connection failed")
            await socket.close(1011, "Server error")
        finally:
            client.pending_visual = None
            if client.visual_task is not None:
                client.visual_task.cancel()
                await asyncio.gather(client.visual_task, return_exceptions=True)
            self.connections.discard(socket)
            key = (client.room_id, client.player_id)
            if self.clients.get(key) is client:
                del self.clients[key]
                try:
                    with self.store.transaction():
                        self.store.clear_ready(client.room_id)
                    self.flush_checkpoint(self.store.room(client.room_id)["match_id"])
                    await self.broadcast(client.room_id, {"type": "player_disconnected", "player_id": client.player_id, "state": self.state(client)})
                except (sqlite3.Error, OSError):
                    LOG.exception("Could not flush disconnected player's checkpoint")

    def process_request(self, connection, request):
        if request.path == "/health":
            response = connection.respond(HTTPStatus.OK, '{"ok":true,"protocol":1}\n')
            del response.headers["Content-Type"]
            response.headers["Content-Type"] = "application/json"
            response.headers["Cache-Control"] = "no-store"
            return response
        if request.path != "/game":
            return connection.respond(HTTPStatus.NOT_FOUND, "Not found\n")
        if request.headers.get("Upgrade", "").lower() != "websocket":
            return connection.respond(HTTPStatus.UPGRADE_REQUIRED, "WebSocket required\n")
        return None


async def run(args):
    store = Store(args.data_dir)
    app = GameServer(store, args.invite_ttl, args.auth_timeout, args.idle_timeout)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stopped.set)

    async def periodic_backup():
        while True:
            await asyncio.sleep(args.backup_every)
            try: store.backup()
            except (sqlite3.Error, OSError): LOG.exception("Scheduled database backup failed")

    async def periodic_checkpoint():
        while True:
            await asyncio.sleep(1)
            try: app.flush_pending_checkpoints()
            except (sqlite3.Error, OSError): LOG.exception("Scheduled checkpoint failed")

    backup_task = None
    checkpoint_task = None
    try:
        async with serve(app.handler, "127.0.0.1", args.port, process_request=app.process_request,
                         max_size=MAX_MESSAGE, max_queue=16, compression=None,
                         # GameMaker LTS 2026 emits an unmasked control PONG, which
                         # correctly triggers 1002 in an RFC-compliant server.
                         # JSON ping/pong + bounded receive deadlines provide liveness.
                         ping_interval=None, close_timeout=3,
                         server_header="FVM-Coop/1") as server:
            port = server.sockets[0].getsockname()[1]
            print(encode({"listening": "127.0.0.1", "port": port, "protocol": VERSION}), flush=True)
            if args.backup_every > 0: backup_task = asyncio.create_task(periodic_backup())
            checkpoint_task = asyncio.create_task(periodic_checkpoint())
            await stopped.wait()
    finally:
        if backup_task:
            backup_task.cancel()
            await asyncio.gather(backup_task, return_exceptions=True)
        if checkpoint_task:
            checkpoint_task.cancel()
            await asyncio.gather(checkpoint_task, return_exceptions=True)
        try: app.flush_pending_checkpoints()
        except (sqlite3.Error, OSError): LOG.exception("Final checkpoint failed")
        try: store.backup()
        except (sqlite3.Error, OSError): LOG.exception("Final database backup failed")
        store.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).parent / "serverdata")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--invite-ttl", type=float, default=600)
    parser.add_argument("--auth-timeout", type=float, default=5)
    parser.add_argument("--backup-every", type=float, default=300)
    parser.add_argument("--idle-timeout", type=float, default=30)
    args = parser.parse_args()
    if not (0 <= args.port <= 65535 and 0 < args.invite_ttl <= 3600 and 0 < args.auth_timeout <= 30 and args.backup_every >= 0 and 0 < args.idle_timeout <= 120):
        parser.error("Invalid limits")
    os.umask(0o077)
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
