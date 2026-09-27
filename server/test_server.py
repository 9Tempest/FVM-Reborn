"""End-to-end tests use real loopback WebSockets and a disposable SQLite directory."""
import asyncio
import base64
import contextlib
import json
from pathlib import Path
import sqlite3
import stat
import struct
import sys
import tempfile
import unittest
import uuid
import zlib

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed
from websockets.asyncio.server import serve

from main import GameServer
from storage import Store


# Real 2x2 JPEG generated with macOS ImageIO/sips; no test-time imaging dependency.
JPEG_SCREEN = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAgACAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8Az6KKK/z7P9dD/9k="


def png_screen(width=2, height=2):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind+body) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\x50\x0a" * width) * height)) + chunk(b"IEND", b"")
    return base64.b64encode(png).decode()


def screen_fields(seq=1, **changes):
    return {"seq": seq, "room": "room_menu", "title": "共同合成屋", "width": 2,
            "height": 2, "encoding": "png", "image": png_screen(), **changes}


def profile(**changes):
    return {"coins": 100, "name": "合作测试", "player": {"total_time": 0},
            "unlocked_cards": [{"id": card, "level": 1, "shape": 0} for card in ("sunflower", "toast_bread", "ice_cream")],
            "unlocked_items": {"max_slot": 2}, **changes}


class Peer:
    def __init__(self, socket):
        self.socket, self.counter, self.events = socket, 0, []
        self.prefix = uuid.uuid4().hex

    async def rpc(self, kind, request_id=None, **fields):
        self.counter += 1
        request_id = request_id or f"{self.prefix}-{self.counter}"
        await self.socket.send(json.dumps({"v": 1, "type": kind, "request_id": request_id, **fields}, ensure_ascii=False))
        while True:
            message = json.loads(await asyncio.wait_for(self.socket.recv(), 4))
            if message.get("request_id") == request_id:
                return message
            self.events.append(message)

    async def event(self, kind):
        while True:
            for index, event in enumerate(self.events):
                if event["type"] == kind:
                    return self.events.pop(index)
            self.events.append(json.loads(await asyncio.wait_for(self.socket.recv(), 4)))


class EndToEnd(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fvm-coop-测试-")
        self.data = Path(self.temp.name)
        self.peers = []
        self.process = None
        await self.start()

    async def start(self, *arguments):
        self.process = await asyncio.create_subprocess_exec(
            sys.executable, str(Path(__file__).with_name("main.py")),
            "--data-dir", str(self.data), "--port", "0", "--backup-every", "0", *arguments,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        line = await asyncio.wait_for(self.process.stdout.readline(), 5)
        if not line:
            self.fail((await self.process.stderr.read()).decode())
        ready = json.loads(line)
        self.assertEqual(ready["listening"], "127.0.0.1")
        self.port = ready["port"]
        self.url = f"ws://127.0.0.1:{self.port}/game"
        self.token = (self.data / "host-token").read_text().strip()

    async def stop(self, abrupt=False):
        if self.process and self.process.returncode is None:
            if abrupt: self.process.kill()
            else: self.process.terminate()
            await asyncio.wait_for(self.process.wait(), 8)
            self.stderr = (await self.process.stderr.read()).decode()
        self.process = None

    async def asyncTearDown(self):
        try:
            for peer in self.peers:
                if peer.socket.close_code is None:
                    await peer.socket.close()
        finally:
            await self.stop()
            self.temp.cleanup()

    async def test_application_heartbeat_and_idle_deadline(self):
        await self.stop()
        await self.start("--idle-timeout", "1")
        peer = await self.peer()
        await peer.rpc("auth_host", token=self.token)
        await peer.rpc("create_room", profile={"coins": 0})
        for _ in range(4):
            await asyncio.sleep(0.4)
            self.assertEqual((await peer.rpc("ping"))["type"], "pong")
        # A silent authenticated peer must not retain one of the bounded slots.
        with self.assertRaises(ConnectionClosed):
            await asyncio.wait_for(peer.socket.recv(), 2)
        self.assertEqual(peer.socket.close_code, 1008)
        self.assertEqual(peer.socket.close_reason, "Game heartbeat timed out")

    async def peer(self):
        peer = Peer(await connect(self.url, compression=None, max_size=4 * 1024 * 1024, proxy=None))
        self.peers.append(peer)
        return peer

    async def room(self):
        host = await self.peer()
        self.assertEqual((await host.rpc("auth_host", token=self.token))["type"], "host_authenticated")
        created = await host.rpc("create_room", profile=profile())
        self.assertEqual(created["type"], "room_created")
        guest = await self.peer()
        joined = await guest.rpc("join_room", room_id=created["room_id"], invite_token=created["invite_token"], name="客人")
        self.assertEqual(joined["type"], "room_joined")
        return host, guest, created, joined

    async def match(self):
        host, guest, created, joined = await self.room()
        match = await self.start_match(host, guest)
        self.assertEqual(match["type"], "match_started")
        return host, guest, created, joined, match["match_id"]

    async def prepare(self, host, level="1-1"):
        response = await host.rpc("prepare_match", level_id=level, level_name="测试关卡", slot_limit=31)
        self.assertEqual(response["type"], "loadout_state", response)
        return response["state"]["preparation"]

    async def select(self, peer, preparation, deck, ready=False, **extra):
        response = await peer.rpc("set_loadout", preparation_id=preparation["id"],
                                  revision=preparation["revision"], deck=deck, ready=ready, **extra)
        self.assertEqual(response["type"], "loadout_state", response)
        return response["state"]["preparation"]

    async def ready(self, host, guest, level="1-1"):
        preparation = await self.prepare(host, level)
        preparation = await self.select(host, preparation, ["sunflower"])
        preparation = await self.select(guest, preparation, ["toast_bread"])
        preparation = await self.select(host, preparation, ["sunflower"], True)
        return await self.select(guest, preparation, ["toast_bread"], True)

    async def start_match(self, host, guest, level="1-1", **extra):
        preparation = await self.ready(host, guest, level)
        response = await host.rpc("start_match", level_id=level, preparation_id=preparation["id"],
                                  revision=preparation["revision"], config={"shared_campaign": True}, **extra)
        self.assertEqual(response["type"], "match_started", response)
        return response

    def query(self, sql, parameters=()):
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db:
            return db.execute(sql, parameters).fetchall()

    async def test_complete_match_commit_idempotence_backup_and_restart(self):
        host, guest, created, joined, match_id = await self.match()
        ack = await guest.rpc("input", match_id=match_id, seq=1, action="place_player", payload={"row": 2, "col": 3})
        self.assertFalse(ack["duplicate"])
        command = await host.event("command")
        self.assertEqual(command["player_id"], joined["player_id"])
        self.assertEqual(command["command_id"], ack["command_id"])
        snapshot = {"entities": [{"kind": "avatar", "row": 2, "col": 3}], "hud": {"flame": 100}}
        saved = await host.rpc("snapshot", match_id=match_id, tick=50, applied_command_id=ack["command_id"], state=snapshot)
        self.assertTrue(saved["persisted"])
        self.assertEqual((await guest.event("snapshot"))["state"], snapshot)
        profiles = {created["player_id"]: profile(coins=150, level="1-2"), joined["player_id"]: profile(coins=150, level="1-2")}
        result = {"outcome": "victory", "reward": {"coins": 50}}
        won = await host.rpc("match_result", match_id=match_id, result=result, profiles=profiles)
        self.assertTrue(won["committed"])
        self.assertFalse(won["duplicate"])
        self.assertEqual((await guest.event("match_finished"))["result"], result)
        repeated = await host.rpc("match_result", match_id=match_id, result=result, profiles=profiles)
        self.assertTrue(repeated["duplicate"])
        self.assertEqual(won["profiles"], repeated["profiles"])
        self.assertEqual(self.query("SELECT COUNT(*) FROM match_results"), [(1,)])
        self.assertEqual(sorted(x[0] for x in self.query("SELECT revision FROM profiles")), [2, 2])
        conflict = await host.rpc("match_result", match_id=match_id, result={"outcome": "defeat"}, profiles=profiles)
        self.assertEqual(conflict["code"], "result_conflict")
        backup = await host.rpc("backup")
        path = self.data / "backups" / backup["filename"]
        with contextlib.closing(sqlite3.connect(path)) as db:
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM match_results").fetchone()[0], 1)
            dump = "\n".join(db.iterdump())
        for token in (self.token, created["resume_token"], joined["resume_token"], created["invite_token"]):
            self.assertNotIn(token, dump)
        self.assertEqual(stat.S_IMODE((self.data / "host-token").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        await self.stop(abrupt=True)
        await self.start()
        resumed_host, resumed_guest = await self.peer(), await self.peer()
        resumed = await resumed_host.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        self.assertEqual(resumed["state"]["room_status"], "finished")
        self.assertEqual(resumed["state"]["result"], result)
        self.assertEqual(resumed["state"]["checkpoint"]["state"], snapshot)
        await resumed_guest.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        retry = await resumed_host.rpc("match_result", match_id=match_id, result=result, profiles=profiles)
        self.assertTrue(retry["duplicate"])
        self.assertEqual(retry["profiles"], won["profiles"])
        # Starting a later match must not allow a delayed result retry to award again.
        await resumed_host.rpc("save_campaign", profiles={p: profile(coins=175) for p in profiles})
        await self.start_match(resumed_host, resumed_guest, "1-2")
        old_retry = await resumed_host.rpc("match_result", match_id=match_id, result=result, profiles=profiles)
        self.assertTrue(old_retry["duplicate"])
        self.assertEqual(old_retry["profiles"], won["profiles"])
        self.assertEqual(self.query("SELECT revision FROM profiles"), [(3,), (3,)])
        self.assertEqual(self.query("SELECT COUNT(*) FROM match_results"), [(1,)])

    async def test_inputs_reconnect_presence_and_checkpoint_batching(self):
        host, guest, created, joined, match_id = await self.match()
        fields = dict(match_id=match_id, seq=1, action="place_card", payload={"row": 1, "col": 2, "card_id": "sunflower"})
        first = await guest.rpc("input", **fields)
        again = await guest.rpc("input", **fields)
        self.assertTrue(again["duplicate"])
        self.assertEqual(first["command_id"], again["command_id"])
        self.assertEqual(self.query("SELECT COUNT(*) FROM commands"), [(1,)])
        self.assertEqual((await guest.rpc("input", **{**fields, "seq": 3}))["code"], "sequence_gap")
        self.assertEqual((await guest.rpc("input", **{**fields, "payload": {"row": 2, "col": 2, "card_id": "sunflower"}}))["code"], "sequence_conflict")
        for action, payload in [("set_coins", {"coins": 900}), ("shovel", {"row": -1, "col": 0}), ("shovel", {"row": 1, "col": 0, "coins": 1})]:
            self.assertEqual((await guest.rpc("input", match_id=match_id, seq=2, action=action, payload=payload))["type"], "error")
        snapshot = dict(match_id=match_id, applied_command_id=first["command_id"], state={"flame": 20})
        self.assertTrue((await host.rpc("snapshot", tick=1, **snapshot))["persisted"])
        self.assertFalse((await host.rpc("snapshot", tick=2, **snapshot))["persisted"])
        self.assertEqual(self.query("SELECT tick FROM checkpoints"), [(1,)])
        self.assertEqual((await guest.rpc("get_state"))["state"]["checkpoint"]["tick"], 2)
        self.assertEqual((await host.rpc("snapshot", tick=1, **snapshot))["code"], "snapshot_out_of_order")
        await guest.socket.close()
        absent = await host.event("player_disconnected")
        self.assertFalse(next(p for p in absent["state"]["players"] if p["role"] == "guest")["connected"])
        self.assertEqual(self.query("SELECT tick FROM checkpoints"), [(2,)])
        guest2 = await self.peer()
        resumed = await guest2.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        self.assertEqual(next(p for p in resumed["state"]["players"] if p["role"] == "guest")["last_seq"], 1)
        self.assertTrue(all(p["connected"] for p in (await host.event("player_connected"))["state"]["players"]))
        await host.socket.close()
        await guest2.event("player_disconnected")
        unavailable = await guest2.rpc("input", **{**fields, "seq": 2})
        self.assertEqual(unavailable["code"], "host_unavailable")
        self.assertEqual((await guest2.rpc("ping"))["type"], "pong")

    async def test_unauthorized_invites_roles_and_session_takeover(self):
        for kind, fields, code in [("get_state", {}, "authentication_required"), ("auth_host", {"token": "wrong"}, "unauthorized")]:
            stranger = await self.peer()
            self.assertEqual((await stranger.rpc(kind, **fields))["code"], code)
            with self.assertRaises(ConnectionClosed): await stranger.socket.recv()
        host, guest, created, joined = await self.room()
        third = await self.peer()
        self.assertEqual((await third.rpc("join_room", room_id=created["room_id"], invite_token=created["invite_token"]))["code"], "invite_invalid")
        for kind in ("start_match", "prepare_match", "cancel_preparation", "snapshot", "match_result", "new_invite", "backup", "save_campaign"):
            self.assertEqual((await guest.rpc(kind))["code"], "forbidden")
        replacement = await self.peer()
        resumed = await replacement.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        self.assertEqual(resumed["player_id"], joined["player_id"])
        with self.assertRaises(ConnectionClosed):
            while True: await guest.socket.recv()
        wrong_room = await self.peer()
        self.assertEqual((await wrong_room.rpc("resume", room_id="wrongroom", resume_token=joined["resume_token"]))["code"], "resume_invalid")

    async def test_atomic_result_rollback_then_retry(self):
        host, guest, created, joined, match_id = await self.match()
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db:
            db.execute("CREATE TRIGGER fail_guest BEFORE UPDATE ON profiles WHEN NEW.player_id='" + joined["player_id"] + "' BEGIN SELECT RAISE(ABORT, 'test disk failure'); END")
        profiles = {created["player_id"]: {"coins": 200}, joined["player_id"]: {"coins": 200}}
        fields = dict(match_id=match_id, result={"outcome": "victory"}, profiles=profiles)
        self.assertEqual((await host.rpc("match_result", **fields))["code"], "storage_error")
        self.assertEqual(self.query("SELECT revision FROM profiles"), [(1,), (1,)])
        self.assertEqual(self.query("SELECT COUNT(*) FROM match_results"), [(0,)])
        self.assertEqual(self.query("SELECT status FROM rooms"), [("running",)])
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db: db.execute("DROP TRIGGER fail_guest")
        self.assertTrue((await host.rpc("match_result", **fields))["committed"])
        self.assertEqual(self.query("SELECT revision FROM profiles"), [(2,), (2,)])

    async def test_campaign_transactions_revisions_retry_and_restart(self):
        host, guest, created, joined = await self.room()
        profiles = {created["player_id"]: profile(coins=90, equipped="card1"), joined["player_id"]: profile(coins=90, equipped="card1")}
        fields = dict(profiles=profiles, revisions={created["player_id"]: 1, joined["player_id"]: 1})
        ack = await host.rpc("save_campaign", request_id="purchase-123", **fields)
        self.assertEqual(ack["type"], "campaign_saved")
        self.assertTrue((await host.rpc("save_campaign", request_id="purchase-123", **fields))["duplicate"])
        self.assertEqual((await guest.event("campaign_updated"))["profiles"], ack["profiles"])
        self.assertEqual((await host.rpc("save_campaign", request_id="purchase-456", **fields))["code"], "revision_conflict")
        self.assertEqual((await host.rpc("save_campaign", request_id="purchase-123", profiles={p: {"coins": 80} for p in profiles}))["code"], "request_conflict")
        await self.start_match(host, guest)
        self.assertEqual((await host.rpc("save_campaign", profiles=profiles))["code"], "match_running")
        await self.stop(abrupt=True)
        await self.start()
        host2 = await self.peer()
        resumed = await host2.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        self.assertEqual(resumed["state"]["players"][0]["profile"]["coins"], 90)
        repeated = await host2.rpc("save_campaign", request_id="purchase-123", **fields)
        self.assertTrue(repeated["duplicate"])
        self.assertEqual(repeated["profiles"], ack["profiles"])

    async def test_http_message_limits_and_validation(self):
        async def http(path):
            reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
            writer.write(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
            await writer.drain()
            result = (await asyncio.wait_for(reader.read(), 3)).decode()
            writer.close()
            await writer.wait_closed()
            return result
        health = await http("/health")
        self.assertIn("200 OK", health)
        self.assertIn('{"ok":true,"protocol":1}', health)
        self.assertNotIn(self.token, health)
        for path in ("/", "/host-token", "/../host-token", "/game?file=host-token"):
            self.assertIn("404 Not Found", await http(path))
        self.assertIn("426 Upgrade Required", await http("/game"))
        peer = await self.peer()
        await peer.socket.send('{"v":true,"type":"auth_host","request_id":"x","token":"x"}')
        self.assertEqual(json.loads(await peer.socket.recv())["code"], "protocol_version")
        oversized = await self.peer()
        await oversized.socket.send("x" * (1024 * 1024 + 1))
        with self.assertRaises(ConnectionClosed): await oversized.socket.recv()
        self.assertEqual(oversized.socket.close_code, 1009)

    async def test_expired_invitation_and_auth_timeout(self):
        await self.stop()
        await self.start("--auth-timeout", "0.15", "--invite-ttl", "0.1")
        unauthenticated = await self.peer()
        with self.assertRaises(ConnectionClosed):
            await asyncio.wait_for(unauthenticated.socket.recv(), 2)
        self.assertEqual(unauthenticated.socket.close_code, 1008)
        host = await self.peer()
        await host.rpc("auth_host", token=self.token)
        room = await host.rpc("create_room", profile={})
        await asyncio.sleep(0.12)
        guest = await self.peer()
        self.assertEqual((await guest.rpc("join_room", room_id=room["room_id"], invite_token=room["invite_token"]))["code"], "invite_invalid")

    async def test_gamemaker_numbers_periodic_checkpoint_and_rate_limit(self):
        host, guest, created, joined, match_id = await self.match()
        accepted = await guest.rpc("input", v=1.0, match_id=match_id, seq=1.0, action="use_gem", payload={"gem_index": 0.0, "row": 1.0, "col": 2.0})
        self.assertEqual(accepted["type"], "input_ack")
        for value in (True, 1.5, 10**100):
            self.assertEqual((await guest.rpc("input", match_id=match_id, seq=value, action="use_gem", payload={"gem_index": 0}))["code"], "invalid_message")
        await host.rpc("snapshot", match_id=match_id, tick=1.0, applied_command_id=accepted["command_id"], state={})
        await host.rpc("snapshot", match_id=match_id, tick=2.0, applied_command_id=accepted["command_id"], state={})
        await asyncio.sleep(1.1)
        self.assertEqual(self.query("SELECT tick FROM checkpoints"), [(2,)])
        for i in range(200):
            try:
                await guest.socket.send(json.dumps({"v": 1, "type": "ping", "request_id": f"burst-{i}"}))
            except ConnectionClosed: break
        limited = False
        with contextlib.suppress(ConnectionClosed):
            while True:
                message = json.loads(await asyncio.wait_for(guest.socket.recv(), 4))
                if message.get("code") == "rate_limited": limited = True
        self.assertTrue(limited)

    async def test_private_host_config_and_refreshed_invitation(self):
        game_dir = self.data / "game-save"
        process = await asyncio.create_subprocess_exec(sys.executable, str(Path(__file__).with_name("configure_host.py")),
            "--data-dir", str(self.data), "--game-data-dir", str(game_dir), "--public-url", "wss://game.example/game",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, errors = await process.communicate()
        self.assertEqual(process.returncode, 0, errors.decode())
        config_path = game_dir / "coop" / "host.json"
        config = json.loads(config_path.read_text())
        self.assertEqual(config["token"], self.token)
        self.assertEqual(config["public_url"], "wss://game.example/game")
        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
        self.assertNotIn(self.token, output.decode())
        host = await self.peer()
        await host.rpc("auth_host", token=self.token)
        room = await host.rpc("create_room", profile={})
        refreshed = await host.rpc("refresh_invite")
        self.assertEqual(refreshed["type"], "invite_created")
        self.assertNotEqual(refreshed["invite_token"], room["invite_token"])
        stale = await self.peer()
        self.assertEqual((await stale.rpc("join_room", room_id=room["room_id"], invite_token=room["invite_token"]))["code"], "invite_invalid")
        guest = await self.peer()
        self.assertEqual((await guest.rpc("join_room", room_id=room["room_id"], invite_token=refreshed["invite_token"]))["type"], "room_joined")
        self.assertEqual((await host.rpc("refresh_invite"))["code"], "room_full")

    async def test_loadout_validation_readiness_start_and_immutable_config(self):
        host, guest, created, joined = await self.room()
        self.assertEqual((await host.rpc("start_match", level_id="1-1"))["type"], "error")
        preparation = await self.prepare(host)
        self.assertEqual(preparation["slot_limit"], 2)  # Never trust requested 31 slots.
        self.assertFalse(any(s["cached"] for s in preparation["selections"].values()))
        state = (await guest.rpc("get_state"))["state"]
        self.assertTrue(state["features"]["personal_loadouts"])
        self.assertEqual(state["room_status"], "lobby")
        for deck, ready in [(["locked"], False), (["sunflower"] * 2, False),
                            (["sunflower", "toast_bread", "ice_cream"], False), ([], True), ([3], False)]:
            bad = await guest.rpc("set_loadout", preparation_id=preparation["id"], revision=preparation["revision"], deck=deck, ready=ready)
            self.assertEqual(bad["code"], "invalid_loadout")
        self.assertEqual(self.query("SELECT COUNT(*) FROM loadout_cache"), [(0,)])
        preparation = await self.select(host, preparation, ["sunflower"], True)
        stale = dict(preparation)
        preparation = await self.select(guest, preparation, ["sunflower"], True)
        self.assertFalse(preparation["selections"][created["player_id"]]["ready"])
        # Shared library permits the same card across the two independent decks.
        self.assertEqual(preparation["selections"][joined["player_id"]]["deck"], ["sunflower"])
        fields = dict(preparation_id=preparation["id"], revision=preparation["revision"], level_id="1-1")
        self.assertEqual((await host.rpc("start_match", **fields))["code"], "players_not_ready")
        conflict = await host.rpc("set_loadout", preparation_id=stale["id"], revision=stale["revision"], deck=["sunflower"], ready=True)
        self.assertEqual(conflict["code"], "preparation_conflict")
        self.assertEqual(conflict["state"]["preparation"], preparation)
        preparation = await self.select(host, preparation, ["sunflower"], True)
        fields["revision"] = preparation["revision"]
        self.assertEqual((await host.rpc("start_match", **{**fields, "level_id": "wrong"}))["code"], "stale_preparation")
        config = {"loadouts": {"attacker": ["locked"]}, "per_player_loadouts": False,
                  "flame_ratio": 50, "shared_campaign": False, "preparation_id": "wrong"}
        started = await host.rpc("start_match", request_id="start-once", config=config, **fields)
        self.assertEqual(started["type"], "match_started")
        expected = {created["player_id"]: ["sunflower"], joined["player_id"]: ["sunflower"]}
        frozen = started["state"]["config"]
        self.assertEqual(frozen["loadouts"], expected)
        self.assertEqual(frozen["flame_ratio"], 0.6)
        self.assertTrue(frozen["per_player_loadouts"] and frozen["shared_campaign"])
        self.assertEqual(frozen["preparation_id"], preparation["id"])
        self.assertIsNone(started["state"]["preparation"])
        repeated = await host.rpc("start_match", request_id="start-once", config=config, **fields)
        self.assertTrue(repeated["duplicate"])
        self.assertEqual(repeated["match_id"], started["match_id"])
        self.assertEqual(self.query("SELECT COUNT(*) FROM matches"), [(1,)])
        self.assertEqual((await guest.rpc("set_loadout", preparation_id=preparation["id"], revision=preparation["revision"], deck=[], ready=False))["code"], "match_already_running")
        self.assertEqual((await guest.rpc("get_state"))["state"]["config"], frozen)
        await self.stop(abrupt=True)
        await self.start()
        host = await self.peer()
        await host.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        repeated = await host.rpc("start_match", request_id="start-once", config=config, **fields)
        self.assertTrue(repeated["duplicate"])
        self.assertEqual(repeated["match_id"], started["match_id"])
        self.assertEqual(repeated["state"]["config"], frozen)
        self.assertEqual(self.query("SELECT COUNT(*) FROM matches"), [(1,)])

    async def test_loadout_per_player_level_cache_cancel_and_stale_requests(self):
        host, guest, created, joined = await self.room()
        preparation = await self.prepare(host)
        first_id = preparation["id"]
        fields = dict(preparation_id=first_id, revision=preparation["revision"], deck=["sunflower"], ready=False)
        first = await host.rpc("set_loadout", request_id="first-edit", **fields)
        preparation = first["state"]["preparation"]
        preparation = await self.select(guest, preparation, ["toast_bread"])
        cancellation = dict(preparation_id=first_id, revision=preparation["revision"])
        cancelled = await host.rpc("cancel_preparation", request_id="cancel-once", **cancellation)
        self.assertIsNone(cancelled["state"]["preparation"])
        preparation = await self.prepare(host, "1-2")
        self.assertEqual(preparation["selections"][created["player_id"]]["deck"], ["sunflower"])
        self.assertEqual(preparation["selections"][joined["player_id"]]["deck"], ["toast_bread"])
        self.assertTrue(all(s["cached"] and not s["ready"] for s in preparation["selections"].values()))
        preparation = await self.select(host, preparation, ["ice_cream"])
        preparation = await self.select(guest, preparation, ["sunflower"])
        # Retrying a committed cancel or old edit must not mutate a newer preparation.
        self.assertEqual((await host.rpc("cancel_preparation", request_id="cancel-once", **cancellation))["state"]["preparation"], preparation)
        duplicate = await host.rpc("set_loadout", request_id="first-edit", **fields)
        self.assertTrue(duplicate["duplicate"])
        self.assertEqual(duplicate["state"]["preparation"], preparation)
        self.assertEqual((await host.rpc("set_loadout", request_id="first-edit", **{**fields, "deck": []}))["code"], "request_conflict")
        self.assertEqual((await host.rpc("set_loadout", **fields))["code"], "stale_preparation")
        original = await self.prepare(host, "1-1")
        self.assertEqual(original["selections"][created["player_id"]]["deck"], ["sunflower"])
        self.assertEqual(original["selections"][joined["player_id"]]["deck"], ["toast_bread"])
        fallback = await self.prepare(host, "1-3")
        self.assertEqual(fallback["selections"][created["player_id"]]["deck"], ["ice_cream"])
        self.assertEqual(fallback["selections"][joined["player_id"]]["deck"], ["sunflower"])

    async def test_loadout_disconnect_takeover_restart_and_durable_cache(self):
        host, guest, created, joined = await self.room()
        preparation = await self.ready(host, guest)
        before = preparation["revision"]
        await guest.socket.close()
        disconnected = (await host.event("player_disconnected"))["state"]["preparation"]
        self.assertGreater(disconnected["revision"], before)
        self.assertFalse(any(s["ready"] for s in disconnected["selections"].values()))
        blocked = await host.rpc("start_match", preparation_id=disconnected["id"], revision=disconnected["revision"], level_id="1-1")
        self.assertEqual(blocked["code"], "players_not_ready")
        guest = await self.peer()
        resumed = await guest.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        preparation = resumed["state"]["preparation"]
        preparation = await self.select(host, preparation, ["sunflower"], True)
        preparation = await self.select(guest, preparation, ["toast_bread"], True)
        replacement = await self.peer()
        replaced = await replacement.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        preparation = replaced["state"]["preparation"]
        self.assertFalse(any(s["ready"] for s in preparation["selections"].values()))
        preparation = await self.select(host, preparation, ["sunflower"], True)
        preparation = await self.select(replacement, preparation, ["toast_bread"], True)
        before = preparation["revision"]
        await self.stop(abrupt=True)
        await self.start()
        # Check disk before either peer resumes: restart itself cleared ready.
        disk = json.loads(self.query("SELECT preparation_json FROM preparations")[0][0])
        self.assertGreater(disk["revision"], before)
        self.assertFalse(any(s["ready"] for s in disk["selections"].values()))
        host, guest = await self.peer(), await self.peer()
        await host.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        await guest.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        restored = await self.prepare(host)
        self.assertEqual(restored["selections"][created["player_id"]]["deck"], ["sunflower"])
        self.assertEqual(restored["selections"][joined["player_id"]]["deck"], ["toast_bread"])
        self.assertTrue(all(s["cached"] and not s["ready"] for s in restored["selections"].values()))

    async def test_loadout_business_changes_invalidate_but_playtime_does_not(self):
        host, guest, created, joined = await self.room()
        preparation = await self.ready(host, guest)
        preparation = await self.select(host, preparation, ["sunflower", "ice_cream"], True)
        preparation = await self.select(guest, preparation, ["toast_bread"], True)
        players = (created["player_id"], joined["player_id"])
        profiles = {pid: profile(player={"total_time": 999}) for pid in players}
        timed = await host.rpc("save_campaign", profiles=profiles)
        self.assertEqual(timed["state"]["preparation"], preparation)
        # start_match cannot smuggle a purchase/profile mutation past ready validation.
        forged = await host.rpc("start_match", preparation_id=preparation["id"], revision=preparation["revision"],
                                level_id="1-1", profiles={pid: profile(coins=900) for pid in players})
        self.assertEqual(forged["code"], "profiles_changed")
        profiles = {pid: profile(coins=90, unlocked_items={"max_slot": 1}, unlocked_cards=[{"id": "sunflower"}, {"id": "ice_cream"}]) for pid in players}
        changed = await host.rpc("save_campaign", profiles=profiles)
        newer = changed["state"]["preparation"]
        self.assertGreater(newer["revision"], preparation["revision"])
        self.assertEqual(newer["slot_limit"], 1)
        self.assertFalse(any(s["ready"] for s in newer["selections"].values()))
        self.assertEqual(newer["selections"][joined["player_id"]]["deck"], [])
        self.assertEqual(newer["selections"][created["player_id"]]["deck"], ["sunflower"])
        restored = await self.prepare(host)
        self.assertEqual(restored["slot_limit"], 1)
        self.assertEqual(restored["selections"][joined["player_id"]]["deck"], [])
        self.assertTrue(restored["selections"][joined["player_id"]]["cached"])

    async def test_loadout_request_atomicity_duplicate_prepare_and_revision_ordering(self):
        host, guest, created, joined = await self.room()
        fields = dict(level_id="1-1", level_name="测试", slot_limit=2.0)
        response = await host.rpc("prepare_match", request_id="prepare-once", **fields)
        preparation = response["state"]["preparation"]
        preparation = await self.select(host, preparation, ["sunflower"], True)
        repeated = await host.rpc("prepare_match", request_id="prepare-once", **fields)
        self.assertEqual(repeated["state"]["preparation"], preparation)
        self.assertTrue(repeated["duplicate"])
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db:
            db.execute("CREATE TRIGGER fail_receipt BEFORE INSERT ON preparation_requests BEGIN SELECT RAISE(ABORT, 'test disk failure'); END")
        edit = dict(preparation_id=preparation["id"], revision=preparation["revision"], deck=["toast_bread"], ready=True)
        self.assertEqual((await guest.rpc("set_loadout", request_id="atomic-edit", **edit))["code"], "storage_error")
        self.assertEqual((await host.rpc("get_state"))["state"]["preparation"], preparation)
        self.assertEqual(self.query("SELECT COUNT(*) FROM loadout_cache WHERE player_id=?", (joined["player_id"],)), [(0,)])
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db:
            db.execute("DROP TRIGGER fail_receipt")
        accepted = await guest.rpc("set_loadout", request_id="atomic-edit", **edit)
        self.assertEqual(accepted["type"], "loadout_state")
        self.assertFalse(accepted["state"]["preparation"]["selections"][created["player_id"]]["ready"])
        for kind in ("set_loadout", "cancel_preparation", "start_match"):
            stale = await host.rpc(kind, **{**edit, "level_id": "1-1"})
            self.assertEqual(stale["code"], "preparation_conflict")
        self.assertEqual(self.query("SELECT COUNT(*) FROM matches"), [(0,)])

    async def test_additive_schema_migration_preserves_old_rooms(self):
        host, guest, created, joined = await self.room()
        waiting_host = await self.peer()
        await waiting_host.rpc("auth_host", token=self.token)
        waiting_room = await waiting_host.rpc("create_room", profile=profile())
        await self.stop()
        with contextlib.closing(sqlite3.connect(self.data / "coop.sqlite3")) as db:
            db.executescript("DROP TABLE preparations; DROP TABLE loadout_cache; DROP TABLE preparation_requests; PRAGMA user_version=1;")
        await self.start()
        self.assertEqual(self.query("PRAGMA user_version"), [(2,)])
        new_guest = await self.peer()
        joined_old = await new_guest.rpc("join_room", room_id=waiting_room["room_id"], invite_token=waiting_room["invite_token"])
        self.assertEqual(joined_old["type"], "room_joined")
        self.assertIsNone(joined_old["state"]["preparation"])
        host, guest = await self.peer(), await self.peer()
        old = await host.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        self.assertEqual(old["state"]["players"][0]["profile"], profile())
        self.assertIsNone(old["state"]["preparation"])
        await guest.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        self.assertEqual((await self.start_match(host, guest))["type"], "match_started")

    async def test_screen_frame_authorization_validation_and_memory_only_recovery(self):
        host, guest, created, joined = await self.room()
        self.assertEqual((await guest.rpc("screen_frame", **screen_fields()))["code"], "forbidden")
        state = (await guest.rpc("get_state"))["state"]
        self.assertTrue(state["features"]["shared_screen"])
        self.assertIsNone(state["shared_screen"])
        for change in ({"room": "room_coop"}, {"room": "room_battle"}, {"room": "room_init"},
                       {"room": "room_ready"}, {"width": 961}, {"height": 541},
                       {"width": True}, {"width": 3}, {"image": "bad%%%"},
                       {"image": "a" * (700 * 1024 + 1)}, {"encoding": "gif"},
                       {"image": base64.b64encode(b"\x89PNG\r\n\x1a\nbroken").decode()},
                       {"image": JPEG_SCREEN, "encoding": "png"}):
            response = await host.rpc("screen_frame", **screen_fields(**change))
            self.assertEqual(response["type"], "error", change)
        rows_before = self.query("SELECT revision,profile_json FROM profiles ORDER BY player_id")
        accepted = await host.rpc("screen_frame", **screen_fields())
        self.assertTrue(accepted["accepted"])
        frame = await guest.event("screen_frame")
        self.assertEqual(frame["image"], png_screen())
        self.assertEqual(frame["title"], "共同合成屋")
        self.assertTrue(frame["stream_id"])
        self.assertTrue((await host.rpc("screen_frame", **screen_fields()))["duplicate"])
        self.assertEqual((await host.rpc("screen_frame", **screen_fields(title="changed")))["code"], "screen_conflict")
        self.assertEqual((await host.rpc("screen_frame", **screen_fields(2)))["dropped"], "rate_limited")
        await asyncio.sleep(0.26)
        jpeg = await host.rpc("screen_frame", **screen_fields(3, image=JPEG_SCREEN, encoding="jpeg"))
        self.assertTrue(jpeg["accepted"])
        self.assertEqual((await guest.event("screen_frame"))["encoding"], "jpeg")
        self.assertEqual((await host.rpc("screen_frame", **screen_fields(2)))["dropped"], "out_of_order")
        self.assertEqual(self.query("SELECT revision,profile_json FROM profiles ORDER BY player_id"), rows_before)
        await guest.socket.close()
        await host.event("player_disconnected")
        guest = await self.peer()
        resumed = await guest.rpc("resume", room_id=created["room_id"], resume_token=joined["resume_token"])
        self.assertEqual(resumed["state"]["shared_screen"]["seq"], 3)
        self.assertEqual(resumed["state"]["shared_screen"]["image"], JPEG_SCREEN)
        await self.stop(abrupt=True)
        await self.start()
        host = await self.peer()
        restarted = await host.rpc("resume", room_id=created["room_id"], resume_token=created["resume_token"])
        self.assertIsNone(restarted["state"]["shared_screen"])
        self.assertTrue((await host.rpc("screen_frame", **screen_fields()))["accepted"])
        self.assertNotEqual((await host.rpc("get_state"))["state"]["shared_screen"]["stream_id"], frame["stream_id"])

    async def test_screen_frame_cannot_cover_loadouts_or_battle(self):
        host, guest, created, joined = await self.room()
        await host.rpc("screen_frame", **screen_fields())
        await guest.event("screen_frame")
        preparation = await self.prepare(host)
        state = (await guest.rpc("get_state"))["state"]
        self.assertIsNone(state["shared_screen"])
        self.assertIsNotNone(state["preparation"])
        self.assertEqual((await host.rpc("screen_frame", **screen_fields(2)))["code"], "screen_unavailable")
        await host.rpc("cancel_preparation", preparation_id=preparation["id"], revision=preparation["revision"])
        self.assertIsNone((await guest.rpc("get_state"))["state"]["shared_screen"])
        started = await self.start_match(host, guest)
        self.assertEqual((await host.rpc("screen_frame", **screen_fields(2)))["code"], "screen_unavailable")
        profiles = {created["player_id"]: profile(), joined["player_id"]: profile()}
        await host.rpc("match_result", match_id=started["match_id"], result={"outcome": "victory"}, profiles=profiles)
        await asyncio.sleep(0.26)
        self.assertTrue((await host.rpc("screen_frame", **screen_fields(2)))["accepted"])
        self.assertEqual((await guest.event("screen_frame"))["seq"], 2)


class Streaming(unittest.IsolatedAsyncioTestCase):
    """Real WebSockets with a controlled slow write, avoiding flaky TCP thresholds."""
    peer, room = EndToEnd.peer, EndToEnd.room
    prepare, select, ready, start_match = EndToEnd.prepare, EndToEnd.select, EndToEnd.ready, EndToEnd.start_match

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fvm-stream-tests-")
        self.store = Store(self.temp.name)
        self.app = GameServer(self.store)
        self.server = await serve(self.app.handler, "127.0.0.1", 0, compression=None, ping_interval=None)
        self.url = f"ws://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/game"
        self.token, self.peers = self.store.host_token, []

    async def asyncTearDown(self):
        for peer in self.peers:
            await peer.socket.close()
        self.server.close()
        await self.server.wait_closed()
        self.store.close()
        self.temp.cleanup()

    async def test_latest_screen_overwrites_backlog_without_blocking_host(self):
        host, guest, created, joined = await self.room()
        connection = self.app.clients[(created["room_id"], joined["player_id"])]
        original = connection.socket.send
        blocked, release = asyncio.Event(), asyncio.Event()
        async def slow_send(payload):
            if json.loads(payload)["type"] == "screen_frame":
                blocked.set()
                await release.wait()
            await original(payload)
        connection.socket.send = slow_send
        try:
            self.assertTrue((await host.rpc("screen_frame", **screen_fields()))["accepted"])
            await asyncio.wait_for(blocked.wait(), 1)
            for seq in (2, 3):
                await asyncio.sleep(0.26)
                self.assertTrue((await host.rpc("screen_frame", **screen_fields(seq)))["accepted"])
            self.assertEqual(connection.pending_visual["seq"], 3)
            self.assertEqual((await host.rpc("ping"))["type"], "pong")
            release.set()
            self.assertEqual((await guest.event("screen_frame"))["seq"], 1)
            self.assertEqual((await guest.event("screen_frame"))["seq"], 3)
            self.assertIsNone(connection.pending_visual)
        finally:
            release.set()

    async def test_committed_input_reaches_host_before_slow_sender_ack(self):
        host, guest, created, joined = await self.room()
        match = await self.start_match(host, guest)
        connection = self.app.clients[(created["room_id"], joined["player_id"])]
        original = connection.socket.send
        blocked, release = asyncio.Event(), asyncio.Event()
        async def slow_ack(payload):
            if json.loads(payload)["type"] == "input_ack":
                blocked.set()
                await release.wait()
            await original(payload)
        connection.socket.send = slow_ack
        task = asyncio.create_task(guest.rpc("input", match_id=match["match_id"], seq=1,
                                             action="shovel", payload={"row": 1, "col": 1}))
        try:
            command = await asyncio.wait_for(host.event("command"), 1)
            await asyncio.wait_for(blocked.wait(), 1)
            self.assertFalse(task.done())
            self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM commands").fetchone()[0], 1)
            release.set()
            self.assertEqual((await task)["command_id"], command["command_id"])
        finally:
            release.set()
            await asyncio.gather(task, return_exceptions=True)

    async def test_final_snapshot_follows_latest_visual_before_result(self):
        host, guest, created, joined = await self.room()
        match = await self.start_match(host, guest)
        connection = self.app.clients[(created["room_id"], joined["player_id"])]
        original = connection.socket.send
        blocked, release = asyncio.Event(), asyncio.Event()
        async def slow_snapshot(payload):
            message = json.loads(payload)
            if message["type"] == "snapshot" and message["tick"] == 1:
                blocked.set()
                await release.wait()
            await original(payload)
        connection.socket.send = slow_snapshot
        try:
            fields = dict(match_id=match["match_id"], applied_command_id=0)
            await host.rpc("snapshot", tick=1, state={"game_over": False}, **fields)
            await asyncio.wait_for(blocked.wait(), 1)
            await host.rpc("snapshot", tick=2, state={"game_over": False}, **fields)
            await host.rpc("snapshot", tick=3, state={"game_over": False}, **fields)
            self.assertEqual(connection.pending_visual["tick"], 3)
            # The final frame is reliable and clears the queued outdated one.
            await host.rpc("snapshot", tick=4, state={"game_over": True}, **fields)
            await asyncio.sleep(0)
            release.set()
            self.assertEqual((await guest.event("snapshot"))["tick"], 1)
            self.assertEqual((await guest.event("snapshot"))["tick"], 4)
            profiles = {created["player_id"]: profile(), joined["player_id"]: profile()}
            await host.rpc("match_result", match_id=match["match_id"], result={"outcome": "victory"}, profiles=profiles)
            self.assertEqual((await guest.event("match_finished"))["result"]["outcome"], "victory")
        finally:
            release.set()

    async def test_direct_defeat_discards_snapshot_waiting_behind_slow_guest(self):
        host, guest, created, joined = await self.room()
        match = await self.start_match(host, guest)
        connection = self.app.clients[(created["room_id"], joined["player_id"])]
        original = connection.socket.send
        blocked, release = asyncio.Event(), asyncio.Event()
        sent = []
        async def slow_snapshot(payload):
            message = json.loads(payload)
            if message["type"] == "snapshot" and message["tick"] == 1:
                blocked.set()
                await release.wait()
            await original(payload)
            sent.append((message["type"], message.get("tick")))
        connection.socket.send = slow_snapshot
        try:
            fields = dict(match_id=match["match_id"], applied_command_id=0)
            await host.rpc("snapshot", tick=1, state={"game_over": False}, **fields)
            await asyncio.wait_for(blocked.wait(), 1)
            await host.rpc("snapshot", tick=2, state={"game_over": False}, **fields)
            self.assertEqual(connection.pending_visual["tick"], 2)
            writer = connection.visual_task
            # Leaving a battle submits defeat directly, without a terminal frame.
            profiles = {created["player_id"]: profile(), joined["player_id"]: profile()}
            result = await host.rpc("match_result", match_id=match["match_id"],
                                    result={"outcome": "defeat"}, profiles=profiles)
            self.assertTrue(result["committed"])
            self.assertEqual(self.store.room(created["room_id"])["status"], "finished")
            release.set()
            self.assertEqual((await guest.event("snapshot"))["tick"], 1)
            self.assertEqual((await guest.event("match_finished"))["result"]["outcome"], "defeat")
            await asyncio.wait_for(writer, 1)
            self.assertIsNone(connection.pending_visual)
            self.assertEqual(sent, [("snapshot", 1), ("match_finished", None)])
        finally:
            release.set()


if __name__ == "__main__":
    unittest.main(verbosity=2)
