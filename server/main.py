#!/usr/bin/env python3
"""Loopback-only, two-player FVM co-op service. No game simulation runs here."""
import argparse
import asyncio
from dataclasses import dataclass
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
                      ProtocolError, decode, encode, identifier, input_payload,
                      integer, json_object, require, string)
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

    def state(self, client, after=None):
        connected = {player for (room, player) in self.clients if room == client.room_id}
        match_id = self.store.room(client.room_id)["match_id"]
        return self.store.state(client.room_id, connected, after, self.live_checkpoints.get(match_id))

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
        client.authenticated = True
        client.room_id, client.player_id, client.role = room_id, player_id, role
        self.clients[key] = client
        if previous and previous is not client:
            await previous.socket.close(4001, "Session resumed on another connection")

    async def broadcast(self, room_id, message, role=None, exclude=None):
        payload = encode({"v": VERSION, **message})
        targets = [c for (room, _), c in self.clients.items()
                   if room == room_id and c is not exclude and (role is None or c.role == role)]
        async def send(client):
            try:
                await asyncio.wait_for(client.socket.send(payload), 3)
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
                    for player, profile in profiles.items():
                        db.execute("UPDATE profiles SET profile_json=?,revision=revision+1,updated_at=? WHERE player_id=?", (profile,time.time(),player))
                    reply = {"type": "campaign_saved", "committed": True, "duplicate": False, "profiles": self.persisted_profiles(client.room_id)}
                    db.execute("INSERT INTO campaign_commits VALUES (?,?,?,?,?)", (client.room_id,request["request_id"],digest,encode(reply),time.time()))
            return reply, ([] if reply["duplicate"] else [({"type": "campaign_updated", "profiles": reply["profiles"]}, "guest", None)])
        if kind == "start_match":
            self.require_host(client)
            room = self.store.room(client.room_id)
            require(room["status"] in ("lobby", "finished"), "match_already_running", "A match is already running")
            members = self.store.members(client.room_id)
            require(len(members) == 2 and all((client.room_id,m["player_id"]) in self.clients for m in members),
                    "players_not_ready", "Both players must be connected")
            level = identifier(request.get("level_id"), "level_id")
            config = json_object(request.get("config", {}), "config", 16384)
            profiles = self.validated_profiles(client, request.get("profiles"), False)
            match_id = new_id()
            with self.store.transaction():
                self.store.db.execute("INSERT INTO matches VALUES (?,?,?,?, 'running',?)", (match_id,client.room_id,level,config,time.time()))
                self.store.db.execute("UPDATE rooms SET status='running',match_id=? WHERE room_id=?", (match_id,client.room_id))
                self.store.db.execute("UPDATE members SET last_seq=0 WHERE room_id=?", (client.room_id,))
                if "profiles" in request:
                    for player, profile in profiles.items():
                        self.store.db.execute("UPDATE profiles SET profile_json=?,revision=revision+1,updated_at=? WHERE player_id=?", (profile,time.time(),player))
            response = {"type": "match_started", "match_id": match_id, "state": self.state(client)}
            return response, [(response, None, client)]
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
                    await socket.send(encode({"v": VERSION, "request_id": request["request_id"], **response}))
                    for event, role, exclude in events:
                        await self.broadcast(client.room_id, event, role, exclude)
                    if request["type"] == "leave":
                        await socket.close(1000, "Left room; progress is retained")
                        break
                except ProtocolError as error:
                    reply = {"v": VERSION, "type": "error", "code": error.code, "message": str(error)}
                    if request: reply["request_id"] = request["request_id"]
                    await socket.send(encode(reply))
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
                    await socket.send(encode(reply))
        except ConnectionClosed:
            pass
        except Exception:
            LOG.exception("Connection failed")
            await socket.close(1011, "Server error")
        finally:
            self.connections.discard(socket)
            key = (client.room_id, client.player_id)
            if self.clients.get(key) is client:
                del self.clients[key]
                try:
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
