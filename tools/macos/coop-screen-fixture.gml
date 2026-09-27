function coop_get(_v,_k,_d=undefined) { return is_struct(_v) && variable_struct_exists(_v,_k) ? variable_struct_get(_v,_k) : _d; }
function coop_ui_hit(_x,_y,_w,_h) { return false; }
function coop_ui_text(_x,_y,_text,_size=1,_colour=c_white,_align=fa_left,_width=1600) {
    draw_set_colour(_colour); draw_set_halign(_align); draw_text(_x,_y,_text);
}
function coop_ui_button(_x,_y,_w,_h,_text,_enabled=true) { draw_set_colour(c_white);draw_text(_x,_y,_text); }
function fixture_expect(_name,_ok) { array_push(global.checks,{name:_name,passed:_ok});show_debug_message("FVM_SCREEN_ASSERT="+string(_ok)+" "+_name); }
function fixture_create() {
    display_set_gui_size(1920,1080);
    window_set_size(960,540);
    global.checks=[]; global.images=[]; global.frame=0; global.sent=[]; global.clears=0; global.phase=0;
    global.coop={active:true,role:"host",connected:true,shared_screen_supported:true,battle_started:false,room_status:"lobby",preparation:undefined,
        all_connected:function() { return connected; },send:function(_type,_frame=undefined) {
            if (_type=="screen_clear") global.clears++; else array_push(global.sent,_frame); return true;
        }};
    fixture_expect("Native GUI event constants match hooks",ev_gui_begin==74 && ev_gui_end==75);
    fixture_expect("Codec rejects invalid dimensions",native_encode_game_frame("",961,540)=="");
    fixture_expect("Codec rejects wrong buffer byte count",native_encode_game_frame("AA==",960,540)=="");
}
function fixture_step() {
    global.frame++;
    coop_screen_tick();
    if (global.frame==35) {
        fixture_expect("Backpressure allows only one unacknowledged frame",array_length(global.sent)==1);
        if (array_length(global.sent)>0) {
            var _packet=global.sent[0],_s=coop_screen_state();
            global.encode_ms=_s.encode_ms; surface_save(_s.surface,"host-composite.png"); surface_save(application_surface,"host-application.png");
            var _raw=buffer_base64_decode(_packet.image); buffer_save(_raw,"sample-game-frame.jpg"); buffer_delete(_raw);
            global.coop.role="guest";
            fixture_expect("Native sprite_add decodes JPEG data URL",coop_screen_receive(_packet));
            fixture_expect("Decoded frame visible only to guest",coop_screen_visible());
            fixture_expect("Duplicate frame ignored",!coop_screen_receive(_packet));
            var _previous=_s.sprite,_next=json_parse(json_stringify(_packet));
            _next.stream_id="reconnected-host";_next.seq=1;
            fixture_expect("Host reconnect starts a new frame sequence",coop_screen_receive(_next));
            fixture_expect("Replaced JPEG releases prior GPU sprite",!sprite_exists(_previous));
            _next.seq=2;_next.room="room_coop";
            fixture_expect("Invitation and lobby canvas never accepted",!coop_screen_receive(_next));
            coop_screen_ack({seq:9999,accepted:true});
            fixture_expect("Unrelated ACK cannot release current frame",_s.pending==_packet.seq);
            coop_screen_ack({seq:_packet.seq,accepted:true});
            fixture_expect("Matching ACK releases capture backpressure",_s.pending==0);
            var _surface=surface_create(960,540);surface_set_target(_surface);
            draw_clear(c_black);draw_sprite(_s.sprite,0,0,0);surface_reset_target();
            var _tl=surface_getpixel(_surface,100,80),_tr=surface_getpixel(_surface,860,80);
            var _bl=surface_getpixel(_surface,100,460),_br=surface_getpixel(_surface,860,460),_gui=surface_getpixel(_surface,480,270);
            fixture_expect("Upper-left red retains RGB ordering",colour_get_red(_tl)>220 && colour_get_green(_tl)<30 && colour_get_blue(_tl)<30);
            fixture_expect("Upper-right blue retains RGB ordering",colour_get_blue(_tr)>220 && colour_get_red(_tr)<30);
            fixture_expect("Bottom-left yellow proves vertical orientation",colour_get_red(_bl)>220 && colour_get_green(_bl)>220 && colour_get_blue(_bl)<30);
            fixture_expect("Bottom-right magenta proves full frame",colour_get_red(_br)>220 && colour_get_blue(_br)>220 && colour_get_green(_br)<30);
            fixture_expect("Draw GUI overlay included in transmitted pixels",colour_get_green(_gui)>220 && colour_get_red(_gui)<30 && colour_get_blue(_gui)<30);
            surface_save(_surface,"received-colour-gui.png");array_push(global.images,game_save_id+"received-colour-gui.png");surface_free(_surface);
            fixture_expect("Frame encoding below transport cap",string_length(_packet.image)<=700*1024);
            global.phase=1;
        }
    }
    if (global.frame==45) {
        surface_save(application_surface,"guest-shared-canvas.png");array_push(global.images,game_save_id+"guest-shared-canvas.png");
        global.coop.preparation={id:"pick"};
        fixture_expect("Independent loadout UI takes priority",!coop_screen_visible());
        coop_screen_tick();fixture_expect("Entering loadout frees shared image",!sprite_exists(coop_screen_state().sprite));
        global.coop.preparation=undefined; global.coop.role="host";global.phase=2;
        coop_screen_reset();global.coop.battle_started=true;coop_screen_tick();
        fixture_expect("Battle disables capture",!coop_screen_state().due);
        global.coop.battle_started=false;global.coop.connected=false;coop_screen_tick();
        fixture_expect("Offline guest disables capture",!coop_screen_state().due);
        global.coop.connected=true;
    }
    if (global.frame==90) {
        if (array_length(global.sent)>1) {
            var _last=global.sent[array_length(global.sent)-1];
            fixture_expect("Sequence survives reset and new menus",_last.seq>global.sent[0].seq);
            coop_screen_ack({seq:_last.seq,accepted:true});
        }
        fixture_expect("A later real scene is encoded",array_length(global.sent)>1);
        global.phase=3;room_goto(room_coop);
    }
    if (global.frame==100) {
        fixture_expect("Host returning to private lobby clears stream once",global.clears==1 && !coop_screen_state().sharing);
        fixture_expect("Private lobby releases capture surfaces",!surface_exists(coop_screen_state().surface));
        var _passed=0;for(var _i=0;_i<array_length(global.checks);_i++)if(global.checks[_i].passed)_passed++;
        var _report={passed:_passed,total:array_length(global.checks),tests:global.checks,images:global.images,
            game_save_id:game_save_id,encode_ms:global.encode_ms,frame_bytes:string_length(global.sent[0].image),later_frame_bytes:coop_screen_state().frame_bytes,later_encode_ms:coop_screen_state().encode_ms};
        show_debug_message("FVM_SCREEN_RESULT="+json_stringify(_report));coop_screen_reset();game_end();
    }
}
function fixture_draw() {
    if (global.phase==1) { coop_screen_draw(); return; }
    draw_clear(c_black);draw_set_alpha(1);
    draw_set_colour(c_red);draw_rectangle(0,0,960,540,false);
    draw_set_colour(c_blue);draw_rectangle(960,0,1920,540,false);
    draw_set_colour(c_yellow);draw_rectangle(0,540,960,1080,false);
    draw_set_colour(c_fuchsia);draw_rectangle(960,540,1920,1080,false);
    if (global.phase==2) draw_sprite_stretched(spr_craft_bg,0,0,0,1920,1080);
    draw_set_alpha(0.25);draw_set_colour(c_yellow);
}
function fixture_gui() {
    if (global.phase==1) return;
    gpu_set_blendmode(bm_normal);draw_set_alpha(1);draw_set_colour(c_lime);draw_rectangle(850,430,1070,650,false);
    draw_set_alpha(0.35);draw_set_colour(c_aqua);gpu_set_blendmode(bm_add);
}
function fixture_after_gui() {
    if (global.frame==1) { fixture_expect("Capture restores GUI colour and alpha",draw_get_colour()==c_aqua && abs(draw_get_alpha()-0.35)<0.001); }
    gpu_set_blendmode(bm_normal);draw_set_alpha(1);draw_set_colour(c_white);
}
