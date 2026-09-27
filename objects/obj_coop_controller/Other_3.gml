if (global.coop.active) {
    if (global.coop.role=="host") {
        if (global.coop.room_status=="running") global.coop.submit_result("defeat");
        else global.coop.save_campaign();
    }
    global.coop.remember();
}
global.coop.leaving=true;
global.coop.transport.close();
coop_audio_stop();
