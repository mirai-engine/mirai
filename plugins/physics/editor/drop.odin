package physics_editor

import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/geom"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import "mirai:ui"
import "mirai:editor/kit"

// The Drop tool: the left button held on the scene drops the chosen mesh under the pointer and
// keeps dropping at its speed; what falls is the Simulate limited to the dropped meshes, a few
// ticks a frame, shown in the document inside a cancelable preview until Confirm or Cancel.

DROP_TOOL :: "drop"
DROP_SCOPE :: ui.Id(0x64726f70)
DROP_TICKS_PER_FRAME :: 8

@(storage,free="drop_free")
Drop_Tool :: struct {
    ready:bool,
    mesh:erender.Mesh_Renderer,
    scale,speed,height:f32,
    press,held:bool,
    drop_time:f32,
    app:^host.App,
    copy:rawptr, // of the document, where only the dropped meshes move; nil without a drop open
    moving:[SETTLE_CAPACITY]core.Entity,
    count:int,
    accumulator:f32,
    ticks:int, // since the last drop
    resting:bool,
    measured_mesh:erender.Mesh_Renderer,
    measured_revision:u64,
    bounds:mm.Aabb,
    measured:bool,
    lines:[32]erender.Debug_Vertex,
}

Drop_End :: enum u8 {Confirm,Cancel}

Drop_Params :: struct {
    end:Drop_End `mirai:"label=Confirm keeps the dropped meshes where they are as one step of undo; Cancel takes them away"`,
}

drop_free :: proc(tool:^Drop_Tool) {
    if tool.copy!=nil {host.app_world_free(tool.app,tool.copy)}
    tool^={}
}

@(private)
api_drop_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,DROP_TOOL,"Drop",.Import,{key=.P,set=true})
    editor.command_bind(s,{name="drop_confirm",view=proc(s:^editor.Session) {drop_finish(s,true)},label="Confirm",state=drop_state,scene=true})
    editor.command_bind(s,{name="drop_cancel",view=proc(s:^editor.Session) {drop_finish(s,false)},label="Cancel",state=drop_state,scene=true})
}

@(private)
drop_tool_of :: proc(s:^editor.Session) -> ^Drop_Tool {
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Drop_Tool)
}

@(private)
drop_state :: proc(s:^editor.Session,b:^editor.Binding) -> editor.Command_State {
    tool:=drop_tool_of(s)
    return {disabled=tool==nil || !drop_open(s,tool)}
}

// Confirm and Cancel of the panel: of the person who holds a drop open.
@(private)
drop_finish :: proc(s:^editor.Session,keep:bool) {
    if tool:=drop_tool_of(s);tool!=nil && drop_open(s,tool) && !drop_end(s,tool,keep) {
        editor.notify(s,"The dropped meshes could not be kept as a step of undo")
    }
}

drop_open :: proc(s:^editor.Session,tool:^Drop_Tool) -> bool {
    return tool.copy!=nil && editor.tool_preview_active(s,DROP_TOOL)
}

// Ends the drop: keep applies what the document shows as one step of undo, otherwise nothing of it
// stays. False when keeping failed, with nothing kept.
drop_end :: proc(s:^editor.Session,tool:^Drop_Tool,keep:bool) -> bool {
    kept:=editor.tool_preview_active(s,DROP_TOOL) && editor.tool_preview_end(s,DROP_TOOL,keep)
    if keep && !kept {editor.tool_preview_end(s,DROP_TOOL,false)}
    if tool.copy!=nil {host.app_world_free(tool.app,tool.copy)}
    tool.copy,tool.app,tool.count,tool.accumulator,tool.ticks,tool.resting=nil,nil,0,0,0,false
    tool.held,tool.drop_time=false,0
    return kept || !keep
}

// The pose that puts the bottom of the mesh height above point, centered on it.
@(private)
drop_pose :: proc(tool:^Drop_Tool,point:[3]f32) -> mm.Transform {
    scale:=[3]f32{tool.scale,tool.scale,tool.scale}
    low,high:=tool.bounds.min*scale,tool.bounds.max*scale
    position:=point-[3]f32{(low.x+high.x)*0.5,low.y,(low.z+high.z)*0.5}
    position.y+=tool.height
    return {position,1,scale}
}

// One mesh more, made in the document and moving in the copy; "" or what failed.
drop_one :: proc(s:^editor.Session,tool:^Drop_Tool,point:[3]f32) -> string {
    for n in point {if math.is_nan(n) || math.is_inf(n) {return "The point under the pointer is not finite"}}
    if tool.count>=len(tool.moving) {return "Confirm or cancel the drop before dropping more meshes"}
    first:=tool.copy==nil
    if first && !editor.tool_preview_begin(s,DROP_TOOL,"Drop meshes") {return "The drop could not start: an edit of the document is open"}
    w:=editor.edited_world(s)
    _,meshes:=core.world_table(w,erender.Mesh_Renderer)
    _,colliders:=core.world_table(w,phys.Collider)
    e:=editor.entity_create(s,{name="Dropped mesh",transform=core.from_math(drop_pose(tool,point))})
    if e==core.NONE || meshes==nil || colliders==nil {drop_end(s,tool,false);return "The mesh could not be made"}
    mesh,collider:=tool.mesh,phys.COLLIDER_DEFAULT
    collider.kind=.Hull
    editor.component_add(s,e,meshes,&mesh)
    editor.component_add(s,e,colliders,&collider)
    core.world_settle(w)
    tool.moving[tool.count]=e
    tool.count+=1
    problem:string
    if first {
        tool.app=s.app
        tool.copy,_,problem=editor.settle_begin(s,tool.moving[:tool.count])
    } else {_,problem=editor.settle_add(s,tool.copy,tool.moving[:tool.count])}
    if problem!="" {drop_end(s,tool,false);return problem}
    tool.ticks,tool.resting=0,false
    return ""
}

// Advances the copy by dt, at most a few ticks, and shows its poses in the document; false when
// physics stopped, which ends the drop.
drop_advance :: proc(s:^editor.Session,tool:^Drop_Tool,dt:f32) -> bool {
    tick:=s.app.tick_dt
    if tool.resting || !(tick>0) {return true}
    tool.accumulator=min(tool.accumulator+clamp(dt,0,tick*DROP_TICKS_PER_FRAME),tick*DROP_TICKS_PER_FRAME)
    rested:[SETTLE_CAPACITY]bool
    for tool.accumulator>=tick {
        tool.accumulator-=tick
        all,ok:=editor.settle_tick(s,tool.copy,tool.moving[:tool.count],rested[:tool.count])
        if !ok {drop_end(s,tool,false);return false}
        tool.ticks+=1
        if all || tool.ticks>=SETTLE_TICKS {tool.resting=true;break}
    }
    if !editor.settle_write(s,tool.copy,tool.moving[:tool.count]) {drop_end(s,tool,false);return false}
    return true
}

@(private)
drop_due :: proc(tool:^Drop_Tool,dt,tick:f32) -> int {
    if !tool.held || !(tool.speed>0) {tool.drop_time=0;return 0}
    if tool.press {tool.drop_time=0;return 1}
    tool.drop_time+=clamp(dt,0,tick*DROP_TICKS_PER_FRAME)
    interval:=1/tool.speed
    count:=int((tool.drop_time+1e-6)/interval)
    tool.drop_time=max(f32(0),tool.drop_time-f32(count)*interval)
    return count
}

@(private)
drop_ready :: proc(tool:^Drop_Tool) {
    if tool.ready {return}
    tool.ready,tool.speed,tool.height,tool.scale=true,5,1,1
    tool.mesh.shape=.Cube
}

@(step="input",after="editor_begin")
drop_pointer :: proc(s:^editor.Session,tool:^Drop_Tool,input:core.Input) {
    drop_ready(tool)
    _,_,tool.press=editor.tool_pointer(s,DROP_TOOL,input)
    // Held from a press on the scene until it is let go: while the button is down the viewport is not hovered.
    tool.held=(tool.held || tool.press) && core.mouse_down(input,.Left)
}

@(step="frame")
drop_frame :: proc(s:^editor.Session,tool:^Drop_Tool,world:core.World_Ref,frame:core.Frame_Time) {
    if tool.copy!=nil {
        if !drop_open(s,tool) || (s.gui.begun && ui.escape(s.gui.ctx)) {drop_end(s,tool,false)} else if !drop_advance(s,tool,frame.dt) {editor.notify(s,"Physics stopped while the meshes fell")}
    }
    if editor.playing(s) || !editor.tool_on(s,DROP_TOOL) || !(s.viewport.hovered || tool.held) || s.viewport.pick.active {return}
    hit:=editor.pick_point(s,world,s.viewport.pointer)
    if hit.entity==core.NONE || hit.indicator {tool.drop_time=0;return}
    if revision:=s.app.assets!=nil?s.app.assets.revision:0;tool.measured_mesh!=tool.mesh || tool.measured_revision!=revision {
        buffer:geom.Mesh_Buffer
        geom.mesh_buffer_init(&buffer,context.temp_allocator)
        tool.measured=host.assets_geometry(s.app.assets,tool.mesh.mesh,tool.mesh.shape,&buffer) && len(buffer.positions)>0
        if tool.measured {tool.bounds.min,tool.bounds.max=geom.mesh_bounds(buffer.positions[:])}
        tool.measured_mesh,tool.measured_revision=tool.mesh,revision
    }
    if !tool.measured {return}
    for _ in 0..<drop_due(tool,frame.dt,s.app.tick_dt) {
        if problem:=drop_one(s,tool,hit.position);problem!="" {
            tool.held=false
            editor.notify(s,problem)
            break
        }
    }
    // The mesh that would drop, its box and its line down to the point.
    pose:=mm.transform_matrix(drop_pose(tool,hit.position))
    if instance,ok:=erender.mesh_instance(s.app.assets,tool.mesh,pose);ok {
        instance.copy_owner,instance.copy_variant=0x64726f70,1
        host.extras_instance_add(&s.app.extras,instance)
    }
    lines:=erender.debug_lines_make(tool.lines[:],false)
    color:=[4]f32{1,0.71,0.28,1}
    erender.debug_box_transformed(&lines,pose,tool.bounds.min,tool.bounds.max,color)
    erender.debug_line(&lines,hit.position,hit.position+[3]f32{0,tool.height,0},color)
    host.extras_debug_lines_add(&s.app.extras,lines)
    host.assets_commit(s.app.assets)
}

@(step="ui",after="editor_panels")
drop_panel :: proc(s:^editor.Session,tool:^Drop_Tool,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) || !editor.tool_on(s,DROP_TOOL) || s.viewport.pick.active {return}
    drop_ready(tool)
    ctx:=g.ctx
    id:=ui.id_derive(ctx,DROP_SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        kit.section(ctx,"Drop")
        if drop_open(s,tool) {
            kit.section(ctx,tool.ticks>=SETTLE_TICKS?"Paused":tool.resting?"Resting":"Falling")
            editor.command_button(s,"drop_confirm",{label="Confirm",variant="field",width=-1,center=true})
            editor.command_button(s,"drop_cancel",{label="Cancel",variant="field",width=-1,center=true})
        }
        editor.row_begin(ctx,"Mesh")
        _=editor.geometry_choice(s,ui.id(ctx,"mesh"),&tool.mesh)
        editor.row_end(ctx)
        speed,height,scale:=f64(tool.speed),f64(tool.height),f64(tool.scale)
        if kit.property(ctx,"Speed") {
            if ui.number_field(ctx,ui.id(ctx,"speed"),&speed,{min=0.1,max=60,has_min=true,has_max=true,speed=0.1,unit="/s"}).changed {tool.speed=f32(speed)}
        }
        if kit.property(ctx,"Drop height") {
            if ui.number_field(ctx,ui.id(ctx,"height"),&height,{min=0,max=1000,has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.height=f32(height)}
        }
        if kit.property(ctx,"Scale") {
            if ui.number_field(ctx,ui.id(ctx,"scale"),&scale,{min=0.001,max=1000,has_min=true,has_max=true,speed=0.05}).changed {tool.scale=f32(scale)}
        }
    }
}
