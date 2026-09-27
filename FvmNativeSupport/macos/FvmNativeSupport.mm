#import <Cocoa/Cocoa.h>
#include "FvmNativeSupport.h"
#include "archive.h"
#include "archive_entry.h"
#include "json.hpp"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
namespace fs = std::filesystem;
using json = nlohmann::json;
// Keep these values in sync with ../FvmNativeSupport/Typedef.h.
enum Error {
  Ok = 0, InvalidArgument = -1, JsonParseFailed = -2,
  OperationCancelled = -3, EncodingFailed = -4, UnknownFailure = -5,
  InvalidArchive = -11, ExtractFailed = -12, PathTraversal = -13,
  PasswordRequired = -14, UnsupportedFormat = -15, OpenFailed = -16,
  FileCreateFailed = -17
};
struct Failure : std::runtime_error {
  int code;
  Failure(int value, const std::string &message) : runtime_error(message), code(value) {}
};
std::mutex log_mutex;
std::string log_path;
constexpr uint64_t kMaxBackupBytes = 256ull * 1024 * 1024;
constexpr uint64_t kMaxArchiveBytes = 2ull * 1024 * 1024 * 1024;
constexpr uint64_t kMaxArchiveFileBytes = 512ull * 1024 * 1024;
constexpr size_t kMaxEntries = 100000;

void log_error(int code, const std::string &message) noexcept {
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    if (log_path.empty()) return;
    // O_NOFOLLOW prevents a log symlink from overwriting an unrelated file.
    int fd = open(log_path.c_str(), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    std::string line = "[error_code=" + std::to_string(code) + "] " + message + "\n";
    (void)write(fd, line.data(), line.size());
    close(fd);
  } catch (...) {}
}

template<class Function> double invoke(const char *operation, Function body) noexcept {
  @autoreleasepool {
    @try {
      try { return static_cast<double>(body()); }
      catch (const Failure &e) { log_error(e.code, std::string(operation) + ": " + e.what()); return e.code; }
      catch (const fs::filesystem_error &e) {
        int code = e.code().value() ? e.code().value() : UnknownFailure;
        log_error(code, std::string(operation) + ": " + e.what()); return code;
      }
      catch (const std::exception &e) { log_error(UnknownFailure, std::string(operation) + ": " + e.what()); return UnknownFailure; }
      catch (...) { log_error(UnknownFailure, operation); return UnknownFailure; }
    } @catch (NSException *exception) {
      log_error(UnknownFailure, std::string(operation) + ": " + exception.reason.UTF8String);
      return UnknownFailure;
    }
  }
}

fs::path path_arg(const char *value) {
  if (!value || !*value) throw Failure(InvalidArgument, "empty path");
  if (![NSString stringWithUTF8String:value]) throw Failure(EncodingFailed, "path is not UTF-8");
  fs::path path = fs::absolute(fs::u8path(value)).lexically_normal();
  while (path != path.root_path() && path.filename().empty()) path = path.parent_path();
  // Resolve the caller-selected parent (including macOS /var and /tmp aliases).
  // The selected leaf and all descendants are still checked for symlinks.
  return fs::weakly_canonical(path.parent_path()) / path.filename();
}

void reject_link(const fs::path &path) {
  if (fs::is_symlink(fs::symlink_status(path))) throw Failure(PathTraversal, "symbolic links are not permitted: " + path.string());
}

void validate_tree(const fs::path &path) {
  reject_link(path);
  if (!fs::exists(path)) return;
  if (!fs::is_directory(path)) throw Failure(ENOTDIR, "expected directory: " + path.string());
  for (const auto &item : fs::recursive_directory_iterator(path)) {
    auto status = item.symlink_status();
    if (!fs::is_directory(status) && !fs::is_regular_file(status))
      throw Failure(PathTraversal, "non-regular entry: " + item.path().string());
  }
}

bool contains_path(const fs::path &parent, const fs::path &child) {
  auto p = parent.begin(), c = child.begin();
  for (; p != parent.end(); ++p, ++c) if (c == child.end() || *p != *c) return false;
  return true;
}

void copy_contents(const fs::path &source, const fs::path &destination) {
  validate_tree(source);
  fs::create_directories(destination);
  for (const auto &item : fs::recursive_directory_iterator(source)) {
    fs::path target = destination / item.path().lexically_relative(source);
    reject_link(target);
    if (item.is_directory()) fs::create_directories(target);
    else fs::copy_file(item.path(), target, fs::copy_options::overwrite_existing);
  }
}

struct TemporaryDirectory {
  fs::path path;
  bool preserve = false;
  explicit TemporaryDirectory(const fs::path &parent) {
    fs::create_directories(parent);
    std::string pattern = (parent / ".fvm-native-XXXXXX").string();
    std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back(0);
    char *created = mkdtemp(buffer.data());
    if (!created) throw Failure(errno, "cannot create staging directory");
    path = created;
  }
  ~TemporaryDirectory() {
    if (!preserve) { std::error_code ignored; fs::remove_all(path, ignored); }
  }
};

void promote_tree(TemporaryDirectory &temp, const fs::path &staged, const fs::path &target) {
  reject_link(target);
  bool existed = fs::exists(target);
  fs::path previous = temp.path / "previous";
  if (existed) fs::rename(target, previous);
  try { fs::rename(staged, target); }
  catch (...) {
    if (existed) {
      std::error_code error; fs::rename(previous, target, error);
      if (error) {
        temp.preserve = true;
        log_error(error.value(), "Original data preserved at " + previous.string());
      }
    }
    throw;
  }
}

void transactional_merge(const fs::path &source, const fs::path &destination) {
  validate_tree(source);
  validate_tree(destination);
  TemporaryDirectory temp(destination.parent_path());
  fs::path staged = temp.path / "merged";
  fs::create_directory(staged);
  if (fs::exists(destination)) copy_contents(destination, staged);
  copy_contents(source, staged);
  promote_tree(temp, staged, destination);
}

std::string read_file(const fs::path &path, uint64_t limit = kMaxBackupBytes) {
  reject_link(path);
  if (!fs::is_regular_file(path)) throw Failure(ENOENT, "file not found: " + path.string());
  if (fs::file_size(path) > limit) throw Failure(InvalidArgument, "file exceeds size limit");
  std::ifstream input(path, std::ios::binary);
  if (!input) throw Failure(errno ? errno : EIO, "cannot open file");
  std::string content((std::istreambuf_iterator<char>(input)), {});
  if (input.bad()) throw Failure(EIO, "cannot read file");
  return content;
}

void write_file(const fs::path &path, const std::string &content) {
  int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (fd < 0) throw Failure(errno, "cannot create file: " + path.string());
  size_t offset = 0;
  while (offset < content.size()) {
    ssize_t written = write(fd, content.data() + offset, content.size() - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) { int code = errno ? errno : EIO; close(fd); throw Failure(code, "cannot write file"); }
    offset += static_cast<size_t>(written);
  }
  if (fsync(fd) != 0) { int code = errno; close(fd); throw Failure(code, "cannot flush file"); }
  if (close(fd) != 0) throw Failure(errno, "cannot close file");
}

bool safe_save_name(const std::string &name) {
  return !name.empty() && name != "." && name != ".." &&
    name.find_first_of("/\\:") == std::string::npos && name.find('\0') == std::string::npos &&
    fs::u8path(name).extension() == ".json";
}

// APFS commonly compares names case-insensitively and normalizes Unicode.
// Reject ambiguous duplicates before restoring any file.
std::string filename_key(const std::string &name) {
  NSString *text = [NSString stringWithUTF8String:name.c_str()];
  if (!text) throw Failure(EncodingFailed, "filename is not UTF-8");
  return text.precomposedStringWithCanonicalMapping.lowercaseString.UTF8String;
}

int backup(const fs::path &saves, const fs::path &target) {
  validate_tree(saves);
  reject_link(target);
  fs::create_directories(saves);
  json output = {{"files", json::array()}};
  std::vector<fs::path> files;
  for (const auto &entry : fs::directory_iterator(saves)) {
    if (entry.is_regular_file() && entry.path().extension() == ".json") files.push_back(entry.path());
  }
  std::sort(files.begin(), files.end());
  uint64_t total = 0;
  for (const auto &path : files) {
    std::string content = read_file(path);
    total += content.size();
    if (total > kMaxBackupBytes || files.size() > kMaxEntries) throw Failure(InvalidArgument, "backup exceeds size limit");
    output["files"].push_back({{"name", path.filename().string()}, {"content", content}});
  }
  std::string serialized = output.dump(4);
  if (serialized.size() > kMaxBackupBytes) throw Failure(InvalidArgument, "serialized backup exceeds size limit");
  TemporaryDirectory temp(target.parent_path());
  fs::path staged = temp.path / "backup.json";
  write_file(staged, serialized);
  fs::rename(staged, target); // Same-volume atomic replacement; prior backup survives write failure.
  return Ok;
}

int restore(const fs::path &saves, const fs::path &target) {
  std::string content = read_file(target);
  json input;
  try { input = json::parse(content); }
  catch (...) { throw Failure(JsonParseFailed, "invalid backup JSON"); }
  if (!input.is_object() || !input.contains("files") || !input["files"].is_array() || input["files"].size() > kMaxEntries)
    throw Failure(JsonParseFailed, "backup requires a files array");
  std::set<std::string> names;
  for (const auto &entry : input["files"]) {
    if (!entry.is_object() || !entry.contains("name") || !entry.contains("content") || !entry["name"].is_string() || !entry["content"].is_string())
      throw Failure(JsonParseFailed, "backup entries require string name and content");
    const std::string &name = entry["name"].get_ref<const std::string &>();
    if (!safe_save_name(name)) throw Failure(PathTraversal, "invalid save filename");
    if (!names.insert(filename_key(name)).second) throw Failure(JsonParseFailed, "duplicate save filename");
  }
  validate_tree(saves);
  TemporaryDirectory temp(saves.parent_path());
  fs::path staged = temp.path / "restored";
  fs::create_directory(staged);
  if (fs::exists(saves)) copy_contents(saves, staged);
  for (const auto &entry : input["files"])
    write_file(staged / fs::u8path(entry["name"].get<std::string>()), entry["content"].get<std::string>());
  promote_tree(temp, staged, saves);
  return Ok;
}

void on_main(dispatch_block_t action) {
  if ([NSThread isMainThread]) action();
  else dispatch_sync(dispatch_get_main_queue(), action);
}

std::string choose_path(bool directory, const char *default_directory) {
  __block std::string result;
  // GameMaker normally calls on its main thread. The dispatch also supports
  // callers using a worker thread while AppKit's main run loop is running.
  on_main(^{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = directory;
    panel.canChooseFiles = !directory;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = directory;
    panel.title = directory ? @"选择备份文件夹" : @"选择存档备份";
    if (!directory) panel.allowedFileTypes = @[@"json"];
    if (default_directory && *default_directory) {
      NSString *path = [NSString stringWithUTF8String:default_directory];
      if (path) panel.directoryURL = [NSURL fileURLWithPath:path isDirectory:YES];
    }
    if ([panel runModal] == NSModalResponseOK) result = panel.URL.path.UTF8String;
  });
  return result;
}

fs::path archive_relative_path(const char *value) {
  if (!value || !*value) throw Failure(PathTraversal, "empty archive pathname");
  if (![NSString stringWithUTF8String:value]) throw Failure(EncodingFailed, "archive filename is not UTF-8");
  std::string text(value);
  std::replace(text.begin(), text.end(), '\\', '/');
  if (text.front() == '/' || text.find(':') != std::string::npos) throw Failure(PathTraversal, "absolute archive pathname");
  fs::path relative = fs::u8path(text);
  for (const auto &component : relative) if (component == "..") throw Failure(PathTraversal, "archive path traversal");
  return relative.lexically_normal();
}

int archive_error_code(archive *reader, int fallback) {
  const char *message = archive_error_string(reader);
  std::string text = message ? message : "";
  std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
  return (text.find("passphrase") != std::string::npos || text.find("password") != std::string::npos || archive_read_has_encrypted_entries(reader) > 0)
    ? PasswordRequired : fallback;
}

int extract(const fs::path &input, const fs::path &destination) {
  reject_link(input);
  if (!fs::is_regular_file(input)) throw Failure(InvalidArchive, "archive does not exist");
  validate_tree(destination);
  std::unique_ptr<archive, decltype(&archive_read_free)> reader(archive_read_new(), archive_read_free);
  if (!reader) throw Failure(UnknownFailure, "cannot allocate archive reader");
  archive_read_support_filter_all(reader.get());
  archive_read_support_format_zip(reader.get());
  archive_read_support_format_7zip(reader.get());
  archive_read_support_format_rar(reader.get());
  archive_read_support_format_rar5(reader.get());
  if (archive_read_open_filename(reader.get(), input.c_str(), 10240) != ARCHIVE_OK)
    throw Failure(archive_error_code(reader.get(), UnsupportedFormat), "cannot open archive");
  TemporaryDirectory temp(destination.parent_path());
  fs::path unpacked = temp.path / "unpacked";
  fs::create_directory(unpacked);
  uint64_t total = 0;
  size_t entries = 0;
  std::set<std::string> file_names;
  archive_entry *entry = nullptr;
  for (;;) {
    int status = archive_read_next_header(reader.get(), &entry);
    if (status == ARCHIVE_EOF) break;
    if (status != ARCHIVE_OK) throw Failure(archive_error_code(reader.get(), ExtractFailed), "invalid archive header");
    if (++entries > kMaxEntries) throw Failure(ExtractFailed, "archive has too many entries");
    if (archive_entry_is_encrypted(entry)) throw Failure(PasswordRequired, "encrypted archives require a password");
    if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) throw Failure(PathTraversal, "archive links are not permitted");
    auto type = archive_entry_filetype(entry);
    if (type != AE_IFDIR && type != AE_IFREG) throw Failure(PathTraversal, "archive entry is not a regular file or directory");
    const char *name = archive_entry_pathname_utf8(entry);
    if (!name) name = archive_entry_pathname(entry);
    fs::path relative = archive_relative_path(name);
    if (relative.empty() || relative == ".") {
      if (type != AE_IFDIR) throw Failure(PathTraversal, "empty archive filename");
      continue;
    }
    fs::path output = unpacked / relative;
    if (type == AE_IFDIR) { fs::create_directories(output); continue; }
    if (!file_names.insert(filename_key(relative.string())).second) throw Failure(PathTraversal, "duplicate archive filename");
    la_int64_t declared_size = archive_entry_size(entry);
    if (declared_size < 0 || static_cast<uint64_t>(declared_size) > kMaxArchiveFileBytes)
      throw Failure(ExtractFailed, "archive file exceeds size limit");
    fs::create_directories(output.parent_path());
    int fd = open(output.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) throw Failure(FileCreateFailed, "cannot create archive output");
    uint64_t file_total = 0;
    try {
      char buffer[64 * 1024];
      for (;;) {
        la_ssize_t count = archive_read_data(reader.get(), buffer, sizeof buffer);
        if (count == 0) break;
        if (count < 0) throw Failure(archive_error_code(reader.get(), ExtractFailed), "cannot decompress archive data");
        total += count; file_total += count;
        if (total > kMaxArchiveBytes || file_total > kMaxArchiveFileBytes) throw Failure(ExtractFailed, "expanded archive exceeds size limit");
        size_t offset = 0;
        while (offset < static_cast<size_t>(count)) {
          ssize_t wrote = write(fd, buffer + offset, static_cast<size_t>(count) - offset);
          if (wrote < 0 && errno == EINTR) continue;
          if (wrote <= 0) throw Failure(FileCreateFailed, "cannot write archive output");
          offset += static_cast<size_t>(wrote);
        }
      }
      if (fsync(fd) != 0) throw Failure(FileCreateFailed, "cannot flush archive output");
    } catch (...) { close(fd); throw; }
    if (close(fd) != 0) throw Failure(FileCreateFailed, "cannot close archive output");
  }
  if (archive_read_close(reader.get()) != ARCHIVE_OK) throw Failure(ExtractFailed, "archive did not finish cleanly");
  transactional_merge(unpacked, destination);
  return Ok;
}
} // namespace

double SetNativeLogFilePath(const char *value) {
  return invoke(__func__, [&] {
    fs::path path = path_arg(value); reject_link(path);
    fs::create_directories(path.parent_path());
    std::lock_guard<std::mutex> lock(log_mutex); log_path = path.string(); return Ok;
  });
}
double OpenFolder(const char *value) {
  return invoke(__func__, [&] {
    fs::path path = path_arg(value);
    if (!fs::is_directory(path)) throw Failure(ENOENT, "folder does not exist");
    __block BOOL opened = NO;
    on_main(^{ opened = [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()] isDirectory:YES]]; });
    return opened ? Ok : OpenFailed;
  });
}
double FolderExists(const char *value) {
  @autoreleasepool { try { return fs::is_directory(path_arg(value)) ? 1.0 : 0.0; } catch (...) { return 0.0; } }
}
double FileExists(const char *value) {
  @autoreleasepool { try { return fs::is_regular_file(path_arg(value)) ? 1.0 : 0.0; } catch (...) { return 0.0; } }
}
double CopyFolder(const char *source_value, const char *destination_value) {
  return invoke(__func__, [&] {
    fs::path source = path_arg(source_value);
    fs::path parent = path_arg(destination_value);
    reject_link(parent);
    fs::path destination = parent / source.filename();
    if (!fs::is_directory(source)) throw Failure(ENOENT, "source directory does not exist");
    if (contains_path(source, destination) || contains_path(destination, source)) throw Failure(InvalidArgument, "source and destination overlap");
    transactional_merge(source, destination); return Ok;
  });
}
double DeleteFolder(const char *value) {
  return invoke(__func__, [&] {
    fs::path path = path_arg(value);
    if (path == path.root_path() || path == fs::path(NSHomeDirectory().UTF8String) || path == fs::current_path())
      throw Failure(InvalidArgument, "refusing to delete a root, home, or current directory");
    reject_link(path);
    if (fs::exists(path) && !fs::is_directory(path)) throw Failure(ENOTDIR, "expected a directory");
    fs::remove_all(path); return Ok; // remove_all unlinks internal symlinks without following them.
  });
}
double StartBackupWithTargetFile(const char *saves, const char *target) {
  return invoke(__func__, [&] { return backup(path_arg(saves), path_arg(target)); });
}
double RestoreBackupWithTargetFile(const char *saves, const char *target) {
  return invoke(__func__, [&] { return restore(path_arg(saves), path_arg(target)); });
}
double StartBackup(const char *saves_value) {
  return invoke(__func__, [&] {
    fs::path saves = path_arg(saves_value);
    std::string selected = choose_path(true, nullptr);
    if (selected.empty()) return OperationCancelled;
    return static_cast<Error>(backup(saves, path_arg(selected.c_str()) / "backup.json"));
  });
}
double RestoreBackup(const char *saves_value, const char *default_directory) {
  return invoke(__func__, [&] {
    fs::path saves = path_arg(saves_value);
    std::string selected = choose_path(false, default_directory);
    if (selected.empty()) return OperationCancelled;
    return static_cast<Error>(restore(saves, path_arg(selected.c_str())));
  });
}
// Windows HWND/ImmAssociateContext operations have no Cocoa equivalent. Keep
// the ABI for existing projects; macOS uses GameMaker's native text input.
// These functions intentionally never change global input sources or windows.
double DisableIme(double) { return 0; }
double EnableIme(double) { return 0; }
double UnzipMapFile(const char *archive_value, const char *destination) {
  return invoke(__func__, [&] {
    fs::path archive = path_arg(archive_value), output = path_arg(destination);
    try { return extract(archive, output); }
    catch (const Failure &error) {
      if (error.code > 0) throw Failure(FileCreateFailed, error.what());
      throw;
    }
    catch (const fs::filesystem_error &error) { throw Failure(FileCreateFailed, error.what()); }
    catch (const std::exception &error) { throw Failure(ExtractFailed, error.what()); }
  });
}
