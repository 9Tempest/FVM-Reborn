if (coop_personal_loadouts()) {
    // Authoritative balances are clamped on credit; never grant debug resources.
    global.flame = coop_flame_get();
    exit;
}
if global.flame > 15000 { global.flame = 15000; }
if global.debug && !coop_battle_active() { global.flame = 15000; }
