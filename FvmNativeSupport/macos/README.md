# FVM native support for macOS

This is a native Objective-C++ replacement for `FvmNativeSupport.dll`. It exports
the same 13 C functions, uses the classic GameMaker extension ABI (`double`
results, UTF-8 string arguments), and supports macOS 11 or later on Apple Silicon
and Intel. It depends only on system Cocoa, libc++, and libarchive; it does not
load Windows DLLs or require Wine, Homebrew, or 7-Zip.

```sh
./FvmNativeSupport/macos/build.sh
python3 FvmNativeSupport/macos/test_native.py
```

The build produces an ad-hoc signed universal
`FvmNativeSupport/macos/build/libFvmNativeSupport.dylib`. Pass an output directory as
the first build argument to place it elsewhere. The app's release signing step
must sign embedded native code again with the same identity as the app. Tests
load the actual dylib and cover both the ABI and filesystem behavior. On a Mac
with Rosetta and a universal Python installed, run the same tests under
`arch -x86_64 /usr/bin/python3` to exercise the Intel slice as well.

`OpenFolder` opens Finder using `NSWorkspace`. Interactive backup and restore
use `NSOpenPanel` on AppKit's main thread. Backup chooses a folder and writes
`backup.json`, matching Windows; restore chooses a JSON file. These user-driven
dialogs require a running graphical session and are not opened by automated
tests.

`CopyFolder(source, parent)` merges into `parent / basename(source)`, matching
the Windows implementation. Backups retain the Windows format
`{"files":[{"name":"save.json","content":"raw UTF-8 save contents"}]}`. Only
top-level `.json` files are backed up. Restore merges saves and preserves
unmentioned files. Errors preserve the existing negative error codes from
`Typedef.h`; positive filesystem errors are POSIX `errno` values on macOS.

Restore validates the whole backup before writing. Copy, restore, and archive
import stage a complete merged directory beside the destination before
renaming it into place. Failed validation or extraction leaves the destination
unchanged; failed promotion attempts to restore the previous directory. If
rollback itself fails, the original directory is preserved at the location
recorded in the native log. This is not a cross-process locking protocol: do not
write the same save/import tree concurrently from another process.

Archive import supports ZIP, 7z, RAR, and RAR5 through the operating system's
libarchive. Compression methods unavailable in that system library return an
extraction error. Password-protected archives return `-14`; no password UI is
provided, matching the Windows extension. Imports reject traversal, absolute
paths, symbolic/hard links, special files, and ambiguous duplicate names.
Backups are limited to 256 MiB, archive files to 512 MiB each, expanded archives
to 2 GiB total, and both formats to 100,000 entries. Limits protect the game from
accidentally exhausting memory or disk while importing untrusted files.

The exported `DisableIme` / `EnableIme` functions intentionally return success
without changing any state: the upstream functions operate on Win32 HWND/IME
contexts. The macOS project uses GameMaker's Cocoa text input and guards those
Windows-only calls. No keyboard layout, global input source, other application's
window, or Cocoa text input context is modified.

The existing `SetNativeLogFilePath` startup call also begins one process-scoped
Foundation activity with `NSActivityUserInitiatedAllowingIdleSystemSleep`. It keeps
the initialized game eligible for normal background scheduling while hosting a
co-op session, and the token is ended at process shutdown. Repeated logger setup
does not create duplicate activities. This does not change system preferences,
prevent normal idle system/display sleep, or introduce a new Windows ABI symbol.
It improves background scheduling reliability; it is not a claim to fix GameMaker
WebSocket protocol errors or accessibility timeouts. A separate native subprocess
test observes the real Foundation begin/end calls and checks that the activity
does not request idle-system or display-sleep prevention.

Apple documents this API as the scoped way to prevent App Nap for user-initiated
work: [Prioritize Work at the App Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).

Apple's Command Line Tools SDK does not ship libarchive headers. The public
headers and small RAR test fixtures in `vendor/libarchive/` are from upstream
libarchive **v3.5.3** (https://github.com/libarchive/libarchive/tree/v3.5.3), with the
upstream `COPYING` file and per-file license notices retained. The library itself
is supplied by macOS (`/usr/lib/libarchive.2.dylib`). The existing project copy of
`json.hpp` supplies nlohmann/json, retaining its existing license.
