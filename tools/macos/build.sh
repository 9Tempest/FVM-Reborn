#!/usr/bin/env bash
# Build with the same GameMaker LTS toolchain as FVM-reborn.yyp.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: tools/macos/build.sh [doctor|native|compile|run|package|package-local]

  doctor   Check the local GameMaker runtime and signed-in user setup.
  native   Build and install the macOS extension without GameMaker login.
  compile  Compile the game without starting it.
  run      Compile and start the native macOS game (default).
  package  Build a macOS ZIP package with your distribution signing identity.
  package-local  Build a sandboxed, ad-hoc signed app for this Mac.

Environment overrides:
  FVM_GAMEMAKER_RUNTIME  Directory for runtime-2026.0.0.23.
  FVM_GAMEMAKER_USER     Signed-in GameMaker user directory with licence.plist.
  FVM_MACOS_BUILD_DIR    Build/cache/output directory (default: ~/Library/Caches/FVM-Reborn/macos).
  FVM_GAMEMAKER_OUTPUT   VM (default) or YYC; YYC requires full Xcode.
  FVM_GAMEMAKER_JOBS     Compiler workers (default: 1 for macOS stability).

Sign in through GameMaker LTS 2026 before compiling, running, or packaging.
This script never creates a licence or requests account credentials.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

action="${1:-run}"
case "$action" in
    -h|--help|help) usage; exit 0 ;;
    doctor|native|compile|run|package|package-local) ;;
    *) usage >&2; fail "Unknown action: $action" ;;
esac
[[ $# -le 1 ]] || fail 'Pass only one action.'
[[ "$(uname -s)" == Darwin ]] || fail 'This script must run on macOS.'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
project="$repo_root/FVM-reborn.yyp"
[[ -f "$project" ]] || fail "Project file is missing: $project"

required_runtime=2026.0.0.23
build_root="${FVM_MACOS_BUILD_DIR:-$HOME/Library/Caches/FVM-Reborn/macos}"
case "$build_root" in /*) ;; *) build_root="$PWD/$build_root" ;; esac
runtime_output="${FVM_GAMEMAKER_OUTPUT:-VM}"
[[ "$action" != package-local || "$runtime_output" == VM ]] || fail 'package-local requires the VM runtime. Use package for YYC.'
case "$runtime_output" in VM|YYC) ;; *) fail 'FVM_GAMEMAKER_OUTPUT must be VM or YYC.' ;; esac

resolve_runtime() {
    runtime_root="${FVM_GAMEMAKER_RUNTIME:-/Users/Shared/GameMakerStudio2-LTS2026/Cache/runtimes/runtime-$required_runtime}"
    [[ -d "$runtime_root" ]] || fail "Install GameMaker LTS 2026 runtime $required_runtime with the macOS module. Set FVM_GAMEMAKER_RUNTIME for a custom location."
    runtime_root="$(cd -- "$runtime_root" && pwd)"
    case "$(uname -m)" in
        arm64) igor_arch=arm64 ;;
        x86_64) igor_arch=x64 ;;
        *) fail 'Only Apple Silicon and Intel Macs are supported.' ;;
    esac
    igor="$runtime_root/bin/igor/osx/$igor_arch/Igor"
    [[ -x "$igor" ]] || fail "The matching $igor_arch Igor executable is missing from the runtime."
    [[ -f "$runtime_root/receipt.json" ]] || fail 'Runtime receipt.json is missing; reinstall this runtime through GameMaker.'
    command -v python3 >/dev/null || fail 'Python 3 is required to validate the runtime receipt.'
    python3 - "$runtime_root/receipt.json" "$required_runtime" "$igor_arch" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        receipt = json.load(stream)
    required = ("base", "base-module-osx-" + sys.argv[3], "mac")
    if any(receipt.get(name, {}).get("Version") != sys.argv[2] for name in required):
        raise ValueError("missing or mismatched runtime modules")
except (OSError, ValueError, TypeError, AttributeError):
    sys.exit("Error: Install all matching base, host tools, and macOS modules for runtime " + sys.argv[2] + ".")
PY
}

is_signed_in_folder() {
    [[ -d "$1" && -s "$1/licence.plist" ]] || return 1
    case "$(basename -- "$1")" in
        unknownUser_unknownUserID|guest|Guest) return 1 ;;
    esac
}

resolve_user() {
    if [[ -n "${FVM_GAMEMAKER_USER:-}" ]]; then
        is_signed_in_folder "$FVM_GAMEMAKER_USER" || fail 'FVM_GAMEMAKER_USER must name a signed-in user folder containing a nonempty licence.plist.'
        user_root="$(cd -- "$FVM_GAMEMAKER_USER" && pwd)"
    else
        user_candidates=()
        for candidate in "$HOME/Library/Application Support/GameMakerStudio2-LTS2026/"*; do
            if is_signed_in_folder "$candidate"; then user_candidates+=("$candidate"); fi
        done
        case "${#user_candidates[@]}" in
            0) fail 'No signed-in GameMaker LTS 2026 user licence found. Open GameMaker, sign in, then run this command again.' ;;
            1) user_root="${user_candidates[0]}" ;;
            *) fail 'Multiple GameMaker user licences found. Set FVM_GAMEMAKER_USER to the account folder you want to use.' ;;
        esac
    fi
    # Igor performs the actual entitlement/expiry validation. Do not print,
    # rewrite, copy, or interpret the contents of this account licence here.
    licence_file="$user_root/licence.plist"
}

build_native() {
    local native_script="$repo_root/FvmNativeSupport/macos/build.sh"
    local native_output="$build_root/native/libFvmNativeSupport.dylib"
    local extension_output="$repo_root/extensions/WindowsNative/libFvmNativeSupport.dylib"
    [[ -f "$native_script" ]] || fail 'The macOS native extension source/build script is missing.'
    xcrun --find clang++ >/dev/null 2>&1 || fail 'Install Apple Command Line Tools with xcode-select --install first.'
    mkdir -p "$build_root/native"
    bash "$native_script" "$build_root/native"
    [[ -f "$native_output" ]] || fail 'The native build did not produce libFvmNativeSupport.dylib.'
    lipo "$native_output" -verify_arch arm64 x86_64
    codesign --verify "$native_output"
    cp "$native_output" "$extension_output"
    printf 'Installed universal macOS extension: %s\n' "$extension_output"
}

if [[ "$action" == native ]]; then
    build_native
    python3 "$repo_root/FvmNativeSupport/macos/test_native.py" "$build_root/native/libFvmNativeSupport.dylib"
    exit 0
fi

resolve_runtime
resolve_user
if [[ "$runtime_output" == YYC ]]; then
    xcodebuild -version >/dev/null 2>&1 || fail 'YYC requires full Xcode. Use the default VM build for local testing with Command Line Tools.'
fi
printf 'GameMaker runtime: %s (%s)\n' "$required_runtime" "$igor_arch"
printf 'GameMaker user licence found; Igor will validate it at build time.\n'
if [[ "$action" == doctor ]]; then
    printf 'Ready for a %s build.\n' "$runtime_output"
    exit 0
fi

umask 077
mkdir -p "$build_root/cache" "$build_root/temp" "$build_root/output" "$build_root/logs"
build_native

case "$action" in
    compile) igor_action=Compile ;;
    run) igor_action=Run ;;
    package|package-local) igor_action=PackageZip ;;
esac
igor_args=(
    "-j=${FVM_GAMEMAKER_JOBS:-1}"
    "/uf=$user_root"
    "/lf=$licence_file"
    "/rp=$runtime_root"
    "/project=$project"
    "/cache=$build_root/cache"
    "/temp=$build_root/temp"
    "/runtime=$runtime_output"
    "/of=$build_root/output/FVM_Reborn"
)
if [[ "$action" == package || "$action" == package-local ]]; then
    igor_args+=("/tf=$build_root/output/FVM_Reborn-macOS.zip")
fi
log_file="$build_root/logs/$(date +%Y%m%d-%H%M%S)-$action-$$.log"
printf 'Building macOS %s with GameMaker %s.\n' "$runtime_output" "$igor_action"
printf 'Build log: %s\n' "$log_file"
cd -- "$repo_root"
build_started="$build_root/temp/build-started-$$"
touch "$build_started"
set +e
# Match YoYoGames/gm-cli: avoid precompiled .NET image crashes on macOS.
COMPlus_ZapDisable=1 "$igor" "${igor_args[@]}" -- Mac "$igor_action" 2>&1 | tee "$log_file"
pipeline_status=("${PIPESTATUS[@]}")
set -e
if [[ "${pipeline_status[0]}" -ne 0 ]]; then
    # Oven requires a Developer ID for its distribution entitlements. Only this
    # exact post-compilation failure may continue to our local signing step.
    if [[ "$action" == package-local && "$build_root/output/game.zip" -nt "$build_started" ]] \
        && /usr/bin/grep -Fq 'Selected entitlements require explicit Signing Identifier.' "$log_file"; then
        printf 'Game data compiled; assembling a locally signed app.\n'
    else
        printf 'GameMaker failed (exit %s). See the build log above.\n' "${pipeline_status[0]}" >&2
        exit "${pipeline_status[0]}"
    fi
fi
[[ "${pipeline_status[1]}" -eq 0 ]] || fail 'The build log could not be written.'
if [[ "$action" == package-local ]]; then
    local_output="$build_root/output/local-$(date +%Y%m%d-%H%M%S)-$$"
    python3 "$script_dir/package-local.py" \
        --game-zip "$build_root/output/game.zip" --runtime "$runtime_root" \
        --output "$local_output/FVM Reborn.app"
else
    printf 'GameMaker %s completed. Output: %s\n' "$igor_action" "$build_root/output"
fi
rm -f -- "$build_started"
