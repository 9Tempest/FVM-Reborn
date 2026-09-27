#!/usr/bin/env python3
"""Exercise the release launcher with a tiny real GameMaker VM in fresh sandboxes.

This is a process-level regression for the /private/tmp versus /tmp resource
path bug. It packages and unpacks a ZIP using the production packager, then runs
the bundle executable from several existing path aliases and working directories.
It does not launch or modify the installed game or access its save container.
Finder/LaunchServices App Translocation is a separate UI acceptance test: direct
process execution, including a quarantined copy, cannot prove that UI path.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fvm_launcher_helpers", HERE / "test-autosave.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
REPO = helpers.REPO
DEFAULT_RUNTIME = Path("/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-" + helpers.VERSION)


def run(command, log, **kwargs):
    with log.open("wb") as stream:
        return subprocess.run([str(arg) for arg in command], stdout=stream,
                              stderr=subprocess.STDOUT, check=True, **kwargs)


def prepare(root, runtime_arg):
    app_id = "io.github.9tempest.fvmreborn.launcher-tests." + uuid.uuid4().hex
    helpers.NAME = "FVM-Launcher-Tests"
    project_file = helpers.prepare(root, app_id)
    project = project_file.parent
    # Retain only the minimal room and its controller. No game/save GML runs.
    yyp = helpers.read_yy(project_file)
    yyp["resources"] = [r for r in yyp["resources"] if not r["id"]["path"].startswith("scripts/")]
    helpers.write_yy(project_file, yyp)
    shutil.rmtree(project / "scripts")
    (project / "objects/obj_autosave_tests/Create_0.gml").write_text('''
var _args = [];
for (var _i = 0; _i < parameter_count(); _i++) array_push(_args, parameter_string(_i));
var _path = game_save_id + "launcher-fixture-only.txt";
var _file = file_text_open_write(_path);
var _wrote = _file >= 0;
if (_wrote) { file_text_write_string(_file, "isolated launcher fixture"); file_text_close(_file); }
show_debug_message("FVM_LAUNCHER_RESULT=" + json_stringify({
    args:_args, save_root:game_save_id, working_directory:working_directory,
    wrote_sandbox_file:_wrote, read_back:_wrote && file_exists(_path)
}));
game_end();
''', encoding="utf-8")
    runtime, igor, user = helpers.toolchain(runtime_arg)
    for name in ("cache", "temp", "output", "logs"):
        (root / name).mkdir()
    run([igor, "-j=1", "/uf=" + str(user), "/lf=" + str(user / "licence.plist"),
         "/rp=" + str(runtime), "/project=" + str(project_file),
         "/cache=" + str(root / "cache"), "/temp=" + str(root / "temp"),
         "/runtime=VM", "/of=" + str(root / "output/test"), "--", "Mac", "Compile"],
        root / "logs/compile.log", cwd=project,
        env=dict(os.environ, COMPlus_ZapDisable="1"), timeout=240)
    game = next((p for p in (root / "output/assets/game.ios", root / "output/game.ios") if p.is_file()), None)
    options = next((p for p in (root / "output/assets/options.ini", root / "output/options.ini") if p.is_file()), None)
    if game is None or options is None:
        raise RuntimeError("Tiny GameMaker compile did not produce game.ios and options.ini")
    # The production packager requires the native library. It is included but
    # intentionally unused by this tiny project, which has no extensions.
    archive = root / "tiny-game.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        output.write(game, "assets/game.ios")
        output.write(options, "assets/options.ini")
        output.write(REPO / "extensions/WindowsNative/libFvmNativeSupport.dylib",
                     "assets/libFvmNativeSupport.dylib")
    manifest = {"app_id": app_id, "runtime": str(runtime),
                "game_sha256": hashlib.sha256(game.read_bytes()).hexdigest(),
                "scope": "Only a test controller executes; no production GML, user app, or user save is loaded."}
    helpers.write_yy(root / "manifest.json", manifest)
    return manifest


def execute(root, app, cwd, args, label, manifest, executable=None):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = executable or info["CFBundleExecutable"]
    command = [str(app / "Contents/MacOS" / binary), *args]
    log = root / "logs" / (label + ".log")
    with log.open("wb") as stream:
        try:
            process = subprocess.run(command, cwd=cwd, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=35)
            exit_code = process.returncode
        except subprocess.TimeoutExpired:
            exit_code = "timeout"
    output = log.read_text(encoding="utf-8", errors="replace")
    matches = re.findall(r"FVM_LAUNCHER_RESULT=(\{[^\r\n]+\})", output)
    report = json.loads(matches[-1]) if matches else None
    return {"name": label, "command": command, "cwd": str(cwd),
            "exit_code": exit_code, "log": str(log), "report": report,
            "passed": exit_code == 0 and report is not None
                      and report["wrote_sandbox_file"] and report["read_back"]
                      and manifest["app_id"] in report["save_root"]}


def capture_args(root, app, manifest, entitlements):
    """Test the execv boundary without the official runner's legacy argv parser."""
    capture = root / "capture 参数.app"
    shutil.copytree(app, capture, symlinks=True)
    capture_info = plistlib.loads((capture / "Contents/Info.plist").read_bytes())
    capture_id = manifest["app_id"] + ".argv"
    capture_info["CFBundleIdentifier"] = capture_id
    (capture / "Contents/Info.plist").write_bytes(plistlib.dumps(capture_info))
    source = root / "capture-argv.mm"
    source.write_text('''#import <Foundation/Foundation.h>
#include <cstdio>
#include <unistd.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    NSMutableArray *args = [NSMutableArray array];
    for (int i=1; i<argc; ++i) [args addObject:[NSString stringWithUTF8String:argv[i]]];
    char cwd[8192]; getcwd(cwd, sizeof(cwd));
    NSDictionary *result = @{ @"args":args, @"cwd":[NSString stringWithUTF8String:cwd],
      @"bundle_id":[NSBundle mainBundle].bundleIdentifier };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    std::printf("FVM_ARGV_RESULT=%s\\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
  return 0;
}
''', encoding="utf-8")
    runner = capture / "Contents/MacOS/Mac_Runner"
    # clang replaces this test copy only. No production executable is patched.
    runner.unlink()
    run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-framework", "Foundation", source, "-o", runner],
        root / "logs/capture-compile.log", timeout=30)
    inner_entitlements = root / "capture-inherit.entitlements.plist"
    inner_entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}))
    outer_entitlements = root / "capture-outer.entitlements.plist"
    outer_entitlements.write_bytes(plistlib.dumps(entitlements))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", capture_id + ".runner", "--entitlements", inner_entitlements, runner],
        root / "logs/capture-inner-sign.log", timeout=30)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", outer_entitlements, capture],
        root / "logs/capture-outer-sign.log", timeout=30)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", capture], root / "logs/capture-verify.log", timeout=30)
    info = plistlib.loads((capture / "Contents/Info.plist").read_bytes())
    private_capture = Path("/private/tmp") / capture.relative_to(root.parent)
    original = ["--probe", "two words", "路径参数", "quote\"inside", "", "apostrophe'inside"]
    log = root / "logs/capture-argv.log"
    run([private_capture / "Contents/MacOS" / info["CFBundleExecutable"], *original], log, cwd="/", timeout=35)
    match = re.search(r"FVM_ARGV_RESULT=(\{[^\r\n]+\})", log.read_text(encoding="utf-8", errors="replace"))
    if not match:
        raise RuntimeError("Native argument probe did not report; inspect " + str(log))
    report = json.loads(match[1])
    expected_game = str(Path("/tmp") / capture.relative_to(root.parent) / "Contents/Resources/game.ios")
    return report, original + ["-game", expected_game], capture_id


def verify(root, manifest, runtime, check_upgrade=False):
    output = root / "package" / "美食 游戏 with spaces.app"
    archive = root / "release-fixture.zip"
    if output.exists() or archive.exists():
        raise RuntimeError("Already packaged; use a fresh --reuse workspace or remove only its test package artifacts")
    run([sys.executable, HERE / "package-local.py", "--game-zip", root / "tiny-game.zip",
         "--runtime", runtime, "--output", output, "--zip", archive],
        root / "logs/package.log", timeout=120)
    extracted = root / "ZIP 解压 with spaces"
    run(["/usr/bin/ditto", "-x", "-k", archive, extracted], root / "logs/unzip.log", timeout=45)
    app = extracted / output.name
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != manifest["app_id"]:
        raise RuntimeError("Refusing to execute a bundle with an unexpected application identity")
    if info["CFBundleExecutable"] == "Mac_Runner":
        raise RuntimeError("Packaged fixture still bypasses the new native launcher")
    checks = []
    def check(name, passed, **details):
        checks.append({"name": name, "passed": bool(passed), **details})
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True)
    check("ZIP roundtrip signature", signature.returncode == 0, detail=signature.stderr)
    entitlements = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)], capture_output=True)
    actual_entitlements = plistlib.loads(entitlements.stdout)
    check("App Sandbox enabled", actual_entitlements.get("com.apple.security.app-sandbox") is True)
    lipo = subprocess.run(["/usr/bin/lipo", str(app / "Contents/MacOS" / info["CFBundleExecutable"]),
                           "-verify_arch", "arm64", "x86_64"], capture_output=True)
    check("Launcher universal arm64/x86_64", lipo.returncode == 0)
    check("Compiled payload unchanged after packaging", hashlib.sha256((app / "Contents/Resources/game.ios").read_bytes()).hexdigest() == manifest["game_sha256"])
    canonical = Path("/tmp") / app.relative_to(root.parent)
    private = Path("/private/tmp") / app.relative_to(root.parent)
    check("Real alias paths refer to same bundle", canonical.samefile(private))
    # Compare against the previous entry point at a stable non-/private path.
    # Existing-container migration is opt-in: macOS can require a UI grant when
    # an ad-hoc app changes its primary executable. A background script cannot
    # acknowledge that system dialog or establish Finder launch acceptance.
    baseline_root = Path.home() / "Library/Caches/FVM-Reborn/launcher-tests" / root.name
    baseline_app = baseline_root / "Old Runner.app"
    baseline_root.mkdir(parents=True)
    shutil.copytree(app, baseline_app, symlinks=True)
    (baseline_app / "Contents/MacOS" / info["CFBundleExecutable"]).unlink()
    shutil.copyfile(runtime / "mac/YoYo Runner.app/Contents/MacOS/Mac_Runner", baseline_app / "Contents/MacOS/Mac_Runner")
    baseline_id = manifest["app_id"] if check_upgrade else manifest["app_id"] + ".baseline"
    baseline_manifest = dict(manifest, app_id=baseline_id)
    baseline_info = dict(info, CFBundleExecutable="Mac_Runner", CFBundleIdentifier=baseline_id)
    (baseline_app / "Contents/Info.plist").write_bytes(plistlib.dumps(baseline_info))
    baseline_options = baseline_app / "Contents/Resources/options.ini"
    baseline_options.write_text(baseline_options.read_text().replace(manifest["app_id"], baseline_id))
    entitlement_file = root / "baseline.entitlements.plist"
    entitlement_file.write_bytes(plistlib.dumps(actual_entitlements))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlement_file, baseline_app],
        root / "logs/baseline-signature.log", timeout=30)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", baseline_app],
        root / "logs/baseline-verify.log", timeout=30)
    baseline = execute(root, baseline_app, Path("/"), [], "baseline_old_entry_stable_path", baseline_manifest)
    check("Old entry point reaches GML in independent test container", baseline["passed"], log=baseline["log"])
    cases = [
        ("canonical_no_args_root_cwd", canonical, Path("/"), []),
        ("private_alias_no_args_root_cwd", private, Path("/"), []),
        ("private_alias_external_cwd", private, Path("/tmp"), []),
        ("canonical_resource_cwd", canonical, canonical / "Contents/Resources", []),
        ("private_alias_arguments", private, Path("/"), ["host", "wss://example.invalid/game", "fixture-token"]),
        ("canonical_unicode_arguments", canonical, Path("/tmp"), ["--probe", "two words", "路径参数"]),
    ]
    runs = []
    for label, path, cwd, args in cases:
        result = execute(root, path, cwd, args, label, manifest)
        runs.append(result)
        check(label + " reaches GML and isolated sandbox", result["passed"], log=result["log"])
        if baseline["report"] and result["report"]:
            old_root = baseline["report"]["save_root"].replace(baseline_id, "{app_id}")
            new_root = result["report"]["save_root"].replace(manifest["app_id"], "{app_id}")
            check(label + " retains save directory convention", new_root == old_root)
        if args and label != "canonical_unicode_arguments" and result["report"]:
            reported = result["report"]["args"]
            check(label + " arguments retained", reported[:len(args)] == args, expected=args, actual=reported)
        print(label + ": " + ("PASS" if result["passed"] else "FAIL"), flush=True)
        if result["exit_code"] == "timeout":
            # Avoid repeatedly launching into a known pending sandbox/UI grant.
            raise RuntimeError("Isolated launch timed out; inspect " + result["log"] + ". No further instances launched.")
    arguments, expected_args, capture_id = capture_args(root, app, manifest, actual_entitlements)
    check("Native execv retains exact original arguments and normalizes game path", arguments["args"] == expected_args,
          expected=expected_args, actual=arguments["args"])
    expected_sandbox_cwd = str(Path.home() / "Library/Containers" / capture_id / "Data")
    check("Inner process inherits the system sandbox working directory", arguments["cwd"] == expected_sandbox_cwd)
    check("Inherited runner retains main bundle identity", arguments["bundle_id"] == capture_id)
    # The same signed old entry point, with unchanged identity/code, is now
    # reached through the existing /private/tmp alias. A failure here and a
    # passing new launcher above isolate the resource-path bug from packaging.
    old_alias_app = root / "Old Alias.app"
    shutil.copytree(baseline_app, old_alias_app, symlinks=True)
    old_alias = Path("/private/tmp") / old_alias_app.relative_to(root.parent)
    old_alias_result = execute(root, old_alias, Path("/"), [], "baseline_old_entry_private_alias", baseline_manifest)
    result = {"passed": sum(test["passed"] for test in checks), "total": len(checks),
              "tests": checks, "runs": runs, "native_arguments": arguments, "baseline_direct_runner": baseline,
              "baseline_private_alias": old_alias_result,
              "app_id": manifest["app_id"], "root": str(root),
              "same_container_upgrade": check_upgrade,
              "ui_limit": "No LaunchServices/Finder test performed. Real download quarantine and App Translocation remain separate UI acceptance checks."}
    helpers.write_yy(root / "results.json", result)
    print(str(result["passed"]) + "/" + str(result["total"]) + " launcher checks passed.")
    print("Report: " + str(root / "results.json"))
    return 0 if result["passed"] == result["total"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=DEFAULT_RUNTIME)
    parser.add_argument("--prepare-only", action="store_true", help="Compile the tiny fixture without packaging or launching")
    parser.add_argument("--reuse", type=Path, help="A workspace previously printed by --prepare-only")
    parser.add_argument("--check-upgrade", action="store_true", help="Also reuse an existing old-runner sandbox; may require an interactive macOS container access grant")
    args = parser.parse_args()
    root = args.reuse.absolute() if args.reuse else Path(tempfile.mkdtemp(prefix="fvm-launcher-", dir="/tmp"))
    print("Launcher test workspace: " + str(root), flush=True)
    manifest = json.loads((root / "manifest.json").read_text()) if args.reuse else prepare(root, args.runtime)
    if args.prepare_only:
        print("Tiny fixture prepared; no app launched.")
        return 0
    return verify(root, manifest, args.runtime, args.check_upgrade)


if __name__ == "__main__":
    sys.exit(main())
