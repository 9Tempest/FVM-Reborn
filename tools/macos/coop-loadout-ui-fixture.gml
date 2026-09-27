#macro room_menu -100001
#macro room_battle -100002
#macro room_coop room_autosave_tests

function coop_get(_value,_key,_fallback=undefined) {
    return is_struct(_value) && variable_struct_exists(_value,_key) ? variable_struct_get(_value,_key) : _fallback;
}
function coop_is_active() { return global.coop.active; }
function coop_battle_can_run() { return true; }
function get_plant_shape_data(_id,_shape) { return deck_get_card_data(_id,_shape); }
function get_card_info_simple(_id) {
    for (var _i=0;_i<array_length(global.save_data.unlocked_cards);_i++) {
        if (global.save_data.unlocked_cards[_i].id==_id) return global.save_data.unlocked_cards[_i];
    }
    return false;
}
function get_gem_info(_id) { return {name:"测试宝石"}; }
function fixture_expect(_name,_ok) {
    array_push(global.fixture_tests,{name:_name,passed:_ok});
    show_debug_message("FVM_LOADOUT_UI_ASSERT="+string(_ok)+" "+_name);
}
function fixture_configure() {
    global.fixture_tests=[]; global.fixture_images=[];
    global.player_deck=ds_list_create(); global.selected_deck=ds_list_create();
    global.save_data={unlocked_cards:[],unlocked_items:{max_slot:21}};
    global.gui_stack={last_room:-1,to:function(_room) { last_room=_room; }};
    var _sprites=[spr_double_long_bao,spr_coke_bomb,spr_mouse_clip];
    var _names=["双层小笼包","可乐炸弹","老鼠夹子"];
    for (var _i=0;_i<100;_i++) {
        var _id="card_"+string(_i),_shape=_i mod 3,_level=(_i mod 9)+1;
        array_push(global.save_data.unlocked_cards,{id:_id,shape:_shape,level:_level});
        var _data=ds_map_create(),_shapes=ds_list_create(),_entry=ds_map_create();
        _data[? "name"]=_names[_i mod 3]+" "+string(_i+1);
        _data[? "shape"]=_shape; _data[? "cost"]=25+(_i mod 8)*25; _data[? "sprite"]=_sprites[_i mod 3];
        ds_list_add(_shapes,_data); _entry[? "shapes"]=_shapes;
        ds_list_add(global.player_deck,_id,_entry);
    }
    global.coop={active:true,role:"host",player_id:"host-id",connected:true,battle_started:false,
        players:[{player_id:"host-id",name:"房主",connected:true},{player_id:"guest-id",name:"队友",connected:true}],
        preparation:{id:"test-preparation",level_id:"cookie_island",level_name:"曲奇岛 / 双人卡组准备",slot_limit:21,selections:{},revision:1},
        loadout_draft:[],loadout_pending:false,loadout_host_level_ready:true,
        match_config:{loadouts:{}},status:"选好你的卡组，准备后等待队友",set_calls:0,
        selected_slot:-1,selected_gem:-1,shovel_selected:false,
        all_connected:function() { return connected; },
        set_loadout:function(_deck,_ready) {
            set_calls++;
            loadout_draft=_deck;
            variable_struct_set(preparation.selections,player_id,{deck:_deck,ready:_ready,cached:false});
            return true;
        },
        cancel_preparation:function() { status="正在取消准备…"; loadout_pending=true; return true; },
        leave:function() { global.fixture_leave_called=true; }
    };
    variable_struct_set(global.coop.preparation.selections,"host-id",{deck:[],ready:false,cached:false});
    variable_struct_set(global.coop.preparation.selections,"guest-id",{deck:["card_0"],ready:false,cached:false});
    global.fixture_leave_called=false;
    coop_invite_text=""; coop_typing=false; coop_reward_page=0; coop_pause_vote=false;
    coop_render_stamp=-1; coop_previous_entities={};
    fixture_frame=0;
}
function fixture_checks() {
    var _c=global.coop;
    fixture_expect("All 100 unlocked cards available",array_length(coop_loadout_cards())==100);
    fixture_expect("Can choose a card also selected by teammate",coop_loadout_toggle("card_0") && array_length(_c.loadout_draft)==1);
    fixture_expect("Toggle selected card removes only local selection",coop_loadout_toggle("card_0") && array_length(_c.loadout_draft)==0 && array_length(variable_struct_get(_c.preparation.selections,"guest-id").deck)==1);
    _c.loadout_pending=true;
    var _calls=_c.set_calls;
    fixture_expect("Pending ACK blocks editing",!coop_loadout_toggle("card_1") && _c.set_calls==_calls);
    _c.loadout_pending=false;
    variable_struct_set(_c.preparation.selections,"host-id",{deck:[],ready:true});
    fixture_expect("Ready must be cancelled before editing",!coop_loadout_toggle("card_1") && _c.set_calls==_calls);
    variable_struct_set(_c.preparation.selections,"host-id",{deck:[],ready:false});
    _c.connected=false;
    fixture_expect("Disconnected client cannot edit",!coop_loadout_toggle("card_1"));
    _c.connected=true;
    var _full=[];
    for (var _i=0;_i<21;_i++) array_push(_full,"card_"+string(_i));
    _c.set_loadout(_full,false); _calls=_c.set_calls;
    fixture_expect("Uses existing 21-slot maximum, without extra card",!coop_loadout_toggle("card_22") && array_length(_c.loadout_draft)==21 && _c.set_calls==_calls);
    fixture_expect("A full deck can still remove a card",coop_loadout_toggle("card_20") && array_length(_c.loadout_draft)==20);
    var _snap={per_player_loadouts:true,slots:[
        {owner:"host-id",slot_index:1,card_id:"card_0"},
        {owner:"guest-id",slot_index:3,card_id:"card_2"},
        {owner:"guest-id",slot_index:1,card_id:"card_1"},
        {slot_index:2,card_id:"card_3"}]};
    var _slots=coop_guest_slots(_snap,"guest-id");
    fixture_expect("Guest HUD contains only own slots",array_length(_slots)==2 && _slots[0].card_id=="card_1" && _slots[1].card_id=="card_2");
    fixture_expect("Legacy snapshots still show shared slots",array_length(coop_guest_slots({slots:_snap.slots},"guest-id"))==4);
    var _balances={}; variable_struct_set(_balances,"host-id",250); variable_struct_set(_balances,"guest-id",60);
    fixture_expect("Guest reads its own independent flame balance",coop_guest_flame({per_player_loadouts:true,balances:_balances,flame:250},"guest-id")==60);
    fixture_expect("Missing personal balance cannot show host money",coop_guest_flame({per_player_loadouts:true,balances:{},flame:250},"guest-id")==0);
    fixture_expect("Legacy flame remains compatible",coop_guest_flame({flame:250},"guest-id")==250);
    fixture_expect("Unconfirmed UI draft cannot launch",!coop_loadout_launch_host() && global.gui_stack.last_room==-1);
    variable_struct_set(_c.match_config.loadouts,"host-id",["card_5","card_1"]);
    _c.loadout_host_level_ready=false;
    fixture_expect("Host must restore level before launching",!coop_loadout_launch_host());
    _c.loadout_host_level_ready=true;
    fixture_expect("Confirmed host deck launches",coop_loadout_launch_host() && global.gui_stack.last_room==room_battle);
    fixture_expect("Confirmed order and host-library shapes retained",global.selected_deck[|0][?"card_id"]=="card_5" && global.selected_deck[|0][?"shape"]==2 && global.selected_deck[|1][?"card_id"]=="card_1" && global.selected_deck[|1][?"shape"]==1);
    _c.prepare_loadout=function(_level,_name,_limit) {
        global.fixture_prepared={level_id:_level,level_name:_name,slot_limit:_limit};
        global.fixture_prepare_calls++;
        return true;
    };
    global.fixture_prepare_calls=0; global.fixture_prepared=undefined;
    global.level_data={id:"stale",name:"旧关卡"};
    var _ready=instance_create_depth(0,0,0,obj_readyroom_manager);
    var _selection_list=_ready.select_card_index;
    fixture_expect("Readyroom Create retains confirmed deck and creates no solo start button",deck_slot_count()==2 && instance_number(obj_battlestart_button)==0 && global.fixture_prepare_calls==0);
    global.level_data={id:"after-create",name:"延后确认的关卡"};
    with (_ready) event_perform(ev_step,0);
    fixture_expect("Readyroom Step uses final level globals and current slot limit",global.fixture_prepared.level_id=="after-create" && global.fixture_prepared.slot_limit==21 && global.gui_stack.last_room==room_coop);
    with (_ready) event_perform(ev_step,0);
    fixture_expect("Repeated readyroom Step does not flood prepare requests",global.fixture_prepare_calls==1);
    with (_ready) instance_destroy();
    fixture_expect("Redirected readyroom safely cleans up its list",!ds_exists(_selection_list,ds_type_list));
    // A full two-player loadout stresses the maximum slot count and pagination.
    _c.set_loadout(_full,false);
    variable_struct_set(_c.preparation.selections,"host-id",{deck:_full,ready:false,cached:true});
    variable_struct_set(_c.preparation.selections,"guest-id",{deck:_full,ready:true,cached:false});
    var _ui=coop_loadout_state(); _ui.notice=""; _ui.notice_until=0; _ui.page=0;
}
function fixture_image(_name) {
    var _path=game_save_id+_name;
    surface_save(application_surface,_path);
    array_push(global.fixture_images,_path);
    show_debug_message("FVM_LOADOUT_UI_IMAGE="+_path);
}
function fixture_guest_hud() {
    var _c=global.coop,_slots=[],_cards=coop_loadout_cards(),_balances={};
    variable_struct_set(_balances,"host-id",250); variable_struct_set(_balances,"guest-id",60);
    for (var _owner=0;_owner<2;_owner++) {
        for (var _i=0;_i<21;_i++) {
            var _card=_cards[_i],_x=535+min(_i,14)*90,_y=_i<15 ? 90 : 90+(_i-14)*118;
            array_push(_slots,{owner:_owner==0 ? "host-id" : "guest-id",slot_index:_i+1,card_id:_card.id,
                x:_x,y:_y,sprite:sprite_get_name(_card.sprite),preview:sprite_get_name(_card.sprite),frame:0,
                cost:_card.cost,cooldown:420,remaining_cd:_i mod 3==0 ? 300 : 0,ready:true});
        }
    }
    _c.player_id="guest-id"; _c.role="guest"; _c.battle_started=true; _c.loadout_pending=false;
    _c.received_at=current_time; _c.previous=undefined; _c.status="各自出牌，共同闯关";
    _c.latest={per_player_loadouts:true,balances:_balances,flame:250,slots:_slots,entities:[],gems:[],bosses:[],platforms:[],
        background:{sprite:""},grid:{cols:9,rows:6,offset_x:695,offset_y:228,cell_x:107,cell_y:116},
        level_name:"曲奇岛 / 双人战斗",wave:2,total_waves:10,time_limit:7200,paused:false,game_over:false,
        players:[{player_id:"host-id",placed:true},{player_id:"guest-id",placed:true}]};
    _c.send_input=function(_action,_payload) { global.fixture_command={action:_action,payload:_payload}; return true; };
}
function fixture_step() {
    fixture_frame++;
    if (fixture_frame==20) keyboard_key_press(vk_right);
    if (fixture_frame==21) keyboard_key_release(vk_right);
    if (fixture_frame==24) {
        fixture_expect("Right arrow advances actual picker page",global.coop_loadout_ui.page==1);
        global.coop_loadout_ui.page=0;
    }
    if (fixture_frame==45) fixture_image("loadout-first-page.png");
    if (fixture_frame==50) global.coop_loadout_ui.page=4;
    if (fixture_frame==65) fixture_image("loadout-final-page.png");
    if (fixture_frame==70) {
        global.coop.loadout_pending=true;
        global.coop.status="正在同步选卡…";
    }
    if (fixture_frame==85) fixture_image("loadout-waiting-ack.png");
    if (fixture_frame==90) fixture_guest_hud();
    if (fixture_frame==105) fixture_image("guest-personal-21-slots.png");
    if (fixture_frame==110) keyboard_key_press(ord("1"));
    if (fixture_frame==111) keyboard_key_release(ord("1"));
    if (fixture_frame==115) fixture_expect("Guest number key selects its filtered first slot",global.coop.selected_slot==0);
    if (fixture_frame==120) {
        var _passed=0;
        for (var _i=0;_i<array_length(global.fixture_tests);_i++) if (global.fixture_tests[_i].passed) _passed++;
        show_debug_message("FVM_AUTOSAVE_RESULT="+json_stringify({passed:_passed,total:array_length(global.fixture_tests),tests:global.fixture_tests,images:global.fixture_images}));
        game_end();
    }
}
