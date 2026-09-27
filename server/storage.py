"""SQLite is the canonical store; acknowledgements follow committed transactions."""
from contextlib import closing, contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
import uuid

from protocol import encode, require


def new_id():
    return uuid.uuid4().hex


def new_token():
    return secrets.token_urlsafe(32)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class Store:
    def __init__(self, directory):
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        self.token_path = self.directory / "host-token"
        try:
            fd = os.open(self.token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            require(not self.token_path.is_symlink(), "storage_error", "Host token cannot be a symlink")
            self.host_token = self.token_path.read_text().strip()
            require(len(self.host_token) >= 40, "storage_error", "Invalid local host token")
            os.chmod(self.token_path, 0o600)
        else:
            self.host_token = new_token()
            with os.fdopen(fd, "w") as output:
                output.write(self.host_token + "\n")
                output.flush()
                os.fsync(output.fileno())
        path = self.directory / "coop.sqlite3"
        require(not path.is_symlink(), "storage_error", "Database cannot be a symlink")
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        os.chmod(path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA fullfsync=ON")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS profiles (
                player_id TEXT PRIMARY KEY, profile_json TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1, updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS rooms (
                room_id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL,
                invite_hash TEXT NOT NULL, invite_expires_at REAL NOT NULL,
                invite_used INTEGER NOT NULL DEFAULT 0, match_id TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS members (
                room_id TEXT NOT NULL REFERENCES rooms(room_id),
                player_id TEXT NOT NULL REFERENCES profiles(player_id),
                role TEXT NOT NULL CHECK(role IN ('host','guest')), name TEXT NOT NULL,
                resume_hash TEXT NOT NULL, last_seq INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(room_id, player_id), UNIQUE(room_id, role)
            );
            CREATE TABLE IF NOT EXISTS matches (
                match_id TEXT PRIMARY KEY, room_id TEXT NOT NULL REFERENCES rooms(room_id),
                level_id TEXT NOT NULL, config_json TEXT NOT NULL, status TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS commands (
                command_id INTEGER PRIMARY KEY AUTOINCREMENT,
                match_id TEXT NOT NULL REFERENCES matches(match_id), player_id TEXT NOT NULL,
                seq INTEGER NOT NULL, action TEXT NOT NULL, payload_json TEXT NOT NULL,
                created_at REAL NOT NULL, UNIQUE(match_id, player_id, seq)
            );
            CREATE INDEX IF NOT EXISTS commands_match ON commands(match_id,command_id);
            CREATE TABLE IF NOT EXISTS checkpoints (
                match_id TEXT PRIMARY KEY REFERENCES matches(match_id), tick INTEGER NOT NULL,
                applied_command_id INTEGER NOT NULL, state_json TEXT NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS match_results (
                match_id TEXT PRIMARY KEY REFERENCES matches(match_id), result_json TEXT NOT NULL,
                profiles_json TEXT NOT NULL, payload_hash TEXT NOT NULL, committed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS campaign_commits (
                room_id TEXT NOT NULL REFERENCES rooms(room_id), request_id TEXT NOT NULL,
                payload_hash TEXT NOT NULL, response_json TEXT NOT NULL, committed_at REAL NOT NULL,
                PRIMARY KEY(room_id, request_id)
            );
            PRAGMA user_version=1;
        """)

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def room(self, room_id):
        row = self.db.execute("SELECT * FROM rooms WHERE room_id=?", (room_id,)).fetchone()
        require(row is not None, "room_not_found", "Room does not exist")
        return row

    def members(self, room_id):
        return self.db.execute("""SELECT m.*,p.profile_json,p.revision FROM members m
            JOIN profiles p USING(player_id) WHERE room_id=? ORDER BY role DESC""", (room_id,)).fetchall()

    def member(self, room_id, player_id):
        return self.db.execute("SELECT * FROM members WHERE room_id=? AND player_id=?", (room_id, player_id)).fetchone()

    def create_room(self, profile_json, name, host_name, invite_ttl):
        room_id, player_id = new_id(), new_id()
        resume, invite = new_token(), new_token()
        now, expires = time.time(), time.time() + invite_ttl
        with self.transaction():
            self.db.execute("INSERT INTO profiles VALUES (?,?,1,?)", (player_id, profile_json, now))
            self.db.execute("INSERT INTO rooms VALUES (?,?, 'lobby',?,?,0,NULL,?)", (room_id,name,token_hash(invite),expires,now))
            self.db.execute("INSERT INTO members VALUES (?,?, 'host',?,?,0)", (room_id,player_id,host_name,token_hash(resume)))
        return room_id, player_id, resume, invite, expires

    def join_room(self, room_id, invite, name):
        with self.transaction():
            room = self.room(room_id)
            require(room["status"] == "lobby", "room_unavailable", "Room is not accepting a player")
            require(not room["invite_used"] and room["invite_expires_at"] > time.time()
                    and secrets.compare_digest(room["invite_hash"], token_hash(invite)), "invite_invalid", "Invitation is invalid, expired, or already used")
            members = self.members(room_id)
            require(len(members) == 1, "room_full", "Room already has two players")
            player_id, resume = new_id(), new_token()
            self.db.execute("INSERT INTO profiles VALUES (?,?,1,?)", (player_id,members[0]["profile_json"],time.time()))
            self.db.execute("INSERT INTO members VALUES (?,?, 'guest',?,?,0)", (room_id,player_id,name,token_hash(resume)))
            self.db.execute("UPDATE rooms SET invite_used=1 WHERE room_id=?", (room_id,))
        return player_id, resume

    def resume(self, room_id, token):
        row = self.db.execute("SELECT * FROM members WHERE room_id=? AND resume_hash=?", (room_id,token_hash(token))).fetchone()
        require(row is not None, "resume_invalid", "Invalid room resume credential")
        return row

    def command_dict(self, row):
        return {"command_id": row["command_id"], "match_id": row["match_id"], "player_id": row["player_id"],
                "seq": row["seq"], "action": row["action"], "payload": json.loads(row["payload_json"])}

    def state(self, room_id, connected, after_command_id=None, live_checkpoint=None):
        room = self.room(room_id)
        players = [{"player_id": m["player_id"], "role": m["role"], "name": m["name"],
                    "profile": json.loads(m["profile_json"]), "revision": m["revision"],
                    "last_seq": m["last_seq"], "connected": m["player_id"] in connected}
                   for m in self.members(room_id)]
        result = {"room_id": room_id, "name": room["name"], "room_status": room["status"],
                  "match_id": room["match_id"], "level_id": None, "config": {}, "players": players,
                  "checkpoint": None, "pending_commands": [], "pending_commands_more": False,
                  "result": None}
        if room["match_id"]:
            match = self.db.execute("SELECT * FROM matches WHERE match_id=?", (room["match_id"],)).fetchone()
            result.update(level_id=match["level_id"], config=json.loads(match["config_json"]))
            checkpoint = self.db.execute("SELECT * FROM checkpoints WHERE match_id=?", (room["match_id"],)).fetchone()
            if checkpoint:
                result["checkpoint"] = {"tick": checkpoint["tick"], "applied_command_id": checkpoint["applied_command_id"],
                                        "state": json.loads(checkpoint["state_json"])}
            if live_checkpoint is not None:
                result["checkpoint"] = live_checkpoint
            after = after_command_id if after_command_id is not None else (result["checkpoint"]["applied_command_id"] if result["checkpoint"] else 0)
            rows = self.db.execute("SELECT * FROM commands WHERE match_id=? AND command_id>? ORDER BY command_id LIMIT 257", (room["match_id"],after)).fetchall()
            result["pending_commands"] = [self.command_dict(row) for row in rows[:256]]
            result["pending_commands_more"] = len(rows) > 256
            final = self.db.execute("SELECT result_json FROM match_results WHERE match_id=?", (room["match_id"],)).fetchone()
            if final: result["result"] = json.loads(final["result_json"])
        return result

    def backup(self):
        directory = self.directory / "backups"
        require(not directory.is_symlink(), "storage_error", "Backup directory cannot be a symlink")
        directory.mkdir(mode=0o700, exist_ok=True)
        destination = directory / (time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(4) + ".sqlite3")
        with closing(sqlite3.connect(destination)) as backup_db:
            self.db.backup(backup_db)
        os.chmod(destination, 0o600)
        # Bound automatic local storage without deleting anything outside our own naming scheme.
        backups = sorted(directory.glob("????????-??????-????????.sqlite3"))
        for old in backups[:-48]:
            old.unlink()
        return destination.name

    def close(self):
        self.db.close()
