package editor

import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:ui"

@(test)
post_process_helpers_compact_and_keep_neighbors_in_their_stage :: proc(t:^testing.T) {
	layers:[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer
	layers[0]={material=base.Asset_Id{1,0},after_tonemap=false}
	layers[2]={material=base.Asset_Id{2,0},after_tonemap=false}
	layers[3]={material=base.Asset_Id{3,0},after_tonemap=true}
	layers[5]={material=base.Asset_Id{4,0},after_tonemap=true}
	testing.expect_value(t,post_process_count(&layers),4)
	testing.expect_value(t,post_process_compact(&layers),4)
	testing.expect(t,layers[0].material==base.Asset_Id{1,0})
	testing.expect(t,layers[1].material==base.Asset_Id{2,0})
	testing.expect(t,layers[2].material==base.Asset_Id{3,0})
	testing.expect(t,layers[3].material==base.Asset_Id{4,0})
	testing.expect(t,layers[4].material==base.Asset_Id{})
	testing.expect_value(t,post_process_neighbor(&layers,0,1),1)
	testing.expect_value(t,post_process_neighbor(&layers,1,1),-1)
	testing.expect_value(t,post_process_neighbor(&layers,2,1),3)
	testing.expect_value(t,post_process_neighbor(&layers,3,-1),2)
	testing.expect_value(t,post_process_neighbor(&layers,2,-1),-1)
}

@(test)
post_process_inspect_counts_the_effects_up_to_a_layer_on_each_side :: proc(t:^testing.T) {
	layers:[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer
	layers[0]={material=base.Asset_Id{1,0},enabled=true}
	layers[1]={material=base.Asset_Id{2,0},after_tonemap=true,enabled=true}
	layers[2]={material=base.Asset_Id{3,0},enabled=false}
	layers[3]={material=base.Asset_Id{4,0},enabled=true}
	layers[4]={material=base.Asset_Id{5,0},after_tonemap=true,enabled=true}
	usable:[erender.POST_PROCESS_CAPACITY]bool
	for i in 0..<5 {usable[i]=true}
	effects,ok:=post_process_inspect_counts(&layers,usable,0)
	testing.expect(t,ok && effects==[2]u8{1,0})
	effects,ok=post_process_inspect_counts(&layers,usable,3)
	testing.expect(t,ok && effects==[2]u8{2,0})
	effects,ok=post_process_inspect_counts(&layers,usable,1)
	testing.expect(t,ok && effects==[2]u8{2,1})
	effects,ok=post_process_inspect_counts(&layers,usable,4)
	testing.expect(t,ok && effects==[2]u8{2,2})
	_,ok=post_process_inspect_counts(&layers,usable,2)
	testing.expect(t,!ok,"a disabled layer shows nothing")
	usable[0]=false
	effects,ok=post_process_inspect_counts(&layers,usable,3)
	testing.expect(t,ok && effects==[2]u8{1,0},"a layer the renderer cannot use is not counted")
}

Post_Process_Test_World :: struct {
	entities:core.Entities,
	ids:core.Table(core.Id),
	transforms:core.Table(core.Transform),
	parents:core.Table(core.Parent),
	volumes:core.Table(erender.View_Volume),
}

@(private="file")
post_process_test_settle :: proc(data,shared,editor:rawptr) {
	w:=cast(^Post_Process_Test_World)data
	core.table_settle(&w.ids,&w.entities)
	core.table_settle(&w.transforms,&w.entities)
	core.table_settle(&w.parents,&w.entities)
	core.table_settle(&w.volumes,&w.entities)
	core.entities_settle(&w.entities)
}

@(test)
the_fade_of_a_layer_is_edited_under_its_row_as_one_undo_step :: proc(t:^testing.T) {
	world:Post_Process_Test_World
	core.entities_init(&world.entities)
	core.table_init(&world.ids,"Id")
	core.table_init(&world.transforms,"Transform")
	core.table_init(&world.parents,"Parent")
	core.table_init(&world.volumes,"View_Volume")
	defer core.entities_destroy(&world.entities)
	defer core.table_destroy(&world.ids)
	defer core.table_destroy(&world.transforms)
	defer core.table_destroy(&world.parents)
	defer core.table_destroy(&world.volumes)
	tables:=[4]core.Table_Info{
		{name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Post_Process_Test_World,ids)},
		{name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Post_Process_Test_World,transforms)},
		{name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Post_Process_Test_World,parents)},
		{name="View_Volume",type=erender.View_Volume,info=type_info_of(erender.View_Volume),offset=offset_of(Post_Process_Test_World,volumes)},
	}
	info:=core.World_Info{entities=offset_of(Post_Process_Test_World,entities),tables=tables[:]}
	e:=core.create(&world.entities)
	core.add(&world.ids,e,core.Id{1})
	core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)
	volume:erender.View_Volume
	volume.layers[0]={enabled=true} // the row reads no asset without a material
	core.add(&world.volumes,e,volume)
	post_process_test_settle(&world,nil,nil)

	ctx:ui.Context
	if !testing.expect(t,ui.context_init(&ctx,{no_font=true})) {return}
	defer ui.context_destroy(&ctx)
	gui:=Editor_Ui{ctx=&ctx}
	edits:Edits
	selection:Selection
	viewport:Viewport
	inspector:Inspector
	materials:Materials
	s:=Session{info=&info,edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,inspector=&inspector,materials=&materials}
	w:=edited_world(&s)
	edits_reset(&edits,w)
	defer edits_free(&edits)
	defer delete(selection.entities)
	selection_set(&selection,{e})
	fade :: proc(w:^Post_Process_Test_World,e:core.Entity) -> f32 {
		v,_:=core.get(core.read(&w.volumes),e)
		return v.layers[0].fade
	}
	frame :: proc(s:^Session,w:^Post_Process_Test_World,e:core.Entity,input:ui.Input) {
		ui.frame_begin(s.gui.ctx,input)
		v,_:=core.get(core.read(&w.volumes),e)
		if ui.box(s.gui.ctx,{width=ui.fixed(320),height=ui.FIT,direction=.Column}) {post_process_row(s,0,v.layers[0])}
		ui.frame_end(s.gui.ctx)
	}
	size:=[2]f32{400,200}
	for _ in 0..<3 {frame(&s,&world,e,{size=size,pointer_absent=true})}
	track,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,ui.id(&ctx,"post_fade",1),"track"))
	if !testing.expect(t,found && track.w>12,"the layer has a fade slider") {return}
	frame(&s,&world,e,{size=size,pointer=ui.rect_center(track),down={.Left},pressed={.Left}})
	frame(&s,&world,e,{size=size,pointer=ui.rect_center(track),released={.Left}})
	edits_flush(&edits,w,&selection)
	testing.expectf(t,abs(fade(&world,e)-0.5)<0.01,"the middle of the slider is half the fade: %v",fade(&world,e))
	testing.expect(t,undo(&edits,w,&selection))
	testing.expect_value(t,fade(&world,e),f32(0))
}
