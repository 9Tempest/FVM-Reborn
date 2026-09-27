/// Native paths share GameMaker's writable save area on macOS.
function NativeUtil() constructor {
    /// @param {String} _path
    /// @returns {String}
    static normalize_path = function(_path) {
        _path = string_replace_all(string(_path), "\\", "/")
        if (os_type == os_windows) {
            return string_replace_all(_path, "/", "\\")
        }
        return _path
    }

    /// @returns {String} Absolute writable root, with a trailing separator.
    static save_root = function() {
        var _root = game_save_id
        if (os_type == os_windows) {
            // Retain the existing Windows save location and migration contract.
            _root = environment_get_variable("LOCALAPPDATA") + "/FVM_Reborn/"
        }
        _root = string_replace_all(_root, "\\", "/")
        if (!string_ends_with(_root, "/")) _root += "/"
        return self.normalize_path(_root)
    }

    /// @param {String} _rel A save-relative path, or an absolute native path.
    /// @returns {String}
    static to_native_absolute = function(_rel) {
        _rel = string_replace_all(string(_rel), "\\", "/")
        if (os_type == os_windows) {
            if (string_pos(":", _rel) > 0 || string_starts_with(_rel, "//")) {
                return self.normalize_path(_rel)
            }
        } else if (string_starts_with(_rel, "/")) {
            return self.normalize_path(_rel)
        }
        while (string_starts_with(_rel, "/")) _rel = string_delete(_rel, 1, 1)
        return self.normalize_path(self.save_root() + _rel)
    }

    /// Compatibility for older callers that pass a LOCALAPPDATA suffix.
    static get_path_in_local_appdata = function(_path) {
        _path = string_replace_all(string(_path), "\\", "/")
        while (string_starts_with(_path, "/")) _path = string_delete(_path, 1, 1)
        if (_path == "FVM_Reborn") _path = ""
        else if (string_starts_with(_path, "FVM_Reborn/")) {
            _path = string_delete(_path, 1, string_length("FVM_Reborn/"))
        }
        return self.to_native_absolute(_path)
    }

    /// Kept for existing callers; only Windows receives backslashes.
    static transfer_path_to_windows = function(_path) {
        return self.normalize_path(_path)
    }

    static show_error = function(_code, _msg) {
        show_message_async(_msg + " code: " + string(_code))
    }
}
