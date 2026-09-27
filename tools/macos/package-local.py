#!/usr/bin/env python3
"""Assemble an already compiled GameMaker VM archive for local macOS use.

Uses the official runner and Apple's signing tools. This does not compile the
project, access a GameMaker account, notarize an app, or launch the result.
"""

import argparse
import configparser
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

RUNTIME_VERSION = "2026.0.0.23"
REPO_ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.files.user-selected.read-write": True,
}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def mac_options(archive):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.read_string(archive.read("assets/options.ini").decode("utf-8-sig"))
    require(parser.has_section("Mac"), "Compiled archive has no [Mac] options.")
    result = {}
    for key, value in parser["Mac"].items():
        value = value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        result[key] = value
    require(result.get("appstore", "0") == "0", "Use GameMaker's signed distribution build for App Store packages.")
    require(result.get("enableapplesignin", "") in ("", "0"), "Apple Sign In requires a signed distribution build.")
    require(result.get("appstoreincoming", "0") == "0", "This local package does not request incoming network access.")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", result.get("appid", "")), "Compiled archive has an invalid application identifier.")
    return result


def extract_assets(archive, resources):
    """Unpack compiler assets without interpreting archive paths as host paths."""
    seen = set()
    for member in archive.infolist():
        path = PurePosixPath(member.filename)
        require(not path.is_absolute() and ".." not in path.parts and "\\" not in member.filename,
                "Unsafe path in compiled archive: " + member.filename)
        require(path.parts and path.parts[0] == "assets" and len(path.parts) > 1,
                "Unexpected entry outside assets/: " + member.filename)
        require(not stat.S_ISLNK(member.external_attr >> 16), "Archive symlinks are not supported.")
        relative = path.parts[1:]
        key = "/".join(relative).casefold()
        require(key not in seen, "Duplicate archive path: " + member.filename)
        seen.add(key)
        target = resources.joinpath(*relative)
        require(not target.is_symlink() and not any(parent.is_symlink() for parent in list(target.parents)[:len(relative)]),
                "Archive entry would traverse a symlink: " + member.filename)
        if member.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as destination:
                shutil.copyfileobj(source, destination, length=1024 * 1024)
            target.chmod(0o644)
    require((resources / "game.ios").is_file(), "Expected a VM game.ios payload in the compiled archive.")
    require((resources / "libFvmNativeSupport.dylib").is_file(), "The compiled archive lacks the macOS native extension.")


def make_icon(source, destination, temporary):
    iconset = temporary / "FVM.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            target = iconset / (f"icon_{points}x{points}{suffix}.png")
            run("/usr/bin/sips", "-z", pixels, pixels, source, "--out", target)
    run("/usr/bin/iconutil", "-c", "icns", "-o", destination, iconset)


def assemble(args):
    require(sys.platform == "darwin", "Local macOS packaging must run on macOS.")
    output = args.output.expanduser().absolute()
    archive_path = args.game_zip.expanduser().resolve(strict=True)
    runtime = args.runtime.expanduser().resolve(strict=True)
    icon = args.icon.expanduser().resolve(strict=True)
    require(output.suffix == ".app", "--output must end in .app.")
    require(not output.exists() and not output.is_symlink(), "Output already exists; choose a new --output path: " + str(output))
    zip_output = args.zip.expanduser().absolute() if args.zip else None
    if zip_output:
        require(zip_output.suffix == ".zip", "--zip must end in .zip.")
        require(not zip_output.exists() and not zip_output.is_symlink(), "ZIP output already exists: " + str(zip_output))
        require(output not in zip_output.parents, "ZIP output must be outside the app bundle.")
    receipt = json.loads((runtime / "receipt.json").read_text(encoding="utf-8"))
    require(receipt.get("mac", {}).get("Version") == RUNTIME_VERSION,
            "Install the matching GameMaker macOS module for runtime " + RUNTIME_VERSION + ".")
    runner = runtime / "mac" / "YoYo Runner.app"
    require((runner / "Contents/MacOS/Mac_Runner").is_file(), "The official VM runner is missing.")
    require(icon.is_file(), "The project macOS icon is missing.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Assemble and verify away from the installed app. Failed builds are removed;
    # existing output and the source archive/runner are never modified.
    with tempfile.TemporaryDirectory(prefix=".fvm-package-", dir=output.parent) as temp_name:
        temporary = Path(temp_name)
        app = temporary / output.name
        shutil.copytree(runner, app, symlinks=True)
        contents = app / "Contents"
        resources = contents / "Resources"
        with zipfile.ZipFile(archive_path) as archive:
            options = mac_options(archive)
            extract_assets(archive, resources)
        for filename in ("yoyorunner.config", "game.yydebug"):
            (resources / filename).unlink(missing_ok=True)
        for library in resources.glob("*.dylib"):
            shutil.move(str(library), contents / "MacOS" / library.name)
        for option, library in (("removeiap", "libYoYoIAP.dylib"), ("removegamepads", "libYoYoGamepad.dylib")):
            if options.get(option, "0") != "0":
                (contents / "Frameworks" / library).unlink(missing_ok=True)
        info_path = contents / "Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        version = ".".join(options.get(key, "0") for key in ("majorversion", "minorversion", "buildversion"))
        info.update({
            "CFBundleIdentifier": options["appid"],
            "CFBundleDisplayName": options.get("displayname", "FVM Reborn"),
            "CFBundleName": "FVM Reborn",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleIconFile": "icon.icns",
            "LSApplicationCategoryType": options.get("category", "public.app-category.games"),
            "LSMinimumSystemVersion": options.get("minversion", "13.0"),
        })
        if options.get("copyright"):
            info["NSHumanReadableCopyright"] = options["copyright"]
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=True)
        make_icon(icon, resources / "icon.icns", temporary)
        entitlements = temporary / "local.entitlements.plist"
        with entitlements.open("wb") as stream:
            plistlib.dump(ENTITLEMENTS, stream)
        # Standard inside-out signing: libraries carry no app entitlements.
        for library in sorted(contents.rglob("*.dylib")):
            run("/usr/bin/codesign", "--force", "--sign", "-", library)
        run("/usr/bin/lipo", contents / "MacOS/libFvmNativeSupport.dylib", "-verify_arch", "arm64", "x86_64")
        run("/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, app)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        staged_zip = temporary / "package.zip"
        if zip_output:
            zip_output.parent.mkdir(parents=True, exist_ok=True)
            run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, staged_zip)
        require(not output.exists() and not output.is_symlink(), "Output was created while packaging; refusing to replace it.")
        app.rename(output)
        if zip_output:
            # Exclusive creation also refuses files/symlinks created by another
            # run while this app was assembling; shutil.move may overwrite them.
            created_zip = False
            try:
                with staged_zip.open("rb") as source, zip_output.open("xb") as destination:
                    created_zip = True
                    shutil.copyfileobj(source, destination, length=1024 * 1024)
            except BaseException:
                if created_zip:
                    zip_output.unlink(missing_ok=True)
                raise
    print("Created local macOS app: " + str(output))
    print("Signature verified; App Sandbox and user-selected file access enabled.")
    if zip_output:
        print("Created local macOS ZIP: " + str(zip_output))
    print("This ad-hoc package is for local use; use Developer ID signing and notarization for normal distribution.")


def main():
    build_root = Path(os.environ.get("FVM_MACOS_BUILD_DIR", str(Path.home() / "Library/Caches/FVM-Reborn/macos")))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-zip", type=Path, default=build_root / "output/game.zip", help="GameMaker-compiled VM archive (default: build output/game.zip)")
    parser.add_argument("--runtime", type=Path, default=Path(os.environ.get("FVM_GAMEMAKER_RUNTIME", "/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + RUNTIME_VERSION)), help="Matching official GameMaker runtime directory")
    parser.add_argument("--icon", type=Path, default=REPO_ROOT / "options/mac/icons/1024.png", help="Project icon PNG")
    parser.add_argument("--output", type=Path, default=build_root / "output/FVM Reborn.app", help="New .app destination; existing output is refused")
    parser.add_argument("--zip", type=Path, help="Also write a local-use ZIP to this new path")
    args = parser.parse_args()
    try:
        assemble(args)
    except subprocess.CalledProcessError as error:
        print("Error: " + " ".join(error.cmd) + " failed.", file=sys.stderr)
        print((error.stderr or error.stdout or "").strip(), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, configparser.Error, zipfile.BadZipFile) as error:
        print("Error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
