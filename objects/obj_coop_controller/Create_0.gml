if (instance_number(obj_coop_controller)>1) { instance_destroy(); exit; }
depth=-100000;
global.coop=new CoopSession();
coop_invite_text="";
coop_typing=false;
coop_pause_vote=false;
coop_reward_page=0;
coop_render_stamp=-1;
coop_previous_entities={};
