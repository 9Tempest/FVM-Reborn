/// Shares only the game's render target. No window/desktop capture, image files,
/// input injection, or save data are involved. Battle and loadout UI stay local.
function coop_screen_state() {
    if (!variable_global_exists("coop_screen")) {
        global.coop_screen={sequence:0,pending:0,pending_at:0,next_at:0,
            surface:-1,scaled:-1,pixels:-1,sprite:-1,capturing:false,due:false,sharing:false,clear_at:0,
            hash:"",last_sent:0,received_at:0,received_seq:0,stream_id:"",room:"",title:"",
            encode_ms:0,frame_bytes:0};
    }
    return global.coop_screen;
}
function coop_screen_room_allowed(_name) {
    return _name=="room_menu" || _name=="room_map" || _name=="room_tower_cake" || _name=="room_laboratory";
}
function coop_screen_host_allowed() {
    var _c=global.coop;
    return os_type==os_macosx && _c.active && _c.role=="host" && _c.all_connected()
        && coop_get(_c,"shared_screen_supported",false) && !_c.battle_started
        && coop_get(_c,"room_status","")!="running" && !is_struct(coop_get(_c,"preparation"))
        && coop_screen_room_allowed(room_get_name(room));
}
function coop_screen_reset() {
    var _s=coop_screen_state();
    // Session may reset several times on the same socket. Sequence numbers must
    // remain monotonic for that socket's server-side duplicate filter.
    if (_s.capturing) { surface_reset_target(); _s.capturing=false; }
    if (surface_exists(_s.surface)) surface_free(_s.surface);
    if (surface_exists(_s.scaled)) surface_free(_s.scaled);
    if (buffer_exists(_s.pixels)) buffer_delete(_s.pixels);
    if (sprite_exists(_s.sprite)) sprite_delete(_s.sprite);
    _s.surface=-1; _s.scaled=-1; _s.pixels=-1; _s.sprite=-1;
    _s.pending=0; _s.due=false; _s.sharing=false; _s.hash=""; _s.received_seq=0;
    _s.received_at=0; _s.stream_id=""; _s.room=""; _s.title=""; _s.next_at=0;
}
function coop_screen_tick() {
    var _s=coop_screen_state(),_c=global.coop;
    if (_s.sharing && _c.active && _c.role=="host" && _c.connected
        && !coop_screen_room_allowed(room_get_name(room)) && current_time>=_s.clear_at) {
        _s.clear_at=current_time+500;
        if (_c.send("screen_clear")) coop_screen_reset();
    }
    if (!_c.active || _c.battle_started || is_struct(coop_get(_c,"preparation"))) {
        if (_s.sprite!=-1 || _s.surface!=-1 || _s.pending!=0) coop_screen_reset();
        return;
    }
    if (!coop_screen_host_allowed()) { _s.due=false; return; }
    // A slow connection can have only one frame in flight. A lost ACK permits
    // a fresh current frame after two seconds, never a queued sequence of JPEGs.
    if (_s.pending!=0 && current_time-_s.pending_at<2000) return;
    if (current_time<_s.next_at) return;
    _s.pending=0; _s.due=true;
}
function coop_screen_ack(_packet) {
    var _s=coop_screen_state();
    if (coop_get(_packet,"seq",-1)!=_s.pending) return;
    _s.pending=0;
    if (!coop_get(_packet,"accepted",false)) _s.hash="";
}
function coop_screen_title(_room) {
    switch (_room) {
        case "room_map": return "房主正在选择关卡";
        case "room_tower_cake": return "房主正在选择挑战";
        case "room_laboratory": return "房主正在操作实验室";
        default: return "房主正在操作共同进度";
    }
}
function coop_screen_copy_begin() {
    var _saved={alpha:draw_get_alpha(),colour:draw_get_colour()};
    gpu_push_state(); gpu_set_blendenable(true); gpu_set_blendmode(bm_normal);
    gpu_set_colourwriteenable(true,true,true,true);
    draw_set_alpha(1); draw_set_colour(c_white);
    return _saved;
}
function coop_screen_copy_end(_saved) {
    gpu_pop_state(); draw_set_alpha(_saved.alpha); draw_set_colour(_saved.colour);
}
function coop_screen_gui_begin() {
    var _s=coop_screen_state();
    if (!_s.due || !coop_screen_host_allowed() || !surface_exists(application_surface)) return;
    _s.due=false; _s.next_at=current_time+250;
    var _w=display_get_gui_width(),_h=display_get_gui_height();
    if (!surface_exists(_s.surface) || surface_get_width(_s.surface)!=_w || surface_get_height(_s.surface)!=_h) {
        if (surface_exists(_s.surface)) surface_free(_s.surface);
        _s.surface=surface_create(_w,_h);
    }
    if (!surface_exists(_s.surface)) return;
    // This event runs before every Draw GUI. The regular Draw/Draw End result
    // is copied first, then the actual GUI renders into the same game surface.
    var _saved=coop_screen_copy_begin();
    surface_set_target(_s.surface);
    draw_clear_alpha(c_black,1);
    draw_surface_stretched(application_surface,0,0,_w,_h);
    coop_screen_copy_end(_saved);
    _s.capturing=true;
}
function coop_screen_gui_end() {
    var _s=coop_screen_state();
    if (!_s.capturing) return;
    surface_reset_target(); _s.capturing=false;
    var _w=display_get_gui_width(),_h=display_get_gui_height();
    var _saved=coop_screen_copy_begin();
    // Show the same composed game+GUI to the host. This changes no game logic.
    draw_surface_stretched(_s.surface,0,0,_w,_h);
    if (!coop_screen_host_allowed()) { coop_screen_copy_end(_saved); return; }
    if (!surface_exists(_s.scaled)) _s.scaled=surface_create(960,540);
    if (!surface_exists(_s.scaled)) { coop_screen_copy_end(_saved); return; }
    surface_set_target(_s.scaled);
    draw_clear_alpha(c_black,1);
    draw_surface_stretched(_s.surface,0,0,960,540);
    // The host's OS cursor is deliberately not captured. A small in-game marker
    // lets the guest follow what the host is pointing at without sharing input.
    if (mouse_x>=0 && mouse_x<_w && mouse_y>=0 && mouse_y<_h) {
        draw_set_alpha(0.85); draw_set_colour(c_white);
        draw_circle(mouse_x*960/_w,mouse_y*540/_h,5,true);
    }
    surface_reset_target(); coop_screen_copy_end(_saved);
    if (!buffer_exists(_s.pixels)) _s.pixels=buffer_create(960*540*4,buffer_fixed,1);
    buffer_get_surface(_s.pixels,_s.scaled,0);
    var _hash=buffer_md5(_s.pixels,0,960*540*4),_room=room_get_name(room);
    if (_hash==_s.hash && _room==_s.room && current_time-_s.last_sent<2000) return;
    var _started=get_timer();
    var _image=native_encode_game_frame(buffer_base64_encode(_s.pixels,0,960*540*4),960,540);
    _s.encode_ms=(get_timer()-_started)/1000;
    if (!is_string(_image) || string_length(_image)==0 || string_length(_image)>700*1024) return;
    _s.sequence++;
    var _frame={seq:_s.sequence,room:_room,width:960,height:540,encoding:"jpeg",image:_image,title:coop_screen_title(_room)};
    if (global.coop.send("screen_frame",_frame)) {
        _s.sharing=true;
        _s.pending=_s.sequence; _s.pending_at=current_time; _s.last_sent=current_time;
        _s.hash=_hash; _s.room=_room; _s.frame_bytes=string_length(_image);
    }
}
function coop_screen_receive(_frame) {
    var _c=global.coop,_s=coop_screen_state();
    if (!_c.active || _c.role!="guest" || _c.battle_started || is_struct(coop_get(_c,"preparation")) || !is_struct(_frame)) return false;
    var _stream=coop_get(_frame,"stream_id",""),_seq=coop_get(_frame,"seq",0),_room=coop_get(_frame,"room","");
    var _encoding=coop_get(_frame,"encoding",""),_image=coop_get(_frame,"image","");
    var _w=coop_get(_frame,"width",0),_h=coop_get(_frame,"height",0);
    if ((_stream==_s.stream_id && _seq<=_s.received_seq) || !coop_screen_room_allowed(_room) || (_encoding!="jpeg" && _encoding!="png")
        || !is_string(_image) || string_length(_image)>700*1024 || _w<1 || _w>960 || _h<1 || _h>540) return false;
    var _sprite=sprite_add("data:image/"+_encoding+";base64,"+_image,1,false,false,0,0);
    if (!sprite_exists(_sprite)) return false;
    if (sprite_get_width(_sprite)!=_w || sprite_get_height(_sprite)!=_h) { sprite_delete(_sprite); return false; }
    if (sprite_exists(_s.sprite)) sprite_delete(_s.sprite);
    _s.sprite=_sprite; _s.stream_id=_stream; _s.received_seq=_seq; _s.received_at=current_time;
    _s.room=_room; _s.title=coop_screen_title(_room);
    return true;
}
function coop_screen_visible() {
    var _c=global.coop,_s=coop_screen_state();
    return _c.active && _c.role=="guest" && !_c.battle_started && !is_struct(coop_get(_c,"preparation")) && sprite_exists(_s.sprite);
}
function coop_screen_step() {
    if (coop_ui_hit(1630,15,250,55)) global.coop.leave();
}
function coop_screen_draw() {
    var _s=coop_screen_state(),_c=global.coop;
    draw_clear(make_colour_rgb(8,20,28));
    draw_set_alpha(1); draw_set_colour(c_white);
    draw_sprite_stretched(_s.sprite,0,80,80,1760,990);
    coop_ui_text(42,41,_s.title,0.92,c_white,fa_left,790);
    var _status=!_c.all_connected() ? "连接中断 / 等待房主" : (current_time-_s.received_at>5000 ? "画面同步中…" : "实时观看 / 选关后分别选卡");
    coop_ui_text(1575,41,_status,0.68,make_colour_rgb(155,219,204),fa_right,700);
    coop_ui_button(1630,15,250,55,"退出合作模式");
    draw_set_alpha(1); draw_set_halign(fa_left); draw_set_valign(fa_top); draw_set_colour(c_white);
}
