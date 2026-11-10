package physics_placement

import "core:math"
import "mirai:core"
import "mirai:editor"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:ui"

PLACEMENT_TOOL :: "physics_placement"
PLACEMENT_SCOPE :: ui.Id(0x70687973)
PLACEMENT_CAPACITY :: 64
PLACEMENT_DT :: f32(1.0/60.0)
PLACEMENT_TICKS :: 1800

Placement_Desc :: struct {
    mesh:erender.Mesh_Renderer,
    scale:[3]f32,
    point:[3]f32,
    height:f32,
}

@(storage,free="physics_placement_free")
Physics_Placement :: struct {
    ready:bool,
    mesh:erender.Mesh_Renderer,
    scale:f32,
    speed:f32,
    height:f32,
    press,held:bool,
    drop_time:f32,
    session:^editor.Session,
    app:^host.App,
    preview:core.World_Ref,
    roots:[PLACEMENT_CAPACITY]core.Entity,
    count:int,
    accumulator:f32,
    ticks:int,
    resting:bool,
    measured_mesh:erender.Mesh_Renderer,
    measured_revision:u64,
    bounds:mm.Aabb,
    measured:bool,
    lines:[50]gpu.Debug_Vertex,
}

physics_placement_free :: proc(tool:^Physics_Placement) {
    placement_dispose(tool)
    tool^={}
}

@(private)
placement_ready :: proc(tool:^Physics_Placement) {
    if tool.ready {return}
    tool.ready,tool.speed,tool.height,tool.scale=true,5,1,1
    tool.mesh.shape=.Cube
}

@(private)
placement_dispose :: proc(tool:^Physics_Placement) {
    if tool.preview.data!=nil {host.app_world_free(tool.app,tool.preview.data)}
    tool.preview,tool.session,tool.app={},nil,nil
    tool.count,tool.accumulator,tool.ticks,tool.resting=0,0,0,false
    tool.held,tool.drop_time=false,0
}

placement_active :: proc(tool:^Physics_Placement) -> bool {
    return tool.preview.data!=nil && tool.session!=nil && editor.tool_preview_active(tool.session,PLACEMENT_TOOL)
}

placement_cancel :: proc(tool:^Physics_Placement) {
    if placement_active(tool) {editor.tool_preview_end(tool.session,PLACEMENT_TOOL,false)}
    placement_dispose(tool)
}

placement_confirm :: proc(tool:^Physics_Placement) -> bool {
    if !placement_active(tool) {placement_dispose(tool);return false}
    changed:=editor.tool_preview_end(tool.session,PLACEMENT_TOOL,true)
    placement_dispose(tool)
    return changed
}

@(private)
placement_box :: proc(assets:^host.Assets,mesh:erender.Mesh_Renderer) -> (box:mm.Aabb,ok:bool) {
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,context.temp_allocator)
    if !host.assets_geometry(assets,mesh.mesh,mesh.shape,&buffer) || len(buffer.positions)==0 {return}
    box.min,box.max=geom.mesh_bounds(buffer.positions[:])
    return box,true
}

@(private)
placement_pose :: proc(desc:Placement_Desc,bounds:mm.Aabb) -> mm.Transform {
    low,high:=bounds.min*desc.scale,bounds.max*desc.scale
    position:=desc.point-[3]f32{(low.x+high.x)*0.5,low.y,(low.z+high.z)*0.5}
    position.y+=desc.height
    return {position,1,desc.scale}
}

@(private)
placement_prepare :: proc(tool:^Physics_Placement) -> bool {
    w:=tool.preview
    rigids:=core.world_table_of(w,phys.Rigid_Body)
    colliders:=core.world_table_of(w,phys.Collider)
    if rigids==nil || colliders==nil {return false}
    if states:=core.world_storage_of(w,phys.Physics_State);states!=nil {phys.state_destroy(states)}
    if requests:=core.world_storage_of(w,phys.Body_Requests);requests!=nil {core.queue_clear(&requests.queue)}
    // A character stays as the static capsule of its collider.
    if characters:=core.world_table_of(w,phys.Character);characters!=nil {
        for e in characters.entities {core.remove(characters,e)}
    }
    if joints:=core.world_table_of(w,phys.Joint);joints!=nil {
        for e in joints.entities {core.remove(joints,e)}
    }
    if states:=core.world_table_of(w,core.Motion);states!=nil {
        for e in states.entities {core.remove(states,e)}
    }
    for &rigid in core.writable(rigids) {rigid=phys.RIGID_BODY_STATIC}
    if destructibles:=core.world_table_of(w,destruct.Destructible);destructibles!=nil {
        // Intact, it is the mesh it shows, with the surface and collision of its collider.
        for e in destructibles.entities {
            if collider:=core.get(colliders,e);collider!=nil && collider.kind==.External {collider.kind=.Mesh}
            else if !core.has(colliders,e) && editor.entity_has(w,e,erender.Mesh_Renderer) {core.add(colliders,e,phys.collider_mesh())}
        }
    }
    core.world_settle(w)
    return phys.step_world(w,tool.app,0) && placement_clean(tool,w)
}

// The preview runs physics alone: a problem in it is a body or a shape that
// physics could not make.
@(private)
placement_clean :: proc(tool:^Physics_Placement,w:core.World_Ref) -> bool {
    problems:=host.app_world_storage(tool.app,w.data,core.Problems)
    return problems==nil || problems.count==0
}

@(private)
placement_valid :: proc(desc:Placement_Desc) -> bool {
    if !(desc.height>=0 && desc.height<=1000) {return false}
    for n in desc.point {if math.is_nan(n) || math.is_inf(n) {return false}}
    for n in desc.scale {if !(n>0 && n<=1000) {return false}}
    return true
}

placement_start :: proc(s:^editor.Session,tool:^Physics_Placement,desc:Placement_Desc) -> bool {
    if editor.playing(s) || s.app==nil || !placement_valid(desc) {return false}
    bounds,measured:=placement_box(s.app.assets,desc.mesh)
    if !measured {editor.notify(s,"Choose a static mesh for placement");return false}
    placement_cancel(tool)
    w:=editor.edited_world(s)
    editor.tool_set(s,PLACEMENT_TOOL,true)
    if !editor.tool_preview_begin(s,PLACEMENT_TOOL,"Physics placement") {return false}
    tool.session,tool.app=s,s.app
    success:=false
    defer if !success {
        editor.tool_preview_end(s,PLACEMENT_TOOL,false)
        placement_dispose(tool)
        editor.notify(s,"The physics placement preview could not be started")
    }
    core.world_settle(w)
    data:=host.app_world_create(s.app)
    if data==nil {return false}
    tool.preview=host.app_world_ref(s.app,data)
    if !core.world_copy(s.info,data,w.data) {return false}
    if !placement_prepare(tool) || !placement_drop(tool,desc,bounds) {return false}
    success=true
    return true
}

@(private)
placement_drop :: proc(tool:^Physics_Placement,desc:Placement_Desc,bounds:mm.Aabb) -> bool {
    if !placement_active(tool) || !placement_valid(desc) || tool.count>=PLACEMENT_CAPACITY {return false}
    s:=tool.session
    w:=editor.edited_world(s)
    _,mesh_info:=core.world_table(w,erender.Mesh_Renderer)
    if mesh_info==nil {return false}
    pose:=core.from_math(placement_pose(desc,bounds))
    e:=editor.entity_create(s,{preset=.Empty,name="Placed mesh",transform=pose})
    if e==core.NONE {return false}
    success:=false
    defer if !success {placement_cancel(tool)}
    mesh:=desc.mesh
    editor.component_add(s,e,mesh_info,&mesh)
    core.world_settle(w)
    // Only physics runs in the clone, so both entity allocators stay in step.
    clone:=tool.preview
    if core.create(core.world_entities(clone))!=e {return false}
    core.add(core.world_table_of(clone,core.Transform),e,pose)
    core.add(core.world_table_of(clone,erender.Mesh_Renderer),e,mesh)
    size:=(bounds.max-bounds.min)*0.5
    for axis in 0..<3 {size[axis]=max(size[axis],0.005)}
    collider:=phys.collider_box(size)
    collider.center=(bounds.min+bounds.max)*0.5
    core.add(core.world_table_of(clone,phys.Collider),e,collider)
    body:=phys.RIGID_BODY_DYNAMIC
    body.linear_damping,body.angular_damping=0.15,0.2
    core.add(core.world_table_of(clone,phys.Rigid_Body),e,body)
    // Made by a step that does not play, the body gets no Motion of physics: without it, its rest is never read.
    if motions:=core.world_table_of(clone,core.Motion);motions!=nil {core.add(motions,e,core.Motion{awake=true})}
    core.world_settle(clone)
    if !phys.step_world(clone,tool.app,0) || !placement_clean(tool,clone) {return false}
    tool.roots[tool.count]=e
    tool.count+=1
    tool.ticks,tool.resting=0,false
    success=true
    return true
}

@(private)
placement_due :: proc(tool:^Physics_Placement,dt:f32) -> int {
    if !tool.held || !(tool.speed>0) {tool.drop_time=0;return 0}
    if tool.press {tool.drop_time=0;return 1}
    tool.drop_time+=clamp(dt,0,PLACEMENT_DT*8)
    interval:=1/tool.speed
    count:=int((tool.drop_time+1e-6)/interval)
    tool.drop_time=max(f32(0),tool.drop_time-f32(count)*interval)
    return count
}

placement_update :: proc(tool:^Physics_Placement,dt:f32) -> bool {
    if !placement_active(tool) {placement_dispose(tool);return false}
    if !(dt>=0 && dt<=max(f32)) {return false}
    if tool.resting {return true}
    tool.accumulator+=min(dt,PLACEMENT_DT*8)
    for tool.accumulator>=PLACEMENT_DT {
        tool.accumulator-=PLACEMENT_DT
        if !phys.step_world(tool.preview,tool.app,PLACEMENT_DT) {placement_cancel(tool);return false}
        tool.ticks+=1
        resting:=true
        for e in tool.roots[:tool.count] {
            local:=editor.entity_local(tool.preview,e)
            if local!=editor.entity_local(editor.edited_world(tool.session),e) {
                if !editor.transform_set(tool.session,e,local) {placement_cancel(tool);return false}
            }
            motion,made:=core.get(core.read(core.world_table_of(tool.preview,core.Motion)),e)
            resting=resting && made && !motion.awake
        }
        if resting || tool.ticks>=PLACEMENT_TICKS {tool.resting=true;break}
    }
    return true
}

@(step="input",after="editor_begin")
physics_placement_pointer :: proc(s:^editor.Session,tool:^Physics_Placement,input:core.Input) {
    placement_ready(tool)
    _,_,tool.press=editor.tool_pointer(s,PLACEMENT_TOOL,input)
    tool.held=(tool.held || tool.press) && s.viewport.hovered && core.mouse_down(input,.Left)
}

@(step="frame",after="editor_tools")
physics_placement_frame :: proc(s:^editor.Session,tool:^Physics_Placement,world:core.World_Ref,frame:core.Frame_Time) {
    if tool.preview.data!=nil {
        if editor.playing(s) || !editor.tool_on(s,PLACEMENT_TOOL) || (s.gui.begun && ui.escape(s.gui.ctx)) {placement_cancel(tool);return}
        if !placement_update(tool,frame.dt) {return}
    }
    if editor.playing(s) || !editor.tool_on(s,PLACEMENT_TOOL) || !s.viewport.hovered || s.viewport.pick.active {return}
    hit:=editor.pick_point(s,world,s.viewport.pointer)
    if hit.entity==core.NONE || hit.indicator {tool.drop_time=0;return}
    revision:=s.app.assets!=nil?s.app.assets.revision:0
    if tool.measured_mesh!=tool.mesh || tool.measured_revision!=revision {
        tool.bounds,tool.measured=placement_box(s.app.assets,tool.mesh)
        tool.measured_mesh,tool.measured_revision=tool.mesh,revision
    }
    if !tool.measured {return}
    desc:=Placement_Desc{mesh=tool.mesh,scale={tool.scale,tool.scale,tool.scale},height=tool.height,point=hit.position}
    for _ in 0..<placement_due(tool,frame.dt) {
        if placement_active(tool) {
            if tool.count>=PLACEMENT_CAPACITY {
                tool.held=false
                editor.notify(s,"Confirm or cancel placement before dropping more meshes")
                break
            } else if !placement_drop(tool,desc,tool.bounds) {editor.notify(s,"The mesh could not be dropped");break}
        } else if placement_start(s,tool,desc) {tool.held=true}
    }
    placement_hover(s,tool,desc)
}

@(private)
placement_hover :: proc(s:^editor.Session,tool:^Physics_Placement,desc:Placement_Desc) {
    bounds:=tool.bounds
    lines:=gpu.debug_lines_make(tool.lines[:],false)
    color:=[4]f32{1,0.71,0.28,1}
    {
        pose:=placement_pose(desc,bounds)
        transform:=mm.transform_matrix(pose)
        if instance,ok:=erender.mesh_instance(s.app.assets,desc.mesh,transform,erender.TINT_DEFAULT,{});ok {
            instance.copy_owner,instance.copy_variant=0x70687973706c6163,1
            host.extras_instance_add(&s.app.extras,instance)
        }
        gpu.debug_box_transformed(&lines,transform,bounds.min,bounds.max,color)
    }
    size:=(bounds.max-bounds.min)*desc.scale*0.5
    low,high:=desc.point-[3]f32{size.x,0,size.z},desc.point+[3]f32{size.x,0,size.z}
    gpu.debug_box(&lines,low,high,color)
    gpu.debug_line(&lines,desc.point,desc.point+[3]f32{0,desc.height,0},color)
    host.extras_debug_lines_add(&s.app.extras,lines)
    host.assets_commit(s.app.assets)
}

@(step="ui",after="editor_panels")
physics_placement_panel :: proc(s:^editor.Session,tool:^Physics_Placement,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    placement_ready(tool)
    ctx:=g.ctx
    if core.key_pressed(input,.P) && ctx.edit.id==0 && ctx.input.modifiers=={} && g.modal==.None && ctx.popup.count==0 {editor.tool_set(s,PLACEMENT_TOOL,!editor.tool_on(s,PLACEMENT_TOOL))}
    active:=editor.tool_on(s,PLACEMENT_TOOL)
    if editor.tool_button(g,ui.id_derive(ctx,PLACEMENT_SCOPE,"tool"),.Import,"Placement","P",active) {editor.tool_set(s,PLACEMENT_TOOL,!active)}
    if !editor.tool_on(s,PLACEMENT_TOOL) || s.viewport.pick.active {return}
    id:=ui.id_derive(ctx,PLACEMENT_SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        ui.section(ctx,"Physics placement")
        if placement_active(tool) {
            ui.section(ctx,tool.ticks>=PLACEMENT_TICKS?"Preview paused":tool.resting?"Resting":"Simulating")
            if ui.button(ctx,ui.id(ctx,"confirm"),{label="Confirm",style=.Field,width=-1,center=true}).clicked {placement_confirm(tool)}
            if ui.button(ctx,ui.id(ctx,"cancel"),{label="Cancel",style=.Field,width=-1,center=true}).clicked {placement_cancel(tool)}
        }
        {
            editor.row_begin(ctx,"Mesh")
            _=editor.geometry_choice(s,ui.id(ctx,"mesh"),&tool.mesh)
            editor.row_end(ctx)
            speed,height,scale:=f64(tool.speed),f64(tool.height),f64(tool.scale)
            if ui.property(ctx,"Speed") {
                if ui.number_field(ctx,ui.id(ctx,"speed"),&speed,{min=0.1,max=60,has_min=true,has_max=true,speed=0.1,unit="/s"}).changed {tool.speed=f32(speed)}
            }
            if ui.property(ctx,"Drop height") {
                if ui.number_field(ctx,ui.id(ctx,"height"),&height,{min=0,max=1000,has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.height=f32(height)}
            }
            if ui.property(ctx,"Scale") {
                if ui.number_field(ctx,ui.id(ctx,"scale"),&scale,{min=0.001,max=1000,has_min=true,has_max=true,speed=0.05}).changed {tool.scale=f32(scale)}
            }
        }
    }
}
