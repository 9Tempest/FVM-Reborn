#!/usr/bin/env python3
"""Integration tests against the actual GameMaker ABI; no third-party packages."""
import binascii
import base64
import ctypes
import json
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

LIBRARY_PATH = Path(sys.argv.pop(1) if len(sys.argv) > 1 else Path(__file__).parent / "build/libFvmNativeSupport.dylib").resolve()
LIBRARY = ctypes.CDLL(str(LIBRARY_PATH))
SIGNATURES = {
    "OpenFolder": 1, "FolderExists": 1, "FileExists": 1, "CopyFolder": 2,
    "DeleteFolder": 1, "StartBackupWithTargetFile": 2, "StartBackup": 1,
    "RestoreBackupWithTargetFile": 2, "RestoreBackup": 2,
    "SetNativeLogFilePath": 1, "DisableIme": "double", "EnableIme": "double",
    "UnzipMapFile": 2,
}
for name, arguments in SIGNATURES.items():
    function = getattr(LIBRARY, name)
    function.restype = ctypes.c_double
    function.argtypes = [ctypes.c_double] if arguments == "double" else [ctypes.c_char_p] * arguments
LIBRARY.EncodeGameFrame.restype = ctypes.c_char_p
LIBRARY.EncodeGameFrame.argtypes = [ctypes.c_char_p, ctypes.c_double, ctypes.c_double]


def call(name, *arguments):
    return getattr(LIBRARY, name)(*(str(arg).encode("utf-8") if isinstance(arg, (Path, str)) else arg for arg in arguments))


class NativeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="FVM 测试 ")
        self.root = Path(self.temporary.name)
        self.saves = self.root / "存档 中文 🥕"
        self.saves.mkdir()
        self.original = '{"名称":"中文角色🥕","level":7}\n'
        (self.saves / "玩家一.json").write_text(self.original, encoding="utf-8")
        (self.saves / "ignore.txt").write_text("not backed up", encoding="utf-8")
        self.backup = self.root / "备份.json"
        self.restore = self.root / "恢复"

    def tearDown(self):
        self.temporary.cleanup()

    def make_backup(self, entries):
        self.backup.write_text(json.dumps({"files": entries}, ensure_ascii=False), encoding="utf-8")

    def make_zip(self, entries, filename="地图.zip"):
        path = self.root / filename
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in entries:
                archive.writestr(name, content)
        return path

    def test_exact_exports_and_universal_architectures(self):
        symbols = subprocess.check_output(["xcrun", "nm", "-gUj", "-arch", platform.machine(), str(LIBRARY_PATH)], text=True)
        self.assertEqual(set(symbols.split()), {"_" + name for name in SIGNATURES} | {"_EncodeGameFrame"})
        architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(LIBRARY_PATH)], text=True)
        self.assertEqual(set(architectures.split()), {"arm64", "x86_64"})
        subprocess.run(["codesign", "--verify", "--strict", str(LIBRARY_PATH)], check=True)

    def test_game_canvas_encoder_returns_jpeg_without_files(self):
        pixels = base64.b64encode(bytes((255, 0, 0, 255)) * 32 * 18)
        result = LIBRARY.EncodeGameFrame(pixels, 32, 18)
        jpeg = base64.b64decode(result, validate=True)
        self.assertTrue(jpeg.startswith(b"\xff\xd8\xff"))
        self.assertTrue(jpeg.endswith(b"\xff\xd9"))

    def test_game_canvas_encoder_bounds_and_buffer_length(self):
        for pixels, width, height in ((None, 1, 1), (b"AA==", 1, 1), (b"@@@@", 1, 1),
                                      (b"", 961, 540), (b"", 960, 541),
                                      (b"", float("nan"), 1), (b"", 1.5, 1)):
            self.assertEqual(LIBRARY.EncodeGameFrame(pixels, width, height), b"")

    def test_background_activity_lifecycle_preserves_normal_sleep(self):
        executable = self.root / "activity-test"
        source = Path(__file__).with_name("test_activity.mm")
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-arch", platform.machine(), str(source), "-framework", "Foundation", "-o", str(executable)], check=True)
        output = subprocess.check_output([str(executable), str(LIBRARY_PATH), str(self.root / "native.log")], text=True)
        self.assertIn("activity_begin=1 activity_end=1 normal_idle_sleep_allowed=yes", output)

    def test_all_exports_accept_their_abi(self):
        for name in SIGNATURES:
            if name in ("DisableIme", "EnableIme"):
                self.assertEqual(call(name, 0.0), 0)
            elif name in ("FolderExists", "FileExists"):
                self.assertEqual(call(name, None), 0)
            else:
                args = (None,) * SIGNATURES[name]
                self.assertEqual(call(name, *args), -1, name)

    def test_unicode_paths_copy_merge_and_delete(self):
        self.assertEqual(call("FolderExists", self.saves), 1)
        self.assertEqual(call("FileExists", self.saves / "玩家一.json"), 1)
        self.assertEqual(call("FileExists", self.saves), 0)
        destination = self.root / "复制 目录"
        merged = destination / self.saves.name
        merged.mkdir(parents=True)
        (merged / "existing.txt").write_text("keep", encoding="utf-8")
        self.assertEqual(call("CopyFolder", str(self.saves) + "/", destination), 0)
        self.assertEqual((merged / "玩家一.json").read_text(encoding="utf-8"), self.original)
        self.assertEqual((merged / "existing.txt").read_text(), "keep")
        self.assertEqual(call("DeleteFolder", destination), 0)
        self.assertFalse(destination.exists())
        self.assertTrue(self.saves.exists())

    def test_copy_rejects_overlap_and_symlinks(self):
        self.assertEqual(call("CopyFolder", self.saves, self.saves), -1)
        (self.saves / "alias.json").symlink_to(self.saves / "玩家一.json")
        self.assertEqual(call("CopyFolder", self.saves, self.root / "copy"), -13)
        self.assertFalse((self.root / "copy").exists())

    def test_backup_format_and_restore_preserve_existing_files(self):
        self.assertEqual(call("StartBackupWithTargetFile", self.saves, self.backup), 0)
        data = json.loads(self.backup.read_text(encoding="utf-8"))
        self.assertEqual(data, {"files": [{"name": "玩家一.json", "content": self.original}]})
        self.restore.mkdir()
        (self.restore / "existing.json").write_text("preserved", encoding="utf-8")
        self.assertEqual(call("RestoreBackupWithTargetFile", self.restore, self.backup), 0)
        self.assertEqual((self.restore / "玩家一.json").read_text(encoding="utf-8"), self.original)
        self.assertEqual((self.restore / "existing.json").read_text(), "preserved")
        self.assertFalse((self.restore / "ignore.txt").exists())

    def test_backup_creates_missing_saves_and_empty_restore(self):
        missing = self.root / "new saves"
        self.assertEqual(call("StartBackupWithTargetFile", missing, self.backup), 0)
        self.assertEqual(json.loads(self.backup.read_text()), {"files": []})
        self.assertEqual(call("RestoreBackupWithTargetFile", self.restore, self.backup), 0)
        self.assertTrue(self.restore.is_dir())

    def test_restore_rejects_invalid_json_and_schema_before_writing(self):
        for bad in ("not json", "[]", '{"files": {}}', '{"files":[{"name":"玩家一.json","content":"overwrite"},{"name":3,"content":4}]}'):
            with self.subTest(bad=bad):
                self.backup.write_text(bad, encoding="utf-8")
                self.assertEqual(call("RestoreBackupWithTargetFile", self.saves, self.backup), -2)
                self.assertEqual((self.saves / "玩家一.json").read_text(encoding="utf-8"), self.original)
                self.assertEqual(call("RestoreBackupWithTargetFile", self.restore, self.backup), -2)
                self.assertFalse(self.restore.exists())

    def test_restore_rejects_traversal_and_duplicate_names(self):
        for name in ("../escaped.json", "/tmp/escaped.json", "..\\escaped.json", "C:\\escaped.json", "nested/file.json", "name\x00.json"):
            with self.subTest(name=name):
                self.make_backup([{"name": "玩家一.json", "content": "overwrite"}, {"name": name, "content": "bad"}])
                self.assertEqual(call("RestoreBackupWithTargetFile", self.saves, self.backup), -13)
                self.assertEqual((self.saves / "玩家一.json").read_text(encoding="utf-8"), self.original)
        for names in (("SAVE.json", "save.json"), ("é.json", "e\u0301.json")):
            self.make_backup([{"name": name, "content": "x"} for name in names])
            self.assertEqual(call("RestoreBackupWithTargetFile", self.saves, self.backup), -2)

    def test_restore_and_backup_reject_existing_symlinks(self):
        self.make_backup([{"name": "玩家一.json", "content": "overwrite"}])
        outside = self.root / "outside.json"
        outside.write_text("preserved")
        (self.saves / "alias.json").symlink_to(outside)
        self.assertEqual(call("RestoreBackupWithTargetFile", self.saves, self.backup), -13)
        self.assertEqual(call("StartBackupWithTargetFile", self.saves, self.root / "new.json"), -13)
        self.assertEqual(outside.read_text(), "preserved")

    def test_failed_restore_write_preserves_original_tree(self):
        self.make_backup([{"name": "玩家一.json", "content": "overwrite"}, {"name": "blocked.json", "content": "cannot replace a directory"}])
        (self.saves / "blocked.json").mkdir()
        (self.saves / "blocked.json/keep.txt").write_text("preserved")
        self.assertNotEqual(call("RestoreBackupWithTargetFile", self.saves, self.backup), 0)
        self.assertEqual((self.saves / "玩家一.json").read_text(encoding="utf-8"), self.original)
        self.assertEqual((self.saves / "blocked.json/keep.txt").read_text(), "preserved")
        self.assertEqual(list(self.root.glob(".fvm-native-*")), [])

    def test_logging_and_missing_files(self):
        log = self.root / "日志" / "native.log"
        self.assertEqual(call("SetNativeLogFilePath", log), 0)
        self.assertEqual(call("CopyFolder", "", ""), -1)
        self.assertIn("[error_code=-1] CopyFolder", log.read_text())
        self.assertEqual(call("RestoreBackupWithTargetFile", self.saves, self.root / "missing"), 2)
        self.assertEqual(call("UnzipMapFile", self.root / "missing.zip", self.restore), -11)
        self.assertEqual(call("OpenFolder", self.root / "missing"), 2)
        self.assertEqual(call("DeleteFolder", "/"), -1)

    def test_unicode_zip_and_merge(self):
        archive = self.make_zip([("地图/关卡.json", "你好 🥕"), ("地图/art/texture.bin", b"\0\1\2")])
        self.restore.mkdir()
        (self.restore / "keep.txt").write_text("preserved")
        self.assertEqual(call("UnzipMapFile", archive, self.restore), 0)
        self.assertEqual((self.restore / "地图/关卡.json").read_text(), "你好 🥕")
        self.assertEqual((self.restore / "地图/art/texture.bin").read_bytes(), b"\0\1\2")
        self.assertEqual((self.restore / "keep.txt").read_text(), "preserved")

    def test_seven_zip(self):
        source = self.root / "7z source"
        source.mkdir()
        (source / "地图.json").write_text("七牛", encoding="utf-8")
        archive = self.root / "map.7z"
        subprocess.run(["/usr/bin/tar", "--format", "7zip", "-cf", str(archive), "-C", str(source), "."], check=True)
        self.assertEqual(call("UnzipMapFile", archive, self.restore), 0)
        self.assertEqual((self.restore / "地图.json").read_text(), "七牛")

    def test_rar_and_rar5_from_upstream_fixtures(self):
        fixtures = Path(__file__).parent / "vendor/libarchive/fixtures"
        for filename, member, expected in (
            ("test_read_format_rar_windows.rar.uu", "test.txt", b"test text file\r\n"),
            ("test_read_format_rar5_stored.rar.uu", "helloworld.txt", b"hello libarchive test suite!\n"),
        ):
            with self.subTest(format=filename):
                lines = (fixtures / filename).read_bytes().splitlines()
                archive = self.root / filename[:-3]
                archive.write_bytes(b"".join(binascii.a2b_uu(line) for line in lines[1:] if line != b"end"))
                destination = self.root / filename
                self.assertEqual(call("UnzipMapFile", archive, destination), 0)
                self.assertEqual((destination / member).read_bytes(), expected)

    def test_password_protected_archive_returns_existing_error_code(self):
        source = self.root / "secret.json"
        source.write_text("private map")
        archive = self.root / "encrypted.zip"
        subprocess.run(["/usr/bin/zip", "-j", "-q", "-P", "fixture-password", str(archive), str(source)], check=True)
        self.assertEqual(call("UnzipMapFile", archive, self.restore), -14)
        self.assertFalse(self.restore.exists())

    def test_archive_traversal_is_transactional(self):
        self.restore.mkdir()
        (self.restore / "keep.txt").write_text("preserved")
        for path in ("../escape.txt", "/tmp/escape.txt", "..\\escape.txt", "C:\\escape.txt"):
            with self.subTest(path=path):
                archive = self.make_zip([("keep.txt", "overwritten"), (path, "bad")])
                self.assertEqual(call("UnzipMapFile", archive, self.restore), -13)
                self.assertEqual((self.restore / "keep.txt").read_text(), "preserved")
                self.assertFalse((self.root / "escape.txt").exists())

    def test_archive_symlink_rejected(self):
        archive = self.root / "link.zip"
        entry = zipfile.ZipInfo("link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("valid.txt", "should not appear")
            output.writestr(entry, "../escape")
        self.assertEqual(call("UnzipMapFile", archive, self.restore), -13)
        self.assertFalse(self.restore.exists())

    def test_archive_existing_symlink_rejected(self):
        self.restore.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (self.restore / "linked").symlink_to(outside, target_is_directory=True)
        archive = self.make_zip([("linked/damage.txt", "bad")])
        self.assertEqual(call("UnzipMapFile", archive, self.restore), -13)
        self.assertFalse((outside / "damage.txt").exists())

    def test_archive_output_collision_preserves_destination(self):
        self.restore.mkdir()
        (self.restore / "blocked").write_text("preserved")
        archive = self.make_zip([("new.txt", "should not appear"), ("blocked/map.json", "map")])
        self.assertEqual(call("UnzipMapFile", archive, self.restore), -17)
        self.assertEqual((self.restore / "blocked").read_text(), "preserved")
        self.assertFalse((self.restore / "new.txt").exists())

    def test_archive_corruption_and_duplicate_rejected(self):
        archive = self.root / "bad.zip"
        archive.write_text("not an archive")
        self.assertEqual(call("UnzipMapFile", archive, self.restore), -15)
        self.assertFalse(self.restore.exists())
        duplicate = self.make_zip([("MAP.json", "first"), ("map.json", "second")])
        self.assertEqual(call("UnzipMapFile", duplicate, self.restore), -13)
        self.assertFalse(self.restore.exists())
        valid = self.make_zip([("broken.bin", bytes(range(256)) * 64)], "crc.zip")
        data = bytearray(valid.read_bytes())
        name_length = int.from_bytes(data[26:28], "little")
        extra_length = int.from_bytes(data[28:30], "little")
        data[30 + name_length + extra_length + 15] ^= 0xFF
        valid.write_bytes(data)
        self.assertEqual(call("UnzipMapFile", valid, self.restore), -12)
        self.assertFalse(self.restore.exists())


if __name__ == "__main__":
    print("Testing", LIBRARY_PATH, "on", platform.machine(), flush=True)
    unittest.main(verbosity=2)
