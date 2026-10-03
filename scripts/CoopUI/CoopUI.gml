function coop_ui_text(_x,_y,_text,_size=1,_colour=c_white,_align=fa_left,_width=1600) {
    draw_set_font(font_yuan); draw_set_halign(_align); draw_set_valign(fa_middle);
    draw_set_colour(_colour); draw_set_alpha(1);
    var _scale=min(_size,_width/max(1,string_width(string(_text))));
    draw_text_transformed(_x,_y,string(_text),_scale,_scale,0);
}
function coop_ui_button(_x,_y,_w,_h,_label,_enabled=true) {
    var _hover=point_in_rectangle(mouse_x,mouse_y,_x,_y,_x+_w,_y+_h);
    draw_set_alpha(1);
    draw_set_colour(!_enabled ? make_colour_rgb(42,52,61) : (_hover ? make_colour_rgb(43,116,112) : make_colour_rgb(30,80,82)));
    draw_roundrect_ext(_x,_y,_x+_w,_y+_h,14,14,false);
    coop_ui_text(_x+_w/2,_y+_h/2,_label,1,_enabled ? c_white : c_gray,fa_center,_w-24);
}
function coop_ui_hit(_x,_y,_w,_h) {
    return mouse_check_button_pressed(mb_left) && point_in_rectangle(mouse_x,mouse_y,_x,_y,_x+_w,_y+_h);
}
function coop_ui_sprite(_name,_frame,_x,_y,_w,_h,_alpha=1) {
    var _s=is_string(_name) ? asset_get_index(_name) : _name;
    if (!sprite_exists(_s)) return;
    var _l=sprite_get_bbox_left(_s),_t=sprite_get_bbox_top(_s);
    var _sw=sprite_get_bbox_right(_s)-_l+1,_sh=sprite_get_bbox_bottom(_s)-_t+1;
    var _scale=min(_w/max(1,_sw),_h/max(1,_sh));
    // Let GameMaker account for texture-page trimming. Cropping the source by
    // its mask rectangle can sample neighboring frames on trimmed card sprites.
    var _dx=_x-(_l+_sw/2-sprite_get_xoffset(_s))*_scale;
    var _dy=_y-(_t+_sh/2-sprite_get_yoffset(_s))*_scale;
    draw_sprite_ext(_s,_frame,_dx,_dy,_scale,_scale,0,c_white,_alpha);
}
/// Both rendering and input use this same local-owner list. Snapshot array order
/// must never make the guest select or spend from the host's slots.
function coop_guest_slots(_snapshot,_player_id) {
    var _all=coop_get(_snapshot,"slots",[]),_result=[];
    var _personal=coop_get(_snapshot,"per_player_loadouts",false);
    for (var _i=0;_i<array_length(_all);_i++) {
        if (!_personal || coop_get(_all[_i],"owner","")==_player_id) array_push(_result,_all[_i]);
    }
    array_sort(_result,function(_a,_b) { return coop_get(_a,"slot_index",0)-coop_get(_b,"slot_index",0); });
    return _result;
}
function coop_guest_flame(_snapshot,_player_id) {
    var _fallback=coop_get(_snapshot,"per_player_loadouts",false) ? 0 : coop_get(_snapshot,"flame",0);
    return coop_get(coop_get(_snapshot,"balances",{}),_player_id,_fallback);
}
function coop_loadout_state() {
    var _prep=coop_get(global.coop,"preparation",{}),_id=coop_get(_prep,"id","");
    if (!variable_global_exists("coop_loadout_ui") || global.coop_loadout_ui.preparation_id!=_id) {
        global.coop_loadout_ui={preparation_id:_id,page:0,notice:"",notice_until:0};
        texture_prefetch("cards");
    }
    return global.coop_loadout_ui;
}
function coop_loadout_cards() {
    var _cards=[],_unlocked=global.save_data.unlocked_cards;
    for (var _i=0;_i<array_length(_unlocked);_i++) {
        var _entry=_unlocked[_i],_data=deck_get_card_data(_entry.id,_entry.shape);
        if (_data==noone) continue;
        var _shape=get_plant_shape_data(_entry.id,_entry.shape);
        array_push(_cards,{id:_entry.id,shape:_entry.shape,level:_entry.level,
            name:_shape[? "name"],sprite:_data[? "sprite"],cost:_data[? "cost"]});
    }
    return _cards;
}
function coop_loadout_card(_cards,_id) {
    for (var _i=0;_i<array_length(_cards);_i++) if (_cards[_i].id==_id) return _cards[_i];
    return undefined;
}
function coop_loadout_toggle(_card_id) {
    var _c=global.coop,_prep=coop_get(_c,"preparation",{}),_ui=coop_loadout_state();
    var _own=coop_get(coop_get(_prep,"selections",{}),_c.player_id,{});
    if (!_c.connected || coop_get(_c,"loadout_pending",false) || coop_get(_own,"ready",false)) return false;
    var _draft=coop_get(_c,"loadout_draft",[]),_next=[],_found=false;
    for (var _i=0;_i<array_length(_draft);_i++) {
        if (_draft[_i]==_card_id) _found=true; else array_push(_next,_draft[_i]);
    }
    if (!_found) {
        if (array_length(_next)>=coop_get(_prep,"slot_limit",deck_slot_max())) {
            _ui.notice="卡槽已满，点击已选卡牌可以移除"; _ui.notice_until=current_time+2500;
            return false;
        }
        array_push(_next,_card_id);
    }
    return _c.set_loadout(_next,false);
}
function coop_loadout_step() {
    var _c=global.coop,_prep=_c.preparation,_ui=coop_loadout_state();
    var _cards=coop_loadout_cards(),_pages=max(1,ceil(array_length(_cards)/21));
    _ui.page=clamp(_ui.page,0,_pages-1);
    if ((keyboard_check_pressed(vk_left) || coop_ui_hit(78,879,175,54)) && _ui.page>0) _ui.page--;
    if ((keyboard_check_pressed(vk_right) || coop_ui_hit(993,879,175,54)) && _ui.page<_pages-1) _ui.page++;
    if (coop_ui_hit(48,978,220,65)) { _c.leave(); return; }
    var _pending=coop_get(_c,"loadout_pending",false);
    if (_c.role=="host" && !_pending && coop_ui_hit(290,978,230,65)) { _c.cancel_preparation(); return; }
    var _own=coop_get(coop_get(_prep,"selections",{}),_c.player_id,{});
    var _ready=coop_get(_own,"ready",false),_draft=coop_get(_c,"loadout_draft",[]);
    if (!_pending && _c.connected && (_ready || _c.all_connected()) && array_length(_draft)>0 && coop_ui_hit(1340,978,530,65)) {
        _c.set_loadout(_draft,!_ready); return;
    }
    if (_pending || _ready || !_c.connected) return;
    if (array_length(_draft)>0 && coop_ui_hit(1740,207,105,44)) { _c.set_loadout([],false); return; }
    for (var _i=_ui.page*21;_i<min(array_length(_cards),(_ui.page+1)*21);_i++) {
        var _cell=_i mod 21,_x=78+(_cell mod 7)*158,_y=264+(_cell div 7)*201;
        if (coop_ui_hit(_x,_y,144,183)) { coop_loadout_toggle(_cards[_i].id); return; }
    }
    var _limit=max(1,coop_get(_prep,"slot_limit",deck_slot_max())),_cols=max(7,ceil(_limit/3)),_cw=560/_cols;
    for (var _i=0;_i<array_length(_draft);_i++) {
        if (coop_ui_hit(1266+(_i mod _cols)*_cw,273+(_i div _cols)*101,_cw-6,91)) {
            coop_loadout_toggle(_draft[_i]); return;
        }
    }
}
function coop_loadout_draw() {
    var _c=global.coop,_prep=_c.preparation,_ui=coop_loadout_state(),_cards=coop_loadout_cards();
    var _draft=coop_get(_c,"loadout_draft",[]),_selections=coop_get(_prep,"selections",{});
    var _own=coop_get(_selections,_c.player_id,{}),_ready=coop_get(_own,"ready",false);
    var _pending=coop_get(_c,"loadout_pending",false),_limit=max(1,coop_get(_prep,"slot_limit",deck_slot_max()));
    var _mate=undefined;
    for (var _i=0;_i<array_length(_c.players);_i++) if (_c.players[_i].player_id!=_c.player_id) _mate=_c.players[_i];
    var _other=coop_get(_selections,coop_get(_mate,"player_id",""),{}),_other_deck=coop_get(_other,"deck",[]);
    var _other_ready=coop_get(_other,"ready",false),_pages=max(1,ceil(array_length(_cards)/21));
    _ui.page=clamp(_ui.page,0,_pages-1);
    draw_clear(make_colour_rgb(9,22,32));
    draw_set_alpha(1); draw_set_colour(make_colour_rgb(19,45,56));
    draw_roundrect_ext(48,176,1202,948,22,22,false);
    draw_roundrect_ext(1234,176,1872,948,22,22,false);
    coop_ui_text(60,70,"各自选卡，一起出发",2.1,make_colour_rgb(250,206,111),fa_left,1200);
    coop_ui_text(62,133,coop_get(_prep,"level_name","合作关卡"),1.05,c_white,fa_left,1140);
    coop_ui_text(1855,70,"两人独立卡组 / 各获 60% 火苗",0.85,make_colour_rgb(152,219,202),fa_right,660);
    coop_ui_text(1855,123,_c.all_connected() ? "队友在线" : "等待队友重新连接",0.8,_c.all_connected() ? c_aqua : c_yellow,fa_right,580);
    coop_ui_text(78,217,"共享卡库",1.15,c_white,fa_left,300);
    coop_ui_text(1170,217,"卡牌等级与形态使用共同进度",0.72,make_colour_rgb(159,190,199),fa_right,650);
    for (var _i=_ui.page*21;_i<min(array_length(_cards),(_ui.page+1)*21);_i++) {
        var _card=_cards[_i],_cell=_i mod 21,_x=78+(_cell mod 7)*158,_y=264+(_cell div 7)*201;
        var _selected=array_get_index(_draft,_card.id),_hover=point_in_rectangle(mouse_x,mouse_y,_x,_y,_x+144,_y+183);
        draw_set_alpha(1); draw_set_colour(_selected>=0 ? make_colour_rgb(54,103,104) : (_hover ? make_colour_rgb(37,75,85) : make_colour_rgb(26,59,71)));
        draw_roundrect_ext(_x,_y,_x+144,_y+183,12,12,false);
        if (_selected>=0) {
            draw_set_colour(make_colour_rgb(245,203,110)); draw_roundrect_ext(_x+1,_y+1,_x+143,_y+182,12,12,true);
        }
        coop_ui_sprite(spr_slot,0,_x+72,_y+69,98,112);
        coop_ui_sprite(_card.sprite,0,_x+72,_y+68,86,89);
        if (_selected>=0) {
            draw_set_colour(make_colour_rgb(20,48,60)); draw_roundrect_ext(_x+6,_y+6,_x+38,_y+30,7,7,false);
            coop_ui_text(_x+22,_y+18,string(_selected+1),0.65,make_colour_rgb(250,206,111),fa_center,28);
        }
        coop_ui_text(_x+72,_y+140,_card.name,0.73,c_white,fa_center,134);
        coop_ui_text(_x+12,_y+166,"Lv."+string(_card.level),0.62,make_colour_rgb(177,216,216),fa_left,63);
        coop_ui_sprite(spr_flame,0,_x+91,_y+166,17,22);
        coop_ui_text(_x+133,_y+166,string(_card.cost),0.65,make_colour_rgb(250,206,111),fa_right,42);
    }
    if (array_length(_cards)==0) coop_ui_text(625,535,"正在同步共同卡库…",1.2,c_white,fa_center,950);
    coop_ui_button(78,879,175,54,"上一页",_ui.page>0);
    coop_ui_text(625,906,string(_ui.page+1)+" / "+string(_pages)+"  共 "+string(array_length(_cards))+" 张",0.78,c_white,fa_center,620);
    coop_ui_button(993,879,175,54,"下一页",_ui.page<_pages-1);
    coop_ui_text(1266,221,"你的卡组  "+string(array_length(_draft))+" / "+string(_limit),1.03,c_white,fa_left,445);
    coop_ui_button(1740,207,105,44,"清空",!_pending && !_ready && _c.connected && array_length(_draft)>0);
    var _cols=max(7,ceil(_limit/3)),_cw=560/_cols;
    for (var _i=0;_i<_limit;_i++) {
        var _x=1266+(_i mod _cols)*_cw,_y=273+(_i div _cols)*101;
        draw_set_colour(make_colour_rgb(10,31,42)); draw_set_alpha(1); draw_roundrect_ext(_x,_y,_x+_cw-6,_y+91,8,8,false);
        coop_ui_text(_x+7,_y+12,string(_i+1),0.48,make_colour_rgb(104,151,160),fa_left,25);
        if (_i<array_length(_draft)) {
            var _card=coop_loadout_card(_cards,_draft[_i]);
            if (is_struct(_card)) {
                coop_ui_sprite(_card.sprite,0,_x+(_cw-6)/2,_y+41,_cw-20,55);
                coop_ui_text(_x+(_cw-6)/2,_y+78,_card.name,0.5,c_white,fa_center,_cw-12);
            }
        } else coop_ui_text(_x+(_cw-6)/2,_y+48,"+",1,make_colour_rgb(55,96,111),fa_center,45);
    }
    var _own_status=_pending ? "正在同步选卡…" : (_ready ? "已准备 / 取消准备后可调整卡组" : "点击卡牌加入，再点击即可移除");
    if (!_pending && !_ready && coop_get(_own,"cached",false)) _own_status="已带入上次卡组，请确认准备";
    coop_ui_text(1266,605,_own_status,0.74,_ready ? c_aqua : make_colour_rgb(168,204,209),fa_left,570);
    draw_set_colour(make_colour_rgb(45,75,84)); draw_line(1266,642,1840,642);
    coop_ui_text(1266,674,coop_get(_mate,"name","等待队友"),0.95,c_white,fa_left,370);
    coop_ui_text(1840,674,_other_ready ? "已准备" : "选卡中",0.8,_other_ready ? c_aqua : c_yellow,fa_right,180);
    for (var _i=0;_i<array_length(_other_deck);_i++) {
        var _card=coop_loadout_card(_cards,_other_deck[_i]),_x=1266+(_i mod _cols)*_cw,_y=710+(_i div _cols)*56;
        draw_set_colour(make_colour_rgb(12,34,44)); draw_set_alpha(1); draw_roundrect_ext(_x,_y,_x+_cw-6,_y+49,7,7,false);
        if (is_struct(_card)) coop_ui_sprite(_card.sprite,0,_x+(_cw-6)/2,_y+25,_cw-18,42);
    }
    if (array_length(_other_deck)==0) coop_ui_text(1550,790,"队友正在挑选自己的卡牌",0.85,make_colour_rgb(132,173,184),fa_center,550);
    coop_ui_text(1266,908,"队友已选 "+string(array_length(_other_deck))+" 张 / 两人可以选择相同卡牌",0.71,make_colour_rgb(159,190,199),fa_left,575);
    coop_ui_button(48,978,220,65,"退出合作");
    if (_c.role=="host") coop_ui_button(290,978,230,65,"更换关卡",!_pending);
    var _label=_pending ? "正在同步…" : (_ready ? "取消准备" : "准备完成");
    coop_ui_button(1340,978,530,65,_label,!_pending && _c.connected && (_ready || _c.all_connected()) && array_length(_draft)>0);
    var _status=(_ready && _other_ready) ? "两人已准备，正在进入战场…" : _c.status;
    if (_ui.notice_until>current_time) _status=_ui.notice;
    coop_ui_text(550,1010,_status,0.72,make_colour_rgb(169,211,210),fa_left,750);
    draw_set_alpha(1); draw_set_halign(fa_left); draw_set_valign(fa_top); draw_set_colour(c_white);
}
/// Session restores the persisted level context before calling this on a
/// confirmed match_started. UI drafts alone must never start or build a battle.
function coop_loadout_launch_host() {
    var _c=global.coop;
    if (!_c.active || _c.role!="host" || !coop_get(_c,"loadout_host_level_ready",false)) return false;
    var _deck=coop_get(coop_get(coop_get(_c,"match_config",{}),"loadouts",{}),_c.player_id,[]);
    if (!is_array(_deck) || array_length(_deck)<1 || array_length(_deck)>deck_slot_max()) return false;
    var _shapes=[];
    for (var _i=0;_i<array_length(_deck);_i++) {
        var _info=get_card_info_simple(_deck[_i]);
        if (!is_struct(_info) || deck_get_card_data(_deck[_i],_info.shape)==noone) return false;
        array_push(_shapes,_info.shape);
    }
    deck_empty_slot_ensure();
    for (var _i=0;_i<ds_list_size(global.selected_deck);_i++) {
        var _old=global.selected_deck[| _i];
        if (_old!=global.deck_empty_slot && ds_exists(_old,ds_type_map)) ds_map_destroy(_old);
    }
    clear_deck();
    for (var _i=0;_i<array_length(_deck);_i++) if (!add_to_deck(_deck[_i],_shapes[_i],_i)) return false;
    audio_stop_sound(mus_readyroom);
    texture_prefetch("bullet"); texture_prefetch("effects");
    global.gui_stack.to(room_battle);
    return true;
}
function coop_ui_step() {
    var _c=global.coop;
    if (room == room_menu) {
        if (coop_ui_hit(770,990,380,65)) global.gui_stack.to(room_coop);
        return;
    }
    if (room != room_coop) return;
    if (_c.active && _c.role == "guest" && is_struct(_c.latest) && _c.battle_started) {
        coop_guest_step();
        return;
    }
    if (_c.active && is_struct(coop_get(_c,"preparation"))) { coop_loadout_step(); return; }
    if (coop_screen_visible()) { coop_screen_step(); return; }
    if (!_c.active) {
        if (coop_ui_hit(320,400,560,84)) _c.create();
        if (coop_ui_hit(1040,400,560,84)) _c.resume();
        if (coop_ui_hit(1370,570,230,70)) {
            keyboard_string=clipboard_get_text();
            coop_invite_text=keyboard_string;
        }
        if (coop_ui_hit(320,570,1020,70)) coop_typing=true;
        if (coop_typing) coop_invite_text=string_copy(keyboard_string,1,4096);
        if (coop_ui_hit(710,685,500,80)) { _c.join(coop_invite_text); coop_typing=false; }
        if (coop_ui_hit(60,950,240,65)) { _c.leave(); coop_typing=false; }
    } else {
        if (coop_ui_hit(450,620,450,80) && _c.role == "host") {
            _c.copy_invite();
        }
        if (coop_ui_hit(1020,620,450,80) && _c.role == "host" && _c.all_connected()) {
            _c.battle_started=false; _c.latest=undefined;
            global.gui_stack.to(room_menu);
        }
        if (coop_ui_hit(60,950,260,65)) _c.leave();
    }
}
function coop_ui_draw() {
    var _c=global.coop;
    if (room == room_menu) {
        coop_ui_button(770,990,380,65,_c.active ? "合作房间 / 已连接" : "双人异地合作");
        if (_c.active) coop_ui_text(960,968,"共同进度 / 各自选卡 / 一起闯关",0.65,c_white,fa_center,800);
    }
    if (room == room_battle && _c.active) {
        if (global.game_over) {
            coop_ui_text(960,258,_c.result_saved ? "共同进度已保存到主机" : "正在等待主机确认存档…",0.65,_c.result_saved ? c_aqua : c_yellow,fa_center,1200);
            if (instance_exists(obj_game_over) && obj_game_over.sprite_index==spr_lose) coop_ui_button(1450,950,360,72,"回到合作房间",_c.result_saved);
        } else {
            draw_set_alpha(0.85); draw_set_colour(make_colour_rgb(10,27,37)); draw_roundrect(20,974,700,1055,false);
            coop_ui_text(40,997,_c.all_connected() ? "双人合作 / 主机同步中" : "连接中断 / 等待队友 / 战斗暂停",0.8,c_white);
            var _status=_c.status;
            if (_status=="先分别放置自己的角色，再共同布阵" && coop_battle_can_run()) _status="与队友共同布阵";
            coop_ui_text(40,1031,_status,0.65,make_colour_rgb(157,217,211),fa_left,635);
        }
    }
    if (room != room_coop) { draw_set_alpha(1); draw_set_halign(fa_left); draw_set_valign(fa_top); return; }
    if (_c.active && _c.role == "guest" && is_struct(_c.latest) && _c.battle_started) {
        coop_guest_draw(); return;
    }
    if (_c.active && is_struct(coop_get(_c,"preparation"))) { coop_loadout_draw(); return; }
    if (coop_screen_visible()) { coop_screen_draw(); return; }
    draw_clear(make_colour_rgb(10,24,35));
    draw_set_colour(make_colour_rgb(17,43,55)); draw_roundrect_ext(235,245,1685,890,30,30,false);
    coop_ui_text(960,130,"一起守住这桌美食",2.6,make_colour_rgb(250,206,111),fa_center,1600);
    coop_ui_text(960,210,"两台 Mac / 异地合作 / 进度保存在房主电脑",1,make_colour_rgb(160,191,198),fa_center,1500);
    if (!_c.active) {
        coop_ui_text(600,330,"我是房主",1.5,c_white,fa_center,600);
        coop_ui_text(1320,330,"继续共同冒险",1.5,c_white,fa_center,600);
        coop_ui_button(320,400,560,84,"创建合作房间");
        coop_ui_button(1040,400,560,84,"重连上次的房间",is_struct(_c.saved_session));
        coop_ui_text(320,535,"加入队友：粘贴完整邀请码",0.9,make_colour_rgb(160,191,198));
        draw_set_colour(make_colour_rgb(8,26,35)); draw_roundrect(320,570,1340,640,false);
        coop_ui_text(342,605,coop_invite_text == "" ? "FVM1:…" : string_copy(coop_invite_text,1,95),0.75,c_white,fa_left,975);
        coop_ui_button(1370,570,230,70,"粘贴");
        coop_ui_button(710,685,500,80,"加入合作房间",coop_invite_text != "");
        coop_ui_button(60,950,240,65,"返回游戏");
    } else {
        for (var _i=0;_i<2;_i++) {
            var _x=520+_i*880;
            var _p=_i<array_length(_c.players) ? _c.players[_i] : undefined;
            coop_ui_sprite(spr_player_character,0,_x,385,130,150);
            coop_ui_text(_x,480,is_struct(_p) ? _p.name : "等待队友",1.3,c_white,fa_center,650);
            coop_ui_text(_x,530,is_struct(_p) ? (_p.connected ? "已连接" : "等待重连") : "复制邀请码邀请另一位玩家",0.9,make_colour_rgb(139,210,189),fa_center,650);
        }
        if (_c.role == "host") {
            coop_ui_button(450,620,450,80,array_length(_c.players)<2 ? "复制邀请码" : "复制重连码");
            coop_ui_button(1020,620,450,80,"选择关卡",_c.all_connected());
            coop_ui_text(960,750,"房主选关，两人分别选卡并准备，再一起进入战场。",0.9,c_white,fa_center,1350);
        } else {
            coop_ui_text(960,680,"等待房主选择关卡…",1.3,c_white,fa_center,1400);
            coop_ui_text(960,750,"选关后，两人可分别选择自己的出战卡组。",0.9,c_white,fa_center,1350);
        }
        coop_ui_button(60,950,260,65,"退出合作模式");
    }
    coop_ui_text(960,840,_c.status,0.9,make_colour_rgb(160,217,209),fa_center,1320);
    draw_set_alpha(1); draw_set_halign(fa_left); draw_set_valign(fa_top); draw_set_colour(c_white);
}
function coop_guest_step() {
    var _c=global.coop,_s=_c.latest;
    if (coop_get(_s,"game_over",false)) {
        if (coop_ui_hit(1450,950,360,72) && _c.result_saved) { _c.battle_started=false; _c.latest=undefined; }
        if (keyboard_check_pressed(vk_right)) coop_reward_page++;
        if (keyboard_check_pressed(vk_left)) coop_reward_page=max(0,coop_reward_page-1);
        return;
    }
    if (keyboard_check_pressed(vk_space) || keyboard_check_pressed(vk_escape)) {
        coop_pause_vote=!coop_get(coop_get(_s,"pause_votes",{}),_c.player_id,coop_pause_vote);
        _c.send_input("pause_vote",{paused:coop_pause_vote});
    }
    if (mouse_check_button_pressed(mb_right)) { _c.selected_slot=-1; _c.selected_gem=-1; _c.shovel_selected=false; }
    var _slots=coop_guest_slots(_s,_c.player_id);
    for (var _i=0;_i<array_length(_slots);_i++) {
        var _slot=_slots[_i];
        if ((_i<9 && keyboard_check_pressed(ord("1")+_i)) || coop_ui_hit(_slot.x-45,_slot.y-55,90,120)) {
            _c.selected_slot=_i; _c.selected_gem=-1; _c.shovel_selected=false; return;
        }
    }
    if (coop_ui_hit(25,30,220,75)) { _c.shovel_selected=true; _c.selected_slot=-1; _c.selected_gem=-1; return; }
    var _gems=coop_get(_s,"gems",[]);
    for (var _i=0;_i<array_length(_gems);_i++) {
        if (coop_get(_gems[_i],"active",true) && coop_get(_gems[_i],"remaining_cd",0)<=0 && coop_ui_hit(25,230+_i*85,180,72)) { _c.selected_gem=_i; _c.shovel_selected=false; _c.selected_slot=-1; return; }
    }
    if (!mouse_check_button_pressed(mb_left)) return;
    var _g=coop_get(_s,"grid",{});
    var _col=floor((mouse_x-coop_get(_g,"offset_x",695))/coop_get(_g,"cell_x",107));
    var _row=floor((mouse_y-coop_get(_g,"offset_y",228))/coop_get(_g,"cell_y",116));
    // Moving platforms use visual offsets but commands carry logical grid cells.
    var _platforms=coop_get(_s,"platforms",[]),_blocked=false,_mapped=false;
    for (var _i=0;_i<array_length(_platforms);_i++) {
        var _p=_platforms[_i];
        var _pc=floor((mouse_x-_p.shift_x-_g.offset_x)/_g.cell_x);
        var _pr=floor((mouse_y-_p.shift_y-_g.offset_y)/_g.cell_y);
        if (_pc>=_p.col && _pc<_p.col+_p.width && _pr>=_p.row && _pr<_p.row+_p.height) { _col=_pc; _row=_pr; _mapped=true; break; }
        if (_col>=_p.col && _col<_p.col+_p.width && _row>=_p.row && _row<_p.row+_p.height) _blocked=true;
    }
    if (_blocked && !_mapped) return;
    if (_col<0 || _row<0 || _col>=coop_get(_g,"cols",0) || _row>=coop_get(_g,"rows",0)) return;
    var _placed=false;
    var _players=coop_get(_s,"players",[]);
    for (var _i=0;_i<array_length(_players);_i++) if (_players[_i].player_id==_c.player_id) _placed=coop_get(_players[_i],"placed",false);
    if (!_placed) { _c.send_input("place_player",{row:_row,col:_col}); return; }
    if (_c.shovel_selected) { _c.send_input("shovel",{row:_row,col:_col}); return; }
    if (_c.selected_gem>=0 && _c.selected_gem<array_length(_gems)) {
        var _gem=_gems[_c.selected_gem];
        _c.send_input("use_gem",{gem_index:_gem.gem_index,gem_id:_gem.gem_id,row:_row,col:_col}); _c.selected_gem=-1; return;
    }
    if (_c.selected_slot>=0 && _c.selected_slot<array_length(_slots)) {
        var _slot=_slots[_c.selected_slot];
        _c.send_input("place_card",{card_id:_slot.card_id,slot_index:coop_get(_slot,"slot_index",_c.selected_slot),row:_row,col:_col});
    }
}
function coop_guest_draw() {
    var _c=global.coop,_s=_c.latest;
    draw_clear(make_colour_rgb(12,26,35));
    var _bg=coop_get(_s,"background",{}),_bg_sprite=asset_get_index(coop_get(_bg,"sprite",""));
    if (sprite_exists(_bg_sprite)) draw_sprite(_bg_sprite,coop_get(_bg,"frame",0),0,0);
    var _entities=coop_get(_s,"entities",[]);
    if (coop_render_stamp != _c.received_at) {
        coop_render_stamp=_c.received_at; coop_previous_entities={};
        var _old=coop_get(_c.previous,"entities",[]);
        for (var _i=0;_i<array_length(_old);_i++) variable_struct_set(coop_previous_entities,_old[_i].id,_old[_i]);
    }
    var _blend_time=clamp((current_time-_c.received_at)/max(16,coop_get(_s,"snapshot_interval_ms",33)),0,1);
    for (var _i=0;_i<array_length(_entities);_i++) {
        var _e=_entities[_i],_sprite=asset_get_index(_e.sprite);
        if (!sprite_exists(_sprite)) continue;
        var _old=coop_get(coop_previous_entities,_e.id,_e);
        var _ex=lerp(_old.x,_e.x,_blend_time),_ey=lerp(_old.y,_e.y,_blend_time);
        draw_sprite_ext(_sprite,_e.frame,_ex,_ey,_e.xscale,_e.yscale,_e.angle,_e.blend,_e.alpha);
        if (coop_get(_e,"flash_alpha",0)>0) {
            shader_set(hit_effect_2);
            draw_sprite_ext(_sprite,_e.frame,_ex,_ey,_e.xscale,_e.yscale,_e.angle,_e.flash_colour,_e.flash_alpha);
            shader_reset();
        }
        var _effects=coop_get(_e,"effects",[]);
        for (var _j=0;_j<array_length(_effects);_j++) {
            var _fx=_effects[_j],_fs=asset_get_index(_fx.sprite);
            if (sprite_exists(_fs)) draw_sprite_ext(_fs,_fx.frame,_ex+_fx.dx,_ey+_fx.dy,_fx.xscale,_fx.yscale,0,_fx.blend,_fx.alpha);
        }
        var _hp=coop_get(_e,"healthbar",{});
        if (coop_get(_hp,"visible",false) && coop_get(_e,"max_hp",0)>0) {
            draw_set_alpha(1); draw_set_colour(c_black); draw_rectangle(_ex-42,_ey+_hp.offset_y-2,_ex+42,_ey+_hp.offset_y+15,false);
            draw_set_colour(_hp.colour); draw_rectangle(_ex-40,_ey+_hp.offset_y,_ex-40+80*clamp(_e.hp/_e.max_hp,0,1),_ey+_hp.offset_y+13,false);
            if (_hp.shield_max_hp>0) { draw_set_colour(c_aqua); draw_rectangle(_ex-40,_ey+_hp.offset_y+13,_ex-40+80*clamp(_hp.shield_hp/_hp.shield_max_hp,0,1),_ey+_hp.offset_y+17,false); }
        }
        if (coop_get(_e,"owner","") != "") {
            coop_ui_text(_e.x,_e.y-100,_e.owner==_c.player_id ? "你" : "队友",0.8,_e.owner==_c.player_id ? c_aqua : c_yellow,fa_center,100);
        }
    }
    draw_set_alpha(0.95); draw_set_colour(make_colour_rgb(15,38,47)); draw_roundrect(350,15,1900,178,false);
    coop_ui_sprite(spr_flame,0,390,80,55,60);
    var _balances=coop_get(_s,"balances",{});
    coop_ui_text(395,142,coop_guest_flame(_s,_c.player_id),0.9,c_white,fa_center,120);
    var _slots=coop_guest_slots(_s,_c.player_id);
    for (var _i=0;_i<array_length(_slots);_i++) {
        var _slot=_slots[_i],_x=_slot.x,_y=_slot.y;
        draw_set_colour(_c.selected_slot==_i ? make_colour_rgb(225,186,88) : make_colour_rgb(65,102,106));
        draw_roundrect(_x-43,_y-54,_x+43,_y+67,false);
        coop_ui_sprite(coop_get(_slot,"sprite",""),coop_get(_slot,"frame",0),_x,_y,70,78);
        coop_ui_text(_x,_y+52,coop_get(_slot,"cost",0),0.65,c_white,fa_center,78);
        var _cd=coop_get(_slot,"remaining_cd",0);
        if (_cd>0) {
            draw_set_alpha(0.7); draw_set_colour(c_black); draw_rectangle(_x-40,_y-50,_x+40,_y+35,false);
            coop_ui_text(_x,_y,string(ceil(_cd/60)),0.9,c_white,fa_center,70);
        }
        coop_ui_text(_x-32,_y-44,string(_i+1),0.5,c_white);
    }
    coop_ui_text(25,137,"你的火苗独立使用",0.64,make_colour_rgb(154,208,205),fa_left,240);
    var _team_players=coop_get(_s,"players",[]);
    for (var _i=0;_i<array_length(_team_players);_i++) {
        var _team_id=_team_players[_i].player_id;
        if (_team_id!=_c.player_id && variable_struct_exists(_balances,_team_id)) {
            coop_ui_text(25,178,"队友火苗 "+string(variable_struct_get(_balances,_team_id)),0.65,make_colour_rgb(151,189,197),fa_left,250);
        }
    }
    coop_ui_button(25,30,220,75,_c.shovel_selected ? "铲子 / 已选择" : "铲子");
    var _gems=coop_get(_s,"gems",[]);
    for (var _i=0;_i<array_length(_gems);_i++) {
        var _gem=_gems[_i],_name=coop_get(_gem,"name",get_gem_info(_gem.gem_id).name);
        var _enabled=coop_get(_gem,"active",true) && coop_get(_gem,"remaining_cd",0)<=0;
        if (!coop_get(_gem,"active",true)) _name+=" / 自动";
        else if (_gem.remaining_cd>0) _name+=" "+string(ceil(_gem.remaining_cd/60))+"秒";
        else if (_c.selected_gem==_i) _name+=" / 已选择";
        coop_ui_button(25,230+_i*85,180,72,_name,_enabled);
    }
    var _players=coop_get(_s,"players",[]);
    for (var _i=0;_i<array_length(_players);_i++) {
        if (_players[_i].player_id==_c.player_id && !_players[_i].placed) {
            coop_ui_sprite(_players[_i].sprite,0,mouse_x,mouse_y-35,110,150,0.65);
            coop_ui_text(960,900,"点击空地放置你的角色",1.2,c_yellow,fa_center,1500);
        }
    }
    var _bosses=coop_get(_s,"bosses",[]);
    for (var _i=0;_i<array_length(_bosses);_i++) {
        var _b=_bosses[_i],_by=275+_i*95;
        coop_ui_sprite(_b.icon,0,1405,_by+10,65,65);
        coop_ui_text(1450,_by-15,_b.name,0.75,c_white,fa_left,390);
        draw_set_colour(c_black); draw_rectangle(1450,_by+5,1840,_by+29,false);
        draw_set_colour(make_colour_rgb(220,93,109)); draw_rectangle(1452,_by+7,1452+386*clamp(_b.hp/max(1,_b.max_hp),0,1),_by+27,false);
    }
    coop_ui_text(40,950,coop_get(_s,"level_name","合作关卡"),0.9,c_white,fa_left,1000);
    var _wave="第 "+string(coop_get(_s,"wave",0))+" / "+string(coop_get(_s,"total_waves",0))+" 波";
    var _limit=coop_get(_s,"time_limit",-1);
    if (_limit>0) _wave+="  剩余 "+string(ceil(_limit/60))+" 秒";
    coop_ui_text(1840,950,_wave,0.8,c_white,fa_right,850);
    draw_set_colour(make_colour_rgb(10,27,37)); draw_set_alpha(0.92); draw_rectangle(0,988,1920,1080,false);
    var _hint=_c.all_connected() ? "数字键选卡 / 点击网格放置 / 右键取消 / 空格暂停" : "网络中断，战斗已暂停，正在等待重连";
    coop_ui_text(30,1010,_hint,0.8,c_white,fa_left,1820);
    var _status=_c.status;
    if (_status=="先分别放置自己的角色，再共同布阵" && !coop_get(_s,"paused",true)) _status="与队友共同布阵";
    coop_ui_text(30,1047,_status,0.65,make_colour_rgb(160,217,209),fa_left,1800);
    if (coop_get(_s,"paused",false) && !coop_get(_s,"game_over",false)) {
        var _placed=true;
        for (var _i=0;_i<array_length(_players);_i++) if (!_players[_i].placed) _placed=false;
        coop_ui_text(960,205,_placed ? "队伍已暂停 / 空格解除自己的暂停请求" : "两位玩家放置角色后开始",1,c_yellow,fa_center,1500);
    }
    if (coop_get(_s,"game_over",false)) coop_guest_rewards();
    draw_set_alpha(1); draw_set_halign(fa_left); draw_set_valign(fa_top); draw_set_colour(c_white);
}
function coop_guest_rewards() {
    var _c=global.coop,_s=_c.latest,_v=coop_get(_s,"victory",{});
    var _won=coop_get(_s,"outcome","")=="victory";
    draw_set_colour(make_colour_rgb(6,18,26)); draw_set_alpha(0.94); draw_rectangle(0,0,1920,1080,false);
    coop_ui_text(960,135,_won ? "共同冒险 / 胜利" : "再试一次",2.5,make_colour_rgb(250,206,111),fa_center,1700);
    if (_won && coop_get(_v,"scaling_applied",false)) {
        coop_ui_text(960,183,coop_get(_v,"difficulty_name","") + "  通关奖励 " + string(coop_get(_v,"multiplier",1)) + "倍",
            0.9,make_colour_rgb(139,210,189),fa_center,1500);
    }
    coop_ui_text(960,228,_c.result_saved ? "奖励与共同进度已保存到主机" : "正在等待主机确认存档…",1,c_white,fa_center,1500);
    var _resources=coop_get(_v,"resources",[]);
    for (var _i=0;_i<array_length(_resources);_i++) {
        var _r=_resources[_i],_x=330+_i*270;
        coop_ui_sprite(_r.sprite,coop_get(_r,"frame",0),_x,360,85,90);
        coop_ui_text(_x,445,_r.name+" + "+string(_r.amount),0.9,c_white,fa_center,255);
    }
    var _unlocks=coop_get(_v,"unlocks",[]),_pages=max(1,ceil(array_length(_unlocks)/6));
    coop_reward_page=clamp(coop_reward_page,0,_pages-1);
    for (var _i=coop_reward_page*6;_i<min(array_length(_unlocks),(coop_reward_page+1)*6);_i++) {
        var _r=_unlocks[_i],_x=285+(_i mod 6)*270;
        draw_set_colour(make_colour_rgb(31,63,71)); draw_roundrect(_x-115,515,_x+115,830,false);
        coop_ui_sprite(_r.sprite,coop_get(_r,"frame",0),_x,650,175,190);
        coop_ui_text(_x,786,_r.name,0.85,c_white,fa_center,205);
    }
    coop_ui_text(960,885,array_length(_unlocks)>0 ? "新获得的卡牌与装备" : "共同进度持续累积",1,c_white,fa_center,1400);
    if (_pages>1) coop_ui_text(960,935,"左右方向键翻页  "+string(coop_reward_page+1)+" / "+string(_pages),0.8,c_white,fa_center,1300);
    coop_ui_button(1450,950,360,72,"回到合作房间",_c.result_saved);
}
