"""Version-one wire validation. The server never executes client-supplied code."""
import base64
import binascii
import json
import math
import re
import struct
import zlib

VERSION = 1
MAX_MESSAGE = 1024 * 1024
MAX_PROFILE = 256 * 1024
MAX_STATE = 768 * 1024
MAX_COMMANDS = 100000
MAX_SEQ = 2147483647
MAX_DECK = 31
MAX_SCREEN_BASE64 = 700 * 1024
SCREEN_INTERVAL = 0.25
SCREEN_ROOMS = frozenset(("room_menu", "room_map", "room_tower_cake", "room_laboratory"))
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


def campaign_progress(profile):
    """Play time changes every frame and must not invalidate a confirmed deck."""
    result = dict(profile)
    if isinstance(result.get("player"), dict):
        result["player"] = {key: value for key, value in result["player"].items() if key != "total_time"}
    return result


def card_library(profile):
    cards, items = profile.get("unlocked_cards"), profile.get("unlocked_items")
    require(isinstance(cards, list) and isinstance(items, dict), "invalid_library", "Host profile has no card library")
    limit = integer(items.get("max_slot"), "max_slot", 1, MAX_DECK)
    allowed = set()
    for card in cards:
        require(isinstance(card, dict), "invalid_library", "Invalid unlocked card")
        allowed.add(identifier(card.get("id"), "card_id"))
    return allowed, limit


def loadout_deck(deck, allowed, limit, ready=False):
    require(isinstance(deck, list) and len(deck) <= limit, "invalid_loadout", "Deck exceeds the available slots")
    for card in deck:
        require(isinstance(card, str) and card in allowed, "invalid_loadout", "Card is not in the shared host library")
    require(len(set(deck)) == len(deck), "invalid_loadout", "A deck cannot contain duplicate cards")
    require(not ready or len(deck) > 0, "invalid_loadout", "Choose at least one card before confirming")
    return list(deck)


def screen_dimensions(data, encoding):
    """Bound image dimensions without decoding image pixels in the server loop."""
    def valid(condition):
        require(condition, "invalid_screen", "Invalid screen image header")
    if encoding == "png":
        valid(data.startswith(b"\x89PNG\r\n\x1a\n"))
        offset, dimensions, image_data = 8, None, False
        while offset + 12 <= len(data):
            size = int.from_bytes(data[offset:offset+4], "big")
            kind = data[offset+4:offset+8]
            end = offset + size + 12
            valid(end <= len(data))
            body = data[offset+8:offset+8+size]
            valid(zlib.crc32(kind + body) & 0xffffffff == int.from_bytes(data[end-4:end], "big"))
            if dimensions is None:
                valid(kind == b"IHDR" and size == 13)
                width, height, depth, colour, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
                valid(depth in (1, 2, 4, 8, 16) and colour in (0, 2, 3, 4, 6)
                      and compression == filtering == 0 and interlace in (0, 1))
                dimensions = width, height
            elif kind == b"IHDR":
                valid(False)
            if kind == b"IDAT":
                image_data = True
            if kind == b"IEND":
                valid(size == 0 and image_data and end == len(data))
                return dimensions
            offset = end
        valid(False)
    # JPEG SOF segment fields follow ITU T.81, as parsed by libjpeg-turbo's
    # jdmarker.c. Accept the 8-bit baseline/extended/progressive encoders used by
    # ImageIO; no pixel decode or optional Python imaging dependency is needed.
    valid(encoding == "jpeg" and data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"))
    offset, dimensions = 2, None
    while offset < len(data) - 2:
        valid(data[offset] == 0xff)
        while offset < len(data) and data[offset] == 0xff:
            offset += 1
        valid(offset < len(data))
        marker = data[offset]
        offset += 1
        valid(marker not in (0, 0xd8, 0xd9))
        if marker == 0x01 or 0xd0 <= marker <= 0xd7:
            continue
        valid(offset + 2 <= len(data))
        size = int.from_bytes(data[offset:offset+2], "big")
        valid(size >= 2 and offset + size <= len(data) - 2)
        body = data[offset+2:offset+size]
        if marker in (0xc0, 0xc1, 0xc2):
            valid(dimensions is None and len(body) >= 6 and body[0] == 8)
            height, width, components = struct.unpack(">HHB", body[1:6])
            valid(components in (1, 3, 4) and len(body) == 6 + components * 3)
            dimensions = width, height
        elif marker == 0xda:
            valid(dimensions is not None and len(body) >= 4 and len(body) == 4 + body[0] * 2)
            return dimensions
        offset += size
    valid(False)


def screen_frame(request):
    seq = integer(request.get("seq"), "seq", 1)
    room = identifier(request.get("room"), "room")
    require(room in SCREEN_ROOMS, "screen_unavailable", "This game screen cannot be shared")
    width = integer(request.get("width"), "width", 1, 960)
    height = integer(request.get("height"), "height", 1, 540)
    encoding = request.get("encoding")
    require(encoding in ("jpeg", "png"), "invalid_screen", "Use JPEG or PNG screen encoding")
    image = request.get("image")
    require(isinstance(image, str) and 1 <= len(image) <= MAX_SCREEN_BASE64,
            "invalid_screen", "Screen image exceeds its encoded size limit")
    try:
        raw = base64.b64decode(image, validate=True)
    except (ValueError, binascii.Error):
        raise ProtocolError("invalid_screen", "Screen image is not valid base64") from None
    require(screen_dimensions(raw, encoding) == (width, height), "invalid_screen", "Screen dimensions do not match its header")
    title = string(request.get("title", room), "title", 160)
    result = {"seq": seq, "room": room, "width": width, "height": height,
              "encoding": encoding, "image": image, "title": title}
    json_object(result, "screen frame", MAX_MESSAGE)
    return result


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
