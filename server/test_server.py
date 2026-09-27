"""End-to-end tests use real loopback WebSockets and a disposable SQLite directory."""
import asyncio
import contextlib
import json
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import unittest

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed


class Peer:
    def __init__(self, socket):
        self.socket, self.counter, self.events = socket, 0, []

    async def rpc(self, kind, request_id=None, **fields):
        self.counter += 1
        request_id = request_id or f"r{self.counter}"
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
        created = await host.rpc("create_room", profile={"coins": 100, "name": "合作测试", "cards": ["sunflower"]})
        self.assertEqual(created["type"], "room_created")
        guest = await self.peer()
        joined = await guest.rpc("join_room", room_id=created["room_id"], invite_token=created["invite_token"], name="客人")
        self.assertEqual(joined["type"], "room_joined")
        return host, guest, created, joined

    async def match(self):
        host, guest, created, joined = await self.room()
        match = await host.rpc("start_match", level_id="1-1", config={"shared_campaign": True})
        self.assertEqual(match["type"], "match_started")
        return host, guest, created, joined, match["match_id"]

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
        profiles = {created["player_id"]: {"coins": 150, "level": "1-2"}, joined["player_id"]: {"coins": 150, "level": "1-2"}}
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
        await resumed_host.rpc("start_match", level_id="1-2", profiles={p: {"coins": 175} for p in profiles})
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
        for kind in ("start_match", "snapshot", "match_result", "new_invite", "backup", "save_campaign"):
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
        profiles = {created["player_id"]: {"coins": 90, "equipped": "card1"}, joined["player_id"]: {"coins": 90, "equipped": "card1"}}
        fields = dict(profiles=profiles, revisions={created["player_id"]: 1, joined["player_id"]: 1})
        ack = await host.rpc("save_campaign", request_id="purchase-123", **fields)
        self.assertEqual(ack["type"], "campaign_saved")
        self.assertTrue((await host.rpc("save_campaign", request_id="purchase-123", **fields))["duplicate"])
        self.assertEqual((await guest.event("campaign_updated"))["profiles"], ack["profiles"])
        self.assertEqual((await host.rpc("save_campaign", request_id="purchase-456", **fields))["code"], "revision_conflict")
        self.assertEqual((await host.rpc("save_campaign", request_id="purchase-123", profiles={p: {"coins": 80} for p in profiles}))["code"], "request_conflict")
        await host.rpc("start_match", level_id="1-1")
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
