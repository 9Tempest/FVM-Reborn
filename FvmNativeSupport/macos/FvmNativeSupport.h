#pragma once

// GameMaker's classic extension ABI: UTF-8 strings and double return values.
#if defined(__cplusplus)
#define FVM_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define FVM_EXPORT __attribute__((visibility("default")))
#endif

FVM_EXPORT double OpenFolder(const char *path);
FVM_EXPORT double FolderExists(const char *path);
FVM_EXPORT double FileExists(const char *path);
FVM_EXPORT double CopyFolder(const char *source, const char *destination);
FVM_EXPORT double DeleteFolder(const char *path);
FVM_EXPORT double StartBackupWithTargetFile(const char *saves_dir, const char *target_file);
FVM_EXPORT double StartBackup(const char *saves_dir);
FVM_EXPORT double RestoreBackupWithTargetFile(const char *saves_dir, const char *target_file);
FVM_EXPORT double RestoreBackup(const char *saves_dir, const char *default_backup_dir);
FVM_EXPORT double SetNativeLogFilePath(const char *path);
FVM_EXPORT double DisableIme(double window_handle);
FVM_EXPORT double EnableIme(double window_handle);
FVM_EXPORT double UnzipMapFile(const char *archive_path, const char *destination);
