/// Shared geometry; each co-op player has a separate row of owned instances.
function create_battle_card_slot(_card_id, _shape, _data, _index, _owner = "") {
    var _inst = instance_create_depth(535 + min(_index,14) * 90,
        90 + max(0,_index - 14) * 118, -2000, obj_card_slot, {coop_owner:_owner});
    _inst.cost = _data[? "cost"];
    _inst.cooldown = _data[? "cooldown"];
    _inst.card_obj = _data[? "obj"];
    _inst.card_spr = _data[? "sprite"];
    _inst.place_preview = _data[? "place_preview"];
    _inst.description = _data[? "description"];
    _inst.slot_index = _index + 1;
    _inst.card_id = _card_id;
    _inst.shape = _shape;
    // The room starts paused, so populate card cost/art before its first Step.
    if (!_inst.info_got) with (_inst) event_user(0);
    _inst.current_cost = _inst.cost;
    _inst.visible = coop_slot_local(_inst);
    return _inst;
}

/// Room Start can run before the match ACK; ready() will complete deferred work.
function create_battle_slots() {
    if (coop_personal_loadouts()) return coop_battle_prepare_loadouts();
    var _count = 0;
    for (var _i = 0; _i < deck_slot_max(); _i++) {
        if (deck_slot_is_empty(_i)) continue;
        var _entry = global.selected_deck[| _i];
        create_battle_card_slot(_entry[? "card_id"],_entry[? "shape"],_entry[? "data"],_count);
        _count++;
    }
    return true;
}
