package editor

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
ai_scene_outlines_follow_pending_authors_and_keep_selection_without_steady_allocations :: proc(t:^testing.T) {
    world:Pick_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    ref:=test_world_ref(&world)
    owner,derived,other,selected:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,owner,{value=1});core.add(&world.ids,other,{value=2});core.add(&world.ids,selected,{value=3})
    core.add(&world.parents,derived,{entity=owner})
    for e in ([4]core.Entity{owner,derived,other,selected}) {core.add(&world.meshes,e,{shape=.Cube});core.add(&world.transforms,e,core.TRANSFORM_IDENTITY)}
    test_world_settle(&world)
    m:=new(Ai);defer free(m)
    m.task_count=2
    m.tasks[0].world,m.tasks[1].world=&world,&world
    m.tasks[0].state,m.tasks[1].state=.Running,.Done
    m.tasks[0].color_index,m.tasks[1].color_index=4,5
    m.tasks[0].context_ids[0],m.tasks[0].context_count=3,1
    m.tasks[0].review.pending,m.tasks[1].review.pending=true,true
    m.tasks[0].review.changed_ids=make([dynamic]base.Entity_Id)
    m.tasks[1].review.changed_ids=make([dynamic]base.Entity_Id)
    append(&m.tasks[0].review.changed_ids,1);append(&m.tasks[1].review.changed_ids,2)
    defer delete(m.tasks[0].review.changed_ids);defer delete(m.tasks[1].review.changed_ids)
    v:Viewport;defer viewport_free(&v)
    selection:history.Selection;defer delete(selection.entities)
    history.selection_set(&selection,{selected})
    app:host.App
    g:Editor_Ui
    session:=Session{ai=m,app=&app,viewport=&v,selection=&selection,gui=&g,edit_world=&world}
    highlight_sync(&session,ref);core.table_settle(&world.highlights,&world.entities)
    testing.expect_value(t,entity_level(&v,owner),u8(9))
    testing.expect_value(t,entity_level(&v,derived),u8(9))
    testing.expect_value(t,entity_level(&v,other),u8(10))
    testing.expect(t,entity_level(&v,selected)==u8(9),"what a working turn was given takes its color over the selection")
    history.selection_clear(&selection)
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&v,selected)==u8(9),"and keeps it after deselection")
    history.selection_set(&selection,{selected})
    highlight_sync(&session,ref)
    version:=world.highlights.version
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for _ in 0..<64 {highlight_sync(&session,ref)}
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect_value(t,world.highlights.version,version)
    m.tasks[0].review.pending=false;m.scene_serial+=1
    highlight_sync(&session,ref)
    testing.expect_value(t,entity_level(&v,owner),u8(0))
    testing.expect_value(t,entity_level(&v,derived),u8(0))
    testing.expect_value(t,entity_level(&v,other),u8(10))
    m.tasks[1].review_finished=true;m.scene_serial+=1
    highlight_sync(&session,ref)
    testing.expect_value(t,entity_level(&v,other),u8(0))
    testing.expect_value(t,entity_level(&v,selected),u8(9))
    // Once the turn ended, what it was given is soft, under the selection.
    m.tasks[0].state=.Done;m.scene_serial+=1
    highlight_sync(&session,ref)
    testing.expect_value(t,entity_level(&v,selected),HIGHLIGHT_SELECTED)
    history.selection_clear(&selection)
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&v,selected)==AI_CONTEXT_LEVEL,"sent context keeps a soft outline of its own after deselection")
    m.show_agents_in_scene=true
    g.layout.library_tab=.Content
    testing.expect(t,ai_scene_task_visible(&session,ref,&m.tasks[0]),"scene figures remain visible on the Content tab")
    g.layout.left_open=false
    testing.expect(t,ai_scene_task_visible(&session,ref,&m.tasks[0]),"closing the browser does not hide scene figures")
    testing.expect(t,!ai_scene_task_visible(&session,ref,&m.tasks[1]),"Finish removes a scene figure")
    other_world:Pick_Test_World
    testing.expect(t,!ai_scene_task_visible(&session,core.world_ref(&other_world,test_world_info(&world)),&m.tasks[0]),"a task never appears on another document")
    m.task_count=3
    m.tasks[2].world,m.tasks[2].state=&world,.Running
    testing.expect(t,!ai_scene_task_visible(&session,ref,&m.tasks[2]),"a turn without context that changed nothing is not in the scene")
    m.tasks[2].context_ids[0],m.tasks[2].context_count=3,1
    testing.expect(t,ai_scene_task_visible(&session,ref,&m.tasks[2]),"the context the user selected puts a turn in the scene")
    // A game is seen alone: no figure, glyph or name while it plays, paused or stepped.
    modes:=[?]struct{mode:Mode,stepped,shown:bool}{
        {.Edit,false,true},{.Simulate,false,true},{.Simulation_Paused,false,true},
        {.Play,false,false},{.Paused,false,false},{.Paused,true,false},{.Watch,false,false},
    }
    m.scene_serial+=1
    for c in modes {
        session.mode,session.play_stepped=c.mode,c.stepped
        testing.expectf(t,ai_scene_figure_shown(&session,ref,&m.tasks[2])==c.shown,"figure shown in %v (stepped %v): %v",c.mode,c.stepped,c.shown)
        if c.mode==.Watch {continue}
        highlight_sync(&session,ref)
        testing.expectf(t,(entity_level(&v,selected)!=0)==c.shown,"outline of an agent in %v (stepped %v): %v",c.mode,c.stepped,c.shown)
    }
    session.mode,session.play_stepped=.Edit,false
    m.task_count=2
    m.tasks[0].state=.Done
    testing.expect(t,ai_task_finish(&session,m,&m.tasks[0]))
    history.selection_clear(&selection)
    highlight_sync(&session,ref)
    testing.expect(t,entity_level(&v,selected)==0,"Finish removes sent context outlines")
}

@(test)
ai_sent_context_is_not_evicted_before_its_review_is_finished :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m)
    m.task_count=AI_TASK_CAPACITY
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.state=.Done
        task.context_count=1;task.context_ids[0]=base.Entity_Id(index+1)
    }
    testing.expect(t,ai_task_slot(m)==nil,"sent context stays outlined until its review is resolved")
    m.tasks[AI_TASK_CAPACITY-1].review_finished=true
    testing.expect(t,ai_task_slot(m)!=nil,"a confirmed conversation can free a cache slot")
    testing.expect(t,m.tasks[0].id==1 && m.tasks[0].context_count==1,"unconfirmed context remains in the cache")
}

@(test)
ai_scene_figures_render_as_transient_geometry_and_reuse_descriptors :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    mounts:=[1]asset.Registry_Mount{{folder=EDITOR_ASSETS,prefix=EDITOR_ASSETS_PREFIX}}
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",asset_mounts=mounts[:],window_desc={size={128,128}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    viewport:=Viewport{orbit=ORBIT_DEFAULT}
    session:=Session{app=app,viewport=&viewport}
    // It faces the camera, which looks at it along -Z.
    task:=Ai_Task{id=7,anchor_set=true,facing=math.PI}
    figure:Presence
    ready:=false
    for _ in 0..<8 {
        ready=ai_scene_figure_prepare(&session,&task,&figure)
        host.assets_commit(app.assets)
        if ready {break}
    }
    if !testing.expect(t,ready,"the pup of the editor's assets loads") {return}
    file:asset.Asset
    if testing.expect_value(t,asset.asset_load(&file,EDITOR_ASSETS+"/presence/pup.mesh"),asset.Error.None) {
        defer asset.asset_close(&file)
        view,error:=asset.mesh_view(&file,&app.assets.types)
        if testing.expect_value(t,error,asset.Error.None) && testing.expect(t,len(view.slots)>int(PRESENCE_STARS_SLOT)) {
            labels:=[4]string{"Color arnes","Color franja nave","Color pantalla","Color estrellas"}
            for slot,i in PRESENCE_COLOR_SLOTS {
                testing.expect_value(t,base.text_get(view.slots[slot].label[:]),labels[i])
            }
        }
    }
    before:=figure
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        for _ in 0..<64 {testing.expect(t,ai_scene_figure_prepare(&session,&task,&figure))}
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect_value(t,figure,before)
    instance:=figure.instance
    testing.expect_value(t,instance.object_id,u64(0))
    testing.expect(t,instance.copy_owner==PRESENCE_OWNER && instance.copy_variant==u64(task.id))
    testing.expect_value(t,instance.highlight,agent_level(int(task.color_index)))
    testing.expect_value(t,instance.slot_materials[0],u32(0))
    testing.expect_value(t,instance.slot_materials[4],u32(0))
    color:=agent_color(int(task.color_index))
    linear:=mm.srgb_to_linear([3]f32{f32(color[0])/255,f32(color[1])/255,f32(color[2])/255})
    for slot in PRESENCE_COLOR_SLOTS {
        row:=instance.slot_materials[slot]
        if testing.expect(t,row>0,"each colored part has its own derived material") {
            values:=host.assets_material_values(app.assets,row-1)
            testing.expect_value(t,values.info.base_color,linear)
            if slot==PRESENCE_STARS_SLOT {
                testing.expect_value(t,values.info.emission,linear)
            }
        }
    }
    other:Presence
    other_color:=agent_color(1)
    testing.expect(t,presence_prepare(&session,&other,figure.at+{0.75,0,0},math.PI,other_color,agent_level(1),100))
    for slot in PRESENCE_COLOR_SLOTS {
        testing.expect(t,other.instance.slot_materials[slot]>0 && other.instance.slot_materials[slot]!=instance.slot_materials[slot],"different figures retain different colors")
    }

    host.assets_commit(app.assets)
    renderer:=app.renderer
    instances:=[2]gpu.Instance_Desc{instance,other.instance}
    for &shown in instances {shown.highlight=0}
    gpu.scene_set_environment(renderer,{direction={0.3,0.8,0.6},color={1,1,1},illuminance=math.PI,enabled=true},{background={},use_background=true})
    gpu.scene_update(renderer,0,instances[:],true)
    camera:=gpu.Camera{position={0.375,0.5,2.4},forward={0,-0.05,-2.4},up={0,1,0},fov_y=45,near=0.05,far=100}
    for _ in 0..<4 {testing.expect(t,gpu.renderer_frame(renderer,{camera=camera}),renderer.error)}
    rhi.device_wait_idle(app.device)
    pixels,width,height,ok:=gpu.renderer_capture(renderer)
    testing.expect(t,ok,renderer.error)
    if ok {
        defer delete(pixels)
        mint,purple,fur:=0,0,0
        for i in 0..<width*height {
            r,g,b:=int(pixels[i*4]),int(pixels[i*4+1]),int(pixels[i*4+2])
            if g>r+8 && g>b+3 {mint+=1}
            if b>r+8 && b>g+8 {purple+=1}
            if r>g+30 && g>b+20 {fur+=1}
        }
        testing.expectf(t,fur>300,"the dog is real rendered geometry with its own colors: %d pixels",fur)
        testing.expectf(t,mint>20 && purple>20,"both figures show their colors at once: mint %d, purple %d pixels",mint,purple)
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
