"""Version-one wire validation. The server never executes client-supplied code."""
import json
import math
import re

VERSION = 1
MAX_MESSAGE = 1024 * 1024
MAX_PROFILE = 256 * 1024
MAX_STATE = 768 * 1024
MAX_COMMANDS = 100000
MAX_SEQ = 2147483647
ID = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")


class ProtocolError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def require(condition, code, message):
    if not condition:
        raise ProtocolError(code, message)


def string(value, field, maximum=160, minimum=1):
    require(isinstance(value, str) and minimum <= len(value) <= maximum,
            "invalid_message", f"Invalid {field}")
    return value


def integer(value, field, minimum=0, maximum=MAX_SEQ):
    # GameMaker json_stringify represents ordinary numeric values as e.g. 1.0.
    require(type(value) in (int, float) and minimum <= value <= maximum and value == int(value),
            "invalid_message", f"Invalid {field}")
    return int(value)


def identifier(value, field):
    string(value, field, 80)
    require(ID.fullmatch(value) is not None, "invalid_message", f"Invalid {field}")
    return value


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def json_object(value, field, maximum):
    require(isinstance(value, dict), "invalid_message", f"{field} must be an object")

    def walk(item, depth=0):
        require(depth <= 32, "invalid_message", f"{field} is too deeply nested")
        if isinstance(item, dict):
            for key, child in item.items():
                require(isinstance(key, str) and len(key) <= 256, "invalid_message", "Invalid object key")
                walk(child, depth + 1)
        elif isinstance(item, list):
            for child in item:
                walk(child, depth + 1)
        elif isinstance(item, float):
            require(math.isfinite(item), "invalid_message", "Non-finite number")
        else:
            require(item is None or isinstance(item, (str, int, bool)), "invalid_message", "Invalid JSON value")
    walk(value)
    try:
        serialized = encode(value)
        size = len(serialized.encode("utf-8"))
    except (ValueError, UnicodeError):
        raise ProtocolError("invalid_message", f"Invalid {field} encoding") from None
    require(size <= maximum, "message_too_large", f"{field} exceeds its limit")
    return serialized


def decode(raw):
    require(isinstance(raw, str), "invalid_message", "Send a UTF-8 JSON text frame")
    try:
        data = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, RecursionError):
        raise ProtocolError("invalid_message", "Invalid JSON") from None
    require(isinstance(data, dict), "invalid_message", "Message must be an object")
    require(type(data.get("v")) in (int, float) and data["v"] == VERSION, "protocol_version", "Unsupported protocol version")
    identifier(data.get("type"), "type")
    identifier(data.get("request_id"), "request_id")
    return data


def input_payload(action, payload):
    require(isinstance(payload, dict), "invalid_input", "Input payload must be an object")
    required = {
        "place_player": {"row", "col"},
        "place_card": {"row", "col", "card_id"},
        "shovel": {"row", "col"},
        "use_gem": {"gem_index"},
        "pause_vote": {"paused"},
    }
    optional = {"place_card": {"shape", "deck_slot", "slot_index"}, "use_gem": {"row", "col", "gem_id"}}
    require(action in required, "invalid_input", "Input action is not allowed")
    require(required[action] <= payload.keys() and payload.keys() <= required[action] | optional.get(action, set()),
            "invalid_input", "Unexpected or missing input fields")
    for key, value in payload.items():
        if key == "row": integer(value, key, 0, 63)
        elif key == "col": integer(value, key, 0, 127)
        elif key == "shape": integer(value, key, 0, 32)
        elif key in ("deck_slot", "slot_index", "gem_index"): integer(value, key, 0, 31)
        elif key == "paused": require(type(value) is bool, "invalid_input", "paused must be boolean")
        else: identifier(value, key)
    return encode(payload)
