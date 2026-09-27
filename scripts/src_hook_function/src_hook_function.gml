global._move_instance_pre_arr = []
global._move_instance_map = ds_map_create()
global._last_platform = -1

#macro instance_create_depth_origfunc instance_create_depth
#macro instance_create_depth          instance_create_depth_define


function instance_create_depth_define(_x, _y, _depth, _obj, _variables = undefined) {

	// Preserve GameMaker's optional pre-Create variables. Co-op ownership and
	// copy-card targets must reach the new instance before its Create event.
	var _inst = is_struct(_variables)
		? instance_create_depth_origfunc(_x, _y, _depth, _obj, _variables)
		: instance_create_depth_origfunc(_x, _y, _depth, _obj);
	array_push(global._move_instance_pre_arr,_inst);
	if (_obj == obj_platform)
		global._last_platform = _inst;

	return _inst;
}
