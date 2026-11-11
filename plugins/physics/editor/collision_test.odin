package physics_editor

import "mirai:editor"
import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import phys "plugins:physics/runtime"
import "mirai:ui"

@(private="file") Collision_Inspector_Row :: struct {layers:phys.Collision_Layers}
@(private="file") INSPECTOR_WORLD :: phys.Collision_Category(1)
@(private="file") INSPECTOR_CAMERA :: phys.Collision_Category(2)
@(private="file") Collision_Inspector_World :: struct {
    using world:core.Test_World,
    rows:core.Table(Collision_Inspector_Row),
    colliders:core.Table(phys.Collider),
    settings:phys.Collision_Settings,
}

// The storages physics gives the World of the editor.
@(private="file")
Physics_Editor_Test_World :: struct {
    inspector:Physics_Inspector,
}

@(private="file")
collision_inspector_frame :: proc(t:^testing.T,s:^editor.Session,input:ui.Input,type:typeid) {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    c:=editor.inspect_component(s,editor.edited_world(s),type,s.selection.entities[:])
    defaults:[size_of(phys.Collider)]u8
    c.defaults=raw_data(defaults[:])
    if ui.box(ctx,{width=ui.fixed(264),height=ui.FIT,direction=.Column}) {editor.fields_rows(&c,c.t.info,0,0,"")}
    output:=ui.frame_end(ctx)
    testing.expect(t,!output.overflow)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(private="file")
collision_inspector_click :: proc(t:^testing.T,s:^editor.Session,id:ui.Id,type:typeid) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    if !testing.expect(t,found) {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,420},pointer=ui.rect_center(rect)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        collision_inspector_frame(t,s,input,type)
    }
    history.edits_flush(s.edits,editor.edited_world(s),s.selection)
}

@(private="file")
Collision_Inspector :: struct {
    world:Collision_Inspector_World,
    editor_world:Physics_Editor_Test_World,
    info:core.World_Info,
    names:[6]core.Name_Info,
    named_types:[2]core.Named_Type_Info,
    name_bits:[1]core.Name_Bits_Info,
    selection:history.Selection,
    ctx:ui.Context,
    gui:editor.Editor_Ui,
    inspector:editor.Inspector,
    document:editor.Document,
    viewport:editor.Viewport,
    edits:history.Edits,
    session:editor.Session,
}

@(private="file")
collision_inspector_init :: proc(t:^testing.T,f:^Collision_Inspector) -> bool {
    f.info=core.test_info(t,Collision_Inspector_World,core.Test_None,Physics_Editor_Test_World,test_types) or_return
    f.names={
        {type=phys.Collision_Category,value=0,name="default"},{type=phys.Collision_Category,value=1,name="world"},
        {type=phys.Collision_Category,value=2,name="camera"},
        {type=phys.Collision_Preset,value=0,name="default"},{type=phys.Collision_Preset,value=1,name="trigger"},
        {type=phys.Collision_Preset,value=255,name="custom"},
    }
    f.named_types={{type=phys.Collision_Category,name="Collision_Category",prefix="CATEGORY_",limit=32},{type=phys.Collision_Preset,name="Collision_Preset",prefix="PRESET_",limit=256}}
    f.name_bits={{type=phys.Collision_Layers,of=phys.Collision_Category}}
    f.info.names,f.info.named_types,f.info.name_bits=f.names[:],f.named_types[:],f.name_bits[:]
    core.test_info_index(&f.info)
    if !core.world_init(&f.info,.World,&f.world,context.allocator) {return false}
    if !ui.context_init(&f.ctx,{}) {return false}
    f.gui={ctx=&f.ctx}
    f.session={info=&f.info,edit_world=&f.world,editor_world=&f.editor_world,gui=&f.gui,selection=&f.selection,inspector=&f.inspector,document=&f.document,viewport=&f.viewport,edits=&f.edits}
    return true
}

@(private="file")
collision_inspector_destroy :: proc(f:^Collision_Inspector) {
    ui.context_destroy(&f.ctx)
    history.edits_free(&f.edits)
    core.value_free(&f.inspector,type_info_of(editor.Inspector))
    delete(f.selection.entities)
    core.world_destroy(&f.info,.World,&f.world)
    core.test_info_destroy(&f.info)
}

// The inspector shows the preset of a Collider by name, its sensor, belongs
// and collides in gray from the preset until it is Custom, and then as
// checkboxes of the categories the code declares.
@(test)
the_inspector_shows_presets_and_masks_by_name :: proc(t:^testing.T) {
    f:Collision_Inspector
    if !testing.expect(t,collision_inspector_init(t,&f)) {return}
    defer collision_inspector_destroy(&f)
    world:=&f.world
    a,b:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.colliders,a,phys.COLLIDER_DEFAULT)
    core.add(&world.rows,b,{layers=phys.collision_layers(INSPECTOR_WORLD)})
    core.settle(&f.info,world,nil)
    session:=&f.session
    history.selection_set(&f.selection,{a})
    history.edits_reset(&f.edits,editor.edited_world(session))
    for _ in 0..<3 {collision_inspector_frame(t,session,{size={800,600},pointer_absent=true},phys.Collider)}
    _,preset:=ui.widget_rect(&f.ctx,ui.id(&f.ctx,"collider_preset",1))
    testing.expect(t,preset,"the preset is a list of names")
    bit:=ui.id_derive(&f.ctx,ui.id(&f.ctx,"collider_preset_layers"),"bit",1)
    box,boxes:=ui.widget_rect(&f.ctx,bit)
    testing.expect(t,boxes,"a preset shows what it gives, ready to change")
    before:=core.get(&world.colliders,a)^
    center:=[2]f32{box.x+box.w*0.5,box.y+box.h*0.5}
    collision_inspector_frame(t,session,{size={800,600},pointer=center,pressed={.Left},down={.Left}},phys.Collider)
    after:=core.get(&world.colliders,a)^
    testing.expect(t,after.preset==phys.PRESET_CUSTOM && after.belongs!=phys.collision_of_collider(collision_settings_of(editor.edited_world(session)),before).belongs,"changing what a preset gives makes the collider Custom with the change")
    for _ in 0..<3 {collision_inspector_frame(t,session,{size={800,600},pointer_absent=true},phys.Collider)}
    _,boxes=ui.widget_rect(&f.ctx,ui.id_derive(&f.ctx,ui.id(&f.ctx,"matrix",int(offset_of(phys.Collider,belongs))+1),"bit",1))
    testing.expect(t,boxes,"a custom collider edits its own categories")
    history.selection_set(&f.selection,{b})
    for _ in 0..<3 {collision_inspector_frame(t,session,{size={800,600},pointer_absent=true},Collision_Inspector_Row)}
    _,boxes=ui.widget_rect(&f.ctx,ui.id(&f.ctx,"named_bit",1))
    testing.expect(t,boxes)
}

@(test)
choosing_custom_keeps_what_the_preset_was_and_undoes_as_one_action :: proc(t:^testing.T) {
    f:Collision_Inspector
    if !testing.expect(t,collision_inspector_init(t,&f)) {return}
    defer collision_inspector_destroy(&f)
    world:=&f.world
    trigger,custom:=phys.COLLIDER_DEFAULT,phys.COLLIDER_DEFAULT
    trigger.preset=phys.PRESET_TRIGGER
    phys.collision_custom(&custom,phys.collision_layers(INSPECTOR_WORLD),phys.collision_layers(INSPECTOR_CAMERA))
    a,b:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.colliders,a,trigger)
    core.add(&world.colliders,b,custom)
    core.settle(&f.info,world,nil)
    history.selection_set(&f.selection,{b,a})
    session:=&f.session
    history.edits_reset(&f.edits,editor.edited_world(session))
    w:=editor.edited_world(session)
    table:=&f.info.tables[1]
    collision_preset_apply(session,table,core.world_table_at(w,table),f.selection.entities[:],phys.PRESET_CUSTOM,&world.settings)
    history.edits_flush(&f.edits,w,&f.selection)
    first,_:=core.get(core.read(&world.colliders),a)
    second,_:=core.get(core.read(&world.colliders),b)
    testing.expect(t,first.preset==phys.PRESET_CUSTOM && first.sensor && first.belongs==1 && first.collides==phys.COLLISION_LAYERS_ALL)
    testing.expect_value(t,second,custom)
    testing.expect_value(t,len(f.edits.steps),1)
    collision_preset_apply(session,table,core.world_table_at(w,table),f.selection.entities[:],phys.PRESET_DEFAULT,&world.settings)
    history.edits_flush(&f.edits,w,&f.selection)
    first,_=core.get(core.read(&world.colliders),a)
    testing.expect(t,first.preset==phys.PRESET_DEFAULT && phys.collision_filter(&world.settings,first)==phys.collision_filter(nil,phys.COLLIDER_DEFAULT))
    testing.expect(t,history.undo(&f.edits,w,&f.selection) && history.undo(&f.edits,w,&f.selection))
    first,_=core.get(core.read(&world.colliders),a);second,_=core.get(core.read(&world.colliders),b)
    testing.expect(t,first==trigger && second==custom)
}

// The settings show the declared categories and each declared preset with
// what the settings say of it, take only valid changes, write the defaults as
// no entry and remove an entry for a value the code does not declare.
@(test)
collision_settings_show_declared_values_and_remove_undeclared_entries :: proc(t:^testing.T) {
    f:Collision_Inspector
    if !testing.expect(t,collision_inspector_init(t,&f)) {return}
    defer collision_inspector_destroy(&f)
    world:=&f.world
    world.settings.presets[7]={preset=phys.Collision_Preset(9),belongs=1}
    defaults:=phys.COLLISION_SETTINGS_DEFAULT
    c:=editor.Inspect{s=&f.session,w=editor.edited_world(&f.session),storage=1,index=editor.SETTING_INDEX,type=phys.Collision_Settings,value=cast([^]u8)&world.settings,defaults=cast([^]u8)&defaults,size=size_of(phys.Collision_Settings)}
    frame :: proc(t:^testing.T,f:^Collision_Inspector,c:^editor.Inspect,input:ui.Input) {
        ui.frame_begin(&f.ctx,input)
        if ui.box(&f.ctx,{width=ui.fixed(440),height=ui.FIT,direction=.Column}) {editor.fields_rows(c,type_info_of(phys.Collision_Settings),0,0,"")}
        output:=ui.frame_end(&f.ctx)
        testing.expect(t,!output.overflow && f.ctx.stats.layout_errors==0)
    }
    for _ in 0..<3 {frame(t,&f,&c,{size={800,2400},pointer_absent=true})}
    for id in ([5]ui.Id{ui.id(&f.ctx,"preset_sensor",1),ui.id(&f.ctx,"preset_sensor",2),ui.id(&f.ctx,"remove_preset",8),ui.id(&f.ctx,"declare_category",1),ui.id(&f.ctx,"declare_preset",1)}) {
        _,shown:=ui.widget_rect(&f.ctx,id)
        testing.expect(t,shown)
    }
    _,extra:=ui.widget_rect(&f.ctx,ui.id(&f.ctx,"preset_sensor",3))
    testing.expect(t,!extra,"one row per declared preset, and none for custom")
    next:=world.settings
    testing.expect_value(t,phys.collision_preset_setting_set(&next,{preset=phys.PRESET_DEFAULT,belongs=phys.collision_layers(INSPECTOR_WORLD),collides=phys.COLLISION_LAYERS_ALL}),phys.Collision_Error.None)
    collision_presets_write(&c,&next)
    testing.expect_value(t,phys.collision_preset_setting(&world.settings,phys.PRESET_DEFAULT).belongs,phys.collision_layers(INSPECTOR_WORLD))
    next=world.settings
    next.presets[3]={preset=phys.PRESET_CUSTOM,belongs=1}
    collision_presets_write(&c,&next)
    testing.expect(t,phys.collision_settings_valid(&world.settings),"an invalid change is not taken")
    next=world.settings
    phys.collision_preset_setting_set(&next,{preset=phys.PRESET_DEFAULT,belongs=1,collides=phys.COLLISION_LAYERS_ALL})
    collision_presets_write(&c,&next)
    for entry in world.settings.presets {testing.expect(t,entry=={} || entry.preset!=phys.PRESET_DEFAULT,"the defaults are no entry")}
    remove:=ui.id(&f.ctx,"remove_preset",8)
    rect,_:=ui.widget_rect(&f.ctx,remove)
    for phase in 0..<3 {
        input:=ui.Input{size={800,2400},pointer=ui.rect_center(rect)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame(t,&f,&c,input)
    }
    testing.expect_value(t,world.settings.presets[7],phys.Collision_Preset_Setting{})
}
