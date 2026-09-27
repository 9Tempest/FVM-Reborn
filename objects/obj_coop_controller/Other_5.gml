if (room==room_battle && global.coop.active && global.coop.role=="host") {
    if (global.coop.room_status=="running" && !global.coop.result_saved) global.coop.submit_result("defeat");
    global.coop.battle_started=false;
}
