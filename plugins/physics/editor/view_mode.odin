package physics_editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

// The Collision modes of the viewport: the colliders of the world shown, all
// of them (collision) or those of one object category (collision.<name>),
// colored by what their bodies are, over the lit image and hidden behind the
// scene. Declared in each frame and drawn in its render phase; the lines are
// made again only when the physics changes.

COLLISION_VIEW_LINES :: 32768 // the most lines drawn; the rest are counted
COLLISION_VIEW_PREFIX :: "collision."

@(storage,free="collision_view_free")
Collision_View :: struct {
    vertices:[dynamic]erender.Debug_Vertex, // made the first time a mode is shown
    scratch:[dynamic]sim.Debug_Line,
    world:rawptr, // what the lines were made from
    synced,tick,teleports:u64,
    epoch:u32,
    layers:sim.Collision_Layers,
    count,dropped:int,
    ready:bool,
    shown:sim.Collision_Layers, // those the mode of this frame shows; none: no Collision mode
}

collision_view_free :: proc(c:^Collision_View) {
    delete(c.vertices);delete(c.scratch)
    c^={}
}

@(step="frame")
collision_view_modes :: proc(s:^editor.Session,view:^Collision_View) {
    w:=editor.shown_world(s)
    settings:^phys.Collision_Settings
    ready:=false
    if w.data!=nil {
        state:=core.world_storage_of(w,phys.Physics_State)
        settings,ready=core.world_storage_of(w,phys.Collision_Settings),state!=nil && state.ready
    }
    reason:=ready?"":"The world shown has no physics"
    editor.view_mode_declare(s,{name="collision",label="All layers",title="Collision",group="Advanced",submenu="Collision",icon=.Collider,reason=reason,record=collision_view_record})
    current:=editor.view_mode_current(s.viewport)
    layers:=~sim.Collision_Layers(0)
    shown:=strings.equal_fold(current,"collision")
    for entry in collision_categories(w.info) {
        label:=editor.readable(entry.name)
        mode:=fmt.tprintf("%s%s",COLLISION_VIEW_PREFIX,entry.name)
        editor.view_mode_declare(s,{name=mode,label=label,title=fmt.tprintf("Collision: %s",label),group="Advanced",submenu="Collision",icon=.Layers,reason=reason,record=collision_view_record})
        if strings.equal_fold(current,mode) {shown,layers=true,sim.Collision_Layers(1)<<uint(entry.value)}
    }
    view.shown=layers if shown && ready && s.mode!=.Play else 0
}

@(step="render",after="render_sync")
collision_view_lines :: proc(s:^editor.Session,view:^Collision_View,extras:^host.Frame_Extras) {
    if view.shown!=0 {collision_view_draw(view,editor.shown_world(s),view.shown,extras)}
}

// The lines go over the lit image: the pass of the mode draws nothing.
@(private)
collision_view_record :: proc(pass:^erender.Pass,user:rawptr) {}

@(private)
collision_view_draw :: proc(c:^Collision_View,w:core.World_Ref,layers:sim.Collision_Layers,extras:^host.Frame_Extras) {
    state:=core.world_storage_of(w,phys.Physics_State)
    if state==nil || !state.ready {return}
    if len(c.vertices)==0 {
        resize(&c.vertices,2*COLLISION_VIEW_LINES)
        resize(&c.scratch,COLLISION_VIEW_LINES)
    }
    lines:=erender.debug_lines_make(c.vertices[:])
    if !c.ready || c.world!=w.data || c.synced!=state.synced || c.epoch!=state.epoch || c.tick!=state.world.tick || c.teleports!=state.stats.teleports || c.layers!=layers {
        out:=sim.Debug_Draw{lines=c.scratch[:]}
        sim.world_debug_draw(&state.world,&out,{.Shapes},layers=layers)
        for line in out.lines[:out.line_count] {erender.debug_line(&lines,line.a,line.b,COLLISION_COLORS[line.kind])}
        c.world,c.synced,c.epoch,c.tick,c.teleports,c.layers=w.data,state.synced,state.epoch,state.world.tick,state.stats.teleports,layers
        c.count,c.dropped,c.ready=lines.count,lines.dropped+out.lines_dropped,true
    }
    lines.count,lines.dropped=c.count,c.dropped
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
}

// The colliders of a world over the image capture takes with debug collision,
// colored as the modes color them.
@(storage)
Collision_Capture :: struct {provider:editor.Capture_Overlay_Provider}

COLLISION_CAPTURE_DEFAULT :: Collision_Capture{provider={name="collision",draw=collision_capture_draw}}

@(private)
collision_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    state:=core.world_storage_of(w,phys.Physics_State)
    if state==nil || !state.ready {return}
    scratch,error:=make([]sim.Debug_Line,COLLISION_VIEW_LINES,context.temp_allocator)
    if error!=nil {return}
    out:=sim.Debug_Draw{lines=scratch}
    sim.world_debug_draw(&state.world,&out,{.Shapes})
    for line in out.lines[:out.line_count] {erender.debug_line(lines,line.a,line.b,COLLISION_COLORS[line.kind])}
}

// The points where bodies touch after the last step over the image capture
// takes with debug contacts: a cross at each, with a line along the normal
// of its manifold, from shape A toward shape B.
@(storage)
Contacts_Capture :: struct {provider:editor.Capture_Overlay_Provider}

CONTACTS_CAPTURE_DEFAULT :: Contacts_Capture{provider={name="contacts",draw=contacts_capture_draw}}

CONTACTS_CAPTURE_POINTS :: 4096          // the most points drawn; the rest are left out
CONTACTS_CAPTURE_COLOR :: [4]f32{1,0.25,0.25,1}
CONTACTS_CAPTURE_CROSS :: f32(0.04)      // m, half the cross at a point
CONTACTS_CAPTURE_NORMAL :: f32(0.25)     // m, of the line along the normal

@(private)
contacts_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    state:=core.world_storage_of(w,phys.Physics_State)
    if state==nil || !state.ready {return}
    points,error:=make([]sim.Debug_Point,CONTACTS_CAPTURE_POINTS,context.temp_allocator)
    if error!=nil {return}
    out:=sim.Debug_Draw{points=points}
    sim.world_debug_draw(&state.world,&out,{.Contacts})
    for point in out.points[:out.point_count] {
        for axis in 0..<3 {
            step:[3]f32
            step[axis]=CONTACTS_CAPTURE_CROSS
            erender.debug_line(lines,point.position-step,point.position+step,CONTACTS_CAPTURE_COLOR)
        }
        erender.debug_line(lines,point.position,point.position+point.normal*CONTACTS_CAPTURE_NORMAL,CONTACTS_CAPTURE_COLOR)
    }
}

// The joints over the image capture takes with debug joints: a line from the
// center of each body to its anchor and between the two anchors.
@(storage)
Joints_Capture :: struct {provider:editor.Capture_Overlay_Provider}

JOINTS_CAPTURE_DEFAULT :: Joints_Capture{provider={name="joints",draw=joints_capture_draw}}

@(private)
joints_capture_draw :: proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines) {
    state:=core.world_storage_of(w,phys.Physics_State)
    if state==nil || !state.ready {return}
    scratch,error:=make([]sim.Debug_Line,COLLISION_VIEW_LINES,context.temp_allocator)
    if error!=nil {return}
    out:=sim.Debug_Draw{lines=scratch}
    sim.world_debug_draw(&state.world,&out,{.Joints})
    for line in out.lines[:out.line_count] {erender.debug_line(lines,line.a,line.b,COLLISION_COLORS[line.kind])}
}

// By what the body of a shape is: what does not move in blue, what moves in
// green (dimmer asleep), what only overlaps in orange.
@(private,rodata)
COLLISION_COLORS:=[sim.Debug_Kind][4]f32{
    .Static={0.45,0.65,1,0.9},.Kinematic={1,0.85,0.3,0.9},.Dynamic={0.35,1,0.55,0.95},.Sleeping={0.3,0.6,0.4,0.9},
    .Trigger={1,0.55,0.2,0.9},.Character={0.4,0.95,1,0.95},.Debris={0.75,0.6,0.45,0.9},
    .Bounds={0.6,0.6,0.6,0.6},.Joint={1,0.4,0.8,0.9},.Center={1,1,1,0.9},
    .Fluid={0.3,0.7,1,0.8},.Dry={1,0.9,0.55,0.8},
}
