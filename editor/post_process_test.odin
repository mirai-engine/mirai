package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
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
	using world:core.Test_World,
	using scene_tables:Test_Scene,
	volumes:core.Table(erender.View_Volume),
}

@(test)
the_fade_of_a_layer_is_edited_under_its_row_as_one_undo_step :: proc(t:^testing.T) {
	world:Post_Process_Test_World
	if !core.test_world_init(t,&world,test_types) {return}
	defer core.test_world_destroy(&world)
	info:=core.test_world_info(&world)
	e:=core.create(&world.entities)
	core.add(&world.ids,e,core.Id{1})
	core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)
	volume:erender.View_Volume
	volume.layers[0]={enabled=true} // the row reads no asset without a material
	core.add(&world.volumes,e,volume)
	core.test_world_settle(&world)

	ctx:ui.Context
	if !testing.expect(t,test_ui_init(&ctx,{no_font=true})) {return}
	defer ui.context_destroy(&ctx)
	gui:=Editor_Ui{ctx=&ctx}
	edits:history.Edits
	selection:history.Selection
	viewport:Viewport
	inspector:Inspector
	materials:Materials
	s:=Session{info=info,edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,inspector=&inspector,materials=&materials}
	w:=edited_world(&s)
	history.edits_reset(&edits,w)
	defer history.edits_free(&edits)
	defer delete(selection.entities)
	history.selection_set(&selection,{e})
	fade :: proc(w:^Post_Process_Test_World,e:core.Entity) -> f32 {
		v,_:=core.get(&w.volumes,e)
		return v.layers[0].fade
	}
	frame :: proc(s:^Session,w:^Post_Process_Test_World,e:core.Entity,input:ui.Input) {
		ui.frame_begin(s.gui.ctx,input)
		v,_:=core.get(&w.volumes,e)
		if ui.box(s.gui.ctx,{width=ui.fixed(320),height=ui.FIT,direction=.Column}) {post_process_row(s,0,v.layers[0])}
		ui.frame_end(s.gui.ctx)
	}
	size:=[2]f32{400,200}
	for _ in 0..<3 {frame(&s,&world,e,{size=size,pointer_absent=true})}
	track,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,ui.id(&ctx,"post_fade",1),"track"))
	if !testing.expect(t,found && track.w>12,"the layer has a fade slider") {return}
	frame(&s,&world,e,{size=size,pointer=ui.rect_center(track),down={.Left},pressed={.Left}})
	frame(&s,&world,e,{size=size,pointer=ui.rect_center(track),released={.Left}})
	history.edits_flush(&edits,w,&selection)
	testing.expectf(t,abs(fade(&world,e)-0.5)<0.01,"the middle of the slider is half the fade: %v",fade(&world,e))
	testing.expect(t,history.undo(&edits,w,&selection))
	testing.expect_value(t,fade(&world,e),f32(0))
}
