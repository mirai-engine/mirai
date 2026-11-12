package foliage_editor

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:editor"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import foliage "plugins:foliage/runtime"

// The modes of the tool and the keys it shares with the terrain's: the
// number keys choose the mode, [ and ] and F the radius, Shift F the density
// of Paint or Erase, Ctrl turns Paint into Erase and Generate on into off.
//
// Paint and Erase fill the ring to the density of each selected type, times
// Paint density, or leave it at Erase density of it; Place puts one instance
// of the selected types, in turn, where it is clicked; Reapply gives the
// instances under the ring the scale, the turn and the offset of their type
// again, each once a stroke; Tint gives them the tint and the wetness of the
// panel, which the source keeps (white and dry: their own look again);
// Generate turns on the generator of the cells under the ring, whose rules
// then place the types; Select takes instances by a click or under the ring
// and the gizmo moves the group.

Foliage_Mode :: enum u8 {Paint,Erase,Select,Place,Reapply,Generate,Tint}
@(rodata) MODE_NAMES := [Foliage_Mode]string{.Paint="Paint",.Erase="Erase",.Select="Select",.Place="Place",.Reapply="Reapply",.Generate="Generate",.Tint="Tint"}
@(rodata) MODE_KEYS := [Foliage_Mode]core.Key{.Paint=.One,.Erase=.Two,.Select=.Three,.Place=.Four,.Reapply=.Five,.Generate=.Six,.Tint=.Seven}
@(rodata) STROKE_LABELS := [Foliage_Mode]string{.Paint="Paint foliage",.Erase="Erase foliage",.Select="",.Place="",.Reapply="Reapply foliage",.Generate="Generate foliage",.Tint="Tint foliage"}
TOOL_KEYS :: core.Keys{.F,.Left_Bracket,.Right_Bracket,.One,.Two,.Three,.Four,.Five,.Six,.Seven}
RADIUS_MIN :: f32(0.1)
RADIUS_MAX :: f32(500)
RADIUS_STEP :: f32(1.15) // what [ and ] multiply the radius by
STROKE_SPACING :: f32(0.5) // a drag touches at least every this part of the radius
STROKE_TOUCHES_MAX :: 16
CELL_IDLE :: ui.Color{232,232,238,140} // a cell near the ring that does not generate

// What the tool keeps between sessions, in the preferences of the editor.
Foliage_Preferences :: struct {
    radius:f32 `mirai:"min=0.1,max=500,unit=m"`,
    paint_density:f32 `mirai:"min=0.01,max=1"`, // of the density of each type
    erase_density:f32 `mirai:"min=0,max=1"`,    // of the density of each type Erase leaves
    ground_only:bool,   // Paint and Place stand instances only on the ground of the foliage (a terrain)
    reapply_scale:bool,
    reapply_turn:bool,
    reapply_offset:bool,
    tint:[3]f32 `mirai:"min=0,max=1"`, // what Tint multiplies the colors of the instances by
    wet:f32 `mirai:"min=0,max=1"`,     // how wet Tint leaves them, 0 dry to 1 soaked
}
FOLIAGE_PREFERENCES_DEFAULT :: Foliage_Preferences{radius=3,paint_density=1,reapply_scale=true,reapply_turn=true,reapply_offset=true,tint={1,1,1}}

@(storage)
Foliage_Tool_Preferences :: struct {provider:editor.Preferences_Provider}
foliage_tool_preferences_default :: proc() -> Foliage_Tool_Preferences {
    return {provider={name="Foliage_Tool",info=type_info_of(Foliage_Preferences),value=foliage_preferences,default=proc(dst:rawptr) {(^Foliage_Preferences)(dst)^=FOLIAGE_PREFERENCES_DEFAULT}}}
}

@(private)
foliage_preferences :: proc(s:^editor.Session) -> rawptr {
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Foliage_Tool)
    if tool==nil {return nil}
    tool_ready(tool)
    return &tool.prefs
}

// The mode a press works in: Ctrl turns Paint into Erase and the other way.
@(private)
mode_held :: proc "contextless" (tool:^Foliage_Tool,modifiers:ui.Modifiers) -> Foliage_Mode {
    if .Primary in modifiers {
        #partial switch tool.mode {
        case .Paint: return .Erase
        case .Erase: return .Paint
        }
    }
    return tool.mode
}

@(private)
mode_set :: proc(s:^editor.Session,tool:^Foliage_Tool,assets:^host.Assets,mode:Foliage_Mode) {
    if mode==tool.mode {return}
    if tool.stroke.active {edit_cancel(s,tool,assets);tool.stroke={}}
    tool.mode=mode
    selected_clear(tool)
}

// The keys of the tool while no field is edited and no menu is open.
@(private)
tool_keys_frame :: proc(s:^editor.Session,tool:^Foliage_Tool,assets:^host.Assets,input:core.Input) {
    ctx:=s.gui.ctx
    if ctx.edit.id!=0 || s.gui.modal!=.None || ctx.popup.count!=0 || ctx.input.modifiers!={} {return}
    if core.key_pressed(input,.Left_Bracket) {tool.radius=max(tool.radius/RADIUS_STEP,RADIUS_MIN)}
    if core.key_pressed(input,.Right_Bracket) {tool.radius=min(tool.radius*RADIUS_STEP,RADIUS_MAX)}
    for key,mode in MODE_KEYS {if core.key_pressed(input,key) {mode_set(s,tool,assets,mode)}}
}

// The density F with Shift drags in a mode.
@(private)
density_of :: proc(tool:^Foliage_Tool,mode:Foliage_Mode) -> ^f32 {return mode==.Erase?&tool.erase_density:&tool.paint_density}

// The ring of the brush on the ground of the foliage where it knows it, on
// the plane of the surface under the pointer elsewhere.
@(private)
ring_draw :: proc(s:^editor.Session,tool:^Foliage_Tool,owner:mm.Transform,ground:^foliage.Ground_Owner,center,normal:[3]f32,radius:f32,color:ui.Color,dashed:=false) {
    points:[RING_SEGMENTS][3]f32
    editor.brush_ring_points(center,normal,radius,points[:])
    if to_local,inverted:=mm.transform_inverse_matrix(owner);inverted {
        for &point in points {
            local:=mm.mat4_point(to_local,point)
            coord,in_cell:=foliage.cell_of(local)
            if h,_,ok:=foliage.ground_at(ground_of(ground,coord),in_cell.x,in_cell.z);ok {
                local.y=h
                point=mm.transform_point(owner,local)
            }
        }
    }
    editor.brush_ring_draw(s,points[:],color,3,dashed)
}

@(private)
mode_color :: proc "contextless" (mode:Foliage_Mode) -> ui.Color {
    #partial switch mode {
    case .Erase:            return editor.BRUSH_TAKE
    case .Reapply,.Select,.Tint: return editor.BRUSH_CHANGE
    }
    return editor.BRUSH_ADD
}

// The brush of Paint, Erase, Reapply and Generate: under the pointer, and
// while the button is held, a touch at most BRUSH_RATE times a second, the
// first when it is pressed; a fast drag also touches between two of them.
@(private)
brush_frame :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,e:core.Entity,owner:mm.Transform,ground:^foliage.Ground_Owner,requests:^foliage.Foliage_Ground_Requests,shown:^foliage.Foliage_Stroke,assets:^host.Assets,input:core.Input,frame:core.Frame_Time) {
    stroke:=&tool.stroke
    if tool.adjust.active {
        mode:=mode_held(tool,s.gui.ctx.input.modifiers)
        editor.brush_adjust_frame(s,&tool.adjust,input,&tool.radius,density_of(tool,mode),RADIUS_MIN,RADIUS_MAX)
        return
    }
    mode:=stroke.active?stroke.mode:mode_held(tool,s.gui.ctx.input.modifiers)
    if stroke.active {
        if ui.escape(s.gui.ctx) {edit_cancel(s,tool,assets);tool.stroke={};return}
        if !core.mouse_down(input,.Left) {
            if stroke.changed {edit_commit(s,tool,world,assets,STROKE_LABELS[stroke.mode])}
            tool.stroke={}
            clear(&tool.reapplied)
            return
        }
    }
    hit:=editor.pick_point(s,world,input.mouse_position)
    stroke.over=hit.entity!=core.NONE && !hit.indicator
    if !stroke.over {return}
    stroke.point,stroke.normal=hit.position,hit.normal
    // The ground of the cells under the ring, for what the brush places.
    to_local,inverted:=mm.transform_inverse_matrix(owner)
    if !inverted {return}
    center:=mm.mat4_point(to_local,hit.position)
    scale:=max(abs(owner.scale.x),1e-6)
    radius:=tool.radius/scale
    low,high:=cells_around(center,radius)
    for z in low.y..=high.y {for x in low.x..=high.x {
        if ground==nil || foliage.ground_tile_find(ground,{x,z})<0 {foliage.ground_request(requests,e,{x,z})}
    }}
    ring_draw(s,tool,owner,ground,hit.position,hit.normal,tool.radius,mode_color(mode),dashed=mode==.Generate && .Primary in s.gui.ctx.input.modifiers)
    if mode==.Generate {cells_draw(s,tool,owner,center,radius)}
    if !stroke.active {
        if editor.brush_adjust_key(s,&tool.adjust,input,hit.position,hit.normal,tool.radius,density_of(tool,mode)^) {return}
        if !tool.begin {return}
        stroke^={active=true,mode=mode,point=hit.position,normal=hit.normal,over=true,last=hit.position,generate=!(.Primary in s.gui.ctx.input.modifiers)}
        edit_baseline(tool)
    }
    stroke.waited+=frame.dt
    if stroke.touched && stroke.waited<1.0/BRUSH_RATE {return}
    first:=!stroke.touched
    stroke.touched,stroke.waited=true,0
    // Between the last touch and this one, on the surface under each point.
    from:=first?hit.position:stroke.last
    step:=hit.position-from
    count:=clamp(int(math.ceil(linalg.length(step)/(tool.radius*STROKE_SPACING))),1,STROKE_TOUCHES_MAX)
    up:=linalg.normalize0(hit.normal)
    changed:=false
    // The cells the touches may change: those within twice the radius, as a
    // ray down a slope places an instance off the ring's disc.
    near_low,near_high:=cells_around(center,2*radius)
    for i in 1..<count {
        point:=from+step*(f32(i)/f32(count))
        under:=editor.pick_ray(s,world,mm.Ray{point+up*tool.radius,-up},tool.radius*2)
        if under.entity==core.NONE {continue}
        changed|=brush_touch(s,tool,world,owner,to_local,ground,under.position,under.normal)
        a,b:=cells_around(mm.mat4_point(to_local,under.position),2*radius)
        near_low,near_high={min(near_low.x,a.x),min(near_low.y,a.y)},{max(near_high.x,b.x),max(near_high.y,b.y)}
    }
    changed|=brush_touch(s,tool,world,owner,to_local,ground,hit.position,hit.normal)
    stroke.last=hit.position
    if changed {
        stroke.changed=true
        edit_show(tool,shown,near_low,near_high)
    }
}

// One touch of the brush at a point of the world with its normal.
@(private)
brush_touch :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,owner:mm.Transform,to_local:mm.Mat4,ground:^foliage.Ground_Owner,point,normal:[3]f32) -> (changed:bool) {
    source:=&tool.edit.source
    stroke:=&tool.stroke
    scale:=max(abs(owner.scale.x),1e-6)
    center:=mm.mat4_point(to_local,point)
    radius:=tool.radius/scale
    if stroke.mode==.Generate {return generate_touch(source,center,radius,stroke.generate)}
    if len(tool.painted)==0 {
        if !stroke.warned {editor.notify(s,len(source.types)==0?"The foliage has no type to paint: add one with Add type":"Select the types the brush paints in the list of types");stroke.warned=true}
        return
    }
    tool.random+=1
    switch stroke.mode {
    case .Erase:
        random:=mm.rng_make(base.hash_u64(tool.random))
        return erase_touch(source,ground,tool.painted[:],center,radius,&tool.work,tool.erase_density,&random)
    case .Reapply:
        return reapply_touch(tool,source,ground,center,radius)
    case .Tint:
        return tint_touch(tool,source,ground,center,radius)
    case .Paint:
    case .Select,.Place,.Generate: return
    }
    clear(&tool.near)
    instances_near(source,ground,tool.painted[:],center,radius,&tool.work,&tool.near)
    n:=linalg.normalize0(normal)
    for id in tool.painted {
        t,_:=foliage.source_type(source,id)
        if t==nil {continue}
        tool.random+=1
        random:=mm.rng_make(base.hash_u64(tool.random),u64(id)+1)
        density:=t.density*tool.paint_density*scale*scale
        existing:=0
        for q in tool.near {if q.type==id {existing+=1}}
        count:=min(paint_count(density,radius,existing,&random),PAINT_MAX)
        for _ in 0..<count*2 {
            if count==0 {break}
            // Down on the surface from the disc of the brush, along its normal.
            candidate:=disc_point(point,normal,tool.radius,&random)
            hit:=editor.pick_ray(s,world,mm.Ray{candidate+n*tool.radius,-n},tool.radius*2)
            if hit.entity==core.NONE {continue}
            local:=mm.mat4_point(to_local,hit.position)
            if !spaced(local,tool.near[:],id,density) {continue}
            up:=linalg.normalize0(mm.quat_rotate(conj(owner.rotation),hit.normal))
            if !stands(tool,t,ground,local,up) {continue}
            paint_instance(source,t,local,up,&random,ground)
            append(&tool.near,Near{id,local})
            count-=1
            changed=true
        }
    }
    return
}

// Whether a type may stand at a point of the space of its foliage with the
// normal of the surface there: on the ground when the brush keeps to it, and
// where the rule of the type takes it.
@(private)
stands :: proc(tool:^Foliage_Tool,t:^foliage.Foliage_Type,ground:^foliage.Ground_Owner,local,up:[3]f32) -> bool {
    coord,in_cell:=foliage.cell_of(local)
    cell:=ground_of(ground,coord)
    h,_,known:=foliage.ground_at(cell,in_cell.x,in_cell.z)
    if tool.ground_only && (!known || abs(local.y-h)>GROUND_SNAP) {return false}
    if !t.rule.enabled {return true}
    mask:=foliage.layer_mask(t.rule,cell.layers)
    weight,weight_known:=foliage.ground_layer_weight(cell,&mask,in_cell.x,in_cell.z)
    return foliage.rule_allows(t^,known?h:local.y,up,weight,weight_known)
}

// The outlines of the cells near the ring, those that generate in green.
@(private)
cells_draw :: proc(s:^editor.Session,tool:^Foliage_Tool,owner:mm.Transform,center:[3]f32,radius:f32) {
    low,high:=cells_around(center,radius+foliage.CELL_SIZE)
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=foliage.source_cell(&tool.edit.source,{x,z})
        on:=cell!=nil && cell.generate
        cell_outline_draw(s,owner,{x,z},center.y,on?editor.BRUSH_GENERATED:CELL_IDLE)
    }}
}

@(private)
cell_outline_draw :: proc(s:^editor.Session,owner:mm.Transform,coord:[2]i32,height:f32,color:ui.Color) {
    corner:=foliage.cell_corner(coord)
    inset:=f32(0.2)
    size:=foliage.CELL_SIZE-inset*2
    points:=[4][3]f32{corner+{inset,height,inset},corner+{inset+size,height,inset},corner+{inset+size,height,inset+size},corner+{inset,height,inset+size}}
    for &point in points {point=mm.transform_point(owner,point)}
    editor.brush_ring_draw(s,points[:],color,1.5)
}

// Erase: of each selected type under the ring, those past erase_density of
// its density go, at random: manual ones from their cell, generated ones by
// an override Deleted.
erase_touch :: proc(s:^foliage.Source,ground:^foliage.Ground_Owner,types:[]u32,center:[3]f32,radius:f32,work:^foliage.Build_Work,keep:f32,random:^mm.Rng) -> (changed:bool) {
    Found :: struct {ref:Instance_Ref,type:u32,order:u32}
    found:=make([dynamic]Found,context.temp_allocator)
    low,high:=cells_around(center,radius)
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=foliage.source_cell(s,{x,z})
        if cell==nil {continue}
        if !foliage.cell_build(s,cell,ground_of(ground,cell.coord),work) {continue}
        for p in work.placed {if slice.contains(types,p.type) && in_brush(p.position,center,radius) {append(&found,Found{ref={cell.coord,p.id},type=p.type,order=mm.rng_u32(random)})}}
    }}
    if len(found)==0 {return}
    area:=math.PI*radius*radius
    gone:=make([dynamic]Instance_Ref,context.temp_allocator)
    for id in types {
        t,_:=foliage.source_type(s,id)
        if t==nil {continue}
        of:=make([dynamic]Found,context.temp_allocator)
        for f in found {if f.type==id {append(&of,f)}}
        keeps:=keep>0?int(math.round(keep*t.density*area)):0
        if len(of)<=keeps {continue}
        // Those that go are the ones a draw puts first.
        slice.sort_by(of[:],proc(a,b:Found) -> bool {return a.order<b.order})
        for f in of[:len(of)-keeps] {append(&gone,f.ref)}
    }
    return instances_delete(s,gone[:])
}

// Takes instances out.
instances_delete :: proc(s:^foliage.Source,refs:[]Instance_Ref) -> (changed:bool) {
    for ref in refs {changed|=instance_delete(s,ref)}
    return
}

// Reapply: the instances of the selected types under the ring take, once a
// stroke, the scale, the turn and the offset of their type again, as the
// boxes of the panel choose.
@(private)
reapply_touch :: proc(tool:^Foliage_Tool,s:^foliage.Source,ground:^foliage.Ground_Owner,center:[3]f32,radius:f32) -> (changed:bool) {
    for f in stroke_instances(tool,s,ground,center,radius) {
        t,_:=foliage.source_type(s,f.placed.type)
        if t==nil {continue}
        tool.random+=1
        random:=mm.rng_make(base.hash_u64(tool.random),u64(t.id)+1)
        p:=f.placed
        coord,in_cell:=foliage.cell_of(p.position)
        h,normal,known:=foliage.ground_at(ground_of(ground,coord),in_cell.x,in_cell.z)
        if tool.reapply_scale {
            across:=t.scale[0]+(t.scale[1]-t.scale[0])*mm.random_f32(&random)
            p.scale={across,across*(t.height[0]+(t.height[1]-t.height[0])*mm.random_f32(&random))}
        }
        if tool.reapply_turn {
            g:=foliage.Generated{type=t.id,yaw=mm.random_f32(&random)*t.yaw,tilt=mm.random_f32(&random)*t.tilt,tilt_turn=mm.random_f32(&random)*math.TAU}
            p.rotation=foliage.generated_rotation(g,t.align,known?normal:[3]f32{0,1,0})
        }
        if tool.reapply_offset && known {
            offset:=t.offset[0]+(t.offset[1]-t.offset[0])*mm.random_f32(&random)
            p.position.y=h+offset
        }
        if _,ok:=instance_set(s,ground,f.ref,p);ok {changed=true}
    }
    return
}

// Tint: the instances of the selected types under the ring take, once a
// stroke, the tint and the wetness of the panel; white and dry, their own
// look again.
@(private)
tint_touch :: proc(tool:^Foliage_Tool,s:^foliage.Source,ground:^foliage.Ground_Owner,center:[3]f32,radius:f32) -> (changed:bool) {
    color:=render.batch_color(tool.tint,tool.wet)
    for f in stroke_instances(tool,s,ground,center,radius) {
        p:=f.placed
        p.color,p.colored=color,color!=render.BATCH_COLOR_PLAIN
        if p.colored==f.placed.colored && p.color==f.placed.color {continue}
        if !p.colored {p.color=0}
        if _,ok:=instance_set(s,ground,f.ref,p);ok {changed=true}
    }
    return
}

// The instances of the selected types under the ring a stroke has not
// touched yet, which it touches now.
@(private)
Stroke_Found :: struct {ref:Instance_Ref,placed:foliage.Placed}
@(private)
stroke_instances :: proc(tool:^Foliage_Tool,s:^foliage.Source,ground:^foliage.Ground_Owner,center:[3]f32,radius:f32) -> []Stroke_Found {
    found:=make([dynamic]Stroke_Found,context.temp_allocator)
    low,high:=cells_around(center,radius)
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=foliage.source_cell(s,{x,z})
        if cell==nil {continue}
        if !foliage.cell_build(s,cell,ground_of(ground,cell.coord),&tool.work) {continue}
        for p in tool.work.placed {
            if !slice.contains(tool.painted[:],p.type) || !in_brush(p.position,center,radius) {continue}
            key:=base.hash_combine(base.hash_u64(u64(u32(cell.coord.x))|u64(u32(cell.coord.y))<<32),p.id)
            if slice.contains(tool.reapplied[:],key) {continue}
            append(&tool.reapplied,key)
            append(&found,Stroke_Found{{cell.coord,p.id},p})
        }
    }}
    return found[:]
}

// Place: one instance of the selected types, in turn, where the pointer is,
// as one step.
@(private)
place_frame :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,owner:mm.Transform,ground:^foliage.Ground_Owner,assets:^host.Assets,input:core.Input) {
    hit:=editor.pick_point(s,world,input.mouse_position)
    if hit.entity==core.NONE || hit.indicator {return}
    to_local,inverted:=mm.transform_inverse_matrix(owner)
    if !inverted {return}
    // A small ring: where it stands, not a reach.
    ring_draw(s,tool,owner,ground,hit.position,hit.normal,0.4,editor.BRUSH_ADD)
    if !tool.begin {return}
    source:=&tool.edit.source
    if len(tool.painted)==0 {editor.notify(s,len(source.types)==0?"The foliage has no type to place: add one with Add type":"Select the types to place in the list of types");return}
    tool.place_next=(tool.place_next+1)%len(tool.painted)
    t,_:=foliage.source_type(source,tool.painted[tool.place_next])
    if t==nil {return}
    local:=mm.mat4_point(to_local,hit.position)
    up:=linalg.normalize0(mm.quat_rotate(conj(owner.rotation),hit.normal))
    if tool.ground_only && !stands(tool,t,ground,local,up) {editor.notify(s,"The type does not stand there: off the ground of the foliage");return}
    edit_baseline(tool)
    tool.random+=1
    random:=mm.rng_make(base.hash_u64(tool.random),u64(t.id)+1)
    paint_instance(source,t,local,up,&random,ground)
    edit_commit(s,tool,world,assets,"Place foliage instance")
}

// The selected instances: those Select took, which the gizmo moves together
// about their middle.
Selected :: struct {
    entity:core.Entity,
    refs:[dynamic]Instance_Ref,
    types:[dynamic]u32,
    starts:[dynamic]mm.Transform, // in the world, when the gizmo began to drag
    pivot,pivot_start:mm.Transform, // what the gizmo holds
    active:bool, // refs has some
}

selected_clear :: proc(t:^Foliage_Tool) {
    sel:=&t.selected
    clear(&sel.refs);clear(&sel.types);clear(&sel.starts)
    sel.active,sel.entity=false,core.NONE
}

selected_free :: proc(sel:^Selected) {delete(sel.refs);delete(sel.types);delete(sel.starts);sel^={}}

@(private)
selected_find :: proc(sel:^Selected,ref:Instance_Ref) -> int {
    for held,i in sel.refs {if held==ref {return i}}
    return -1
}

@(private)
selected_add :: proc(t:^Foliage_Tool,e:core.Entity,ref:Instance_Ref,type:u32) {
    sel:=&t.selected
    if sel.entity!=e {selected_clear(t);sel.entity=e}
    if selected_find(sel,ref)>=0 {return}
    append(&sel.refs,ref);append(&sel.types,type)
    sel.active=true
}

@(private)
selected_remove :: proc(t:^Foliage_Tool,ref:Instance_Ref) {
    sel:=&t.selected
    if at:=selected_find(sel,ref);at>=0 {ordered_remove(&sel.refs,at);ordered_remove(&sel.types,at)}
    sel.active=len(sel.refs)>0
}

// Where the selected instances are, and the gizmo at their middle: the
// transform of the one alone.
@(private)
selected_pivot :: proc(t:^Foliage_Tool,owner:mm.Transform,ground:^foliage.Ground_Owner) -> bool {
    sel:=&t.selected
    source:=&t.edit.source
    clear(&sel.starts)
    middle:[3]f32
    for i:=len(sel.refs)-1;i>=0;i-=1 {
        placed,found:=instance_placed(source,ground,sel.refs[i],&t.work)
        if !found {ordered_remove(&sel.refs,i);ordered_remove(&sel.types,i);continue}
        sel.types[i]=placed.type
    }
    for ref in sel.refs {
        placed,_:=instance_placed(source,ground,ref,&t.work)
        world:=instance_world(placed,owner)
        append(&sel.starts,world)
        middle+=world.position
    }
    sel.active=len(sel.refs)>0
    if !sel.active {return false}
    if len(sel.refs)==1 {sel.pivot=sel.starts[0]} else {sel.pivot={position=middle/f32(len(sel.refs)),rotation=1,scale={1,1,1}}}
    return true
}

// Select: a click takes the instance under it alone, with Shift adds it and
// with Ctrl takes it out or adds it; a drag takes those of the selected types
// under the ring (with Ctrl, takes them out). The gizmo moves the selection
// about its middle, Delete takes it out and End stands it on the ground,
// each a step.
@(private)
select_frame :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,e:core.Entity,owner:mm.Transform,ground:^foliage.Ground_Owner,resident:^foliage.Foliage_Resident,assets:^host.Assets,input:core.Input,frame:core.Frame_Time) {
    sel:=&tool.selected
    source:=&tool.edit.source
    ctx:=s.gui.ctx
    if sel.active && sel.entity!=e {selected_clear(tool)}
    if sel.active && !tool.gizmo.drag.active && !tool.stroke.active {selected_pivot(tool,owner,ground)}
    if sel.active && !tool.stroke.active {
        before:=tool.gizmo.drag.active
        event:=editor.tool_gizmo(s,&tool.gizmo,&sel.pivot,s.viewport.tool)
        switch event {
        case .None:
        case .Began:
            edit_baseline(tool)
            sel.pivot_start=sel.pivot
        case .Moved:
            if selected_move(tool,owner,ground) {edit_preview(s,tool,assets)}
        case .Ended:
            if !edit_commit(s,tool,world,assets,len(sel.refs)==1?"Move foliage instance":"Move foliage instances") {selected_clear(tool)}
        case .Cancelled:
            edit_cancel(s,tool,assets)
            selected_clear(tool)
        }
        if sel.active {editor.tool_gizmo_draw(s,&tool.gizmo,sel.pivot,s.viewport.tool)}
        if before || event!=.None {return}
        // Escape lets go of the instances before the editor takes it for the selection.
        if ui.escape(ctx) {selected_clear(tool);return}
        if ctx.edit.id==0 {
            if core.key_pressed(input,.Delete) || core.key_pressed(input,.Backspace) {selected_delete(s,tool,world,assets);return}
            if core.key_pressed(input,.End) {selected_ground(s,tool,world,assets,ground,owner);return}
        }
    }
    stroke:=&tool.stroke
    if stroke.active {
        if !core.mouse_down(input,.Left) {tool.stroke={};return}
    }
    hit:=editor.pick_point(s,world,input.mouse_position,batches=true)
    if stroke.active {
        // A drag: those under the ring join or leave.
        if hit.entity==core.NONE {return}
        ring_draw(s,tool,owner,ground,hit.position,hit.normal,tool.radius,editor.BRUSH_CHANGE,dashed=stroke.mode==.Erase)
        if linalg.length(hit.position-stroke.point)<tool.radius*0.25 && !stroke.touched {return}
        stroke.touched=true
        to_local,inverted:=mm.transform_inverse_matrix(owner)
        if !inverted {return}
        center:=mm.mat4_point(to_local,hit.position)
        radius:=tool.radius/max(abs(owner.scale.x),1e-6)
        low,high:=cells_around(center,radius)
        for z in low.y..=high.y {for x in low.x..=high.x {
            cell:=foliage.source_cell(source,{x,z})
            if cell==nil {continue}
            if !foliage.cell_build(source,cell,ground_of(ground,cell.coord),&tool.work) {continue}
            for p in tool.work.placed {
                if !slice.contains(tool.painted[:],p.type) || !in_brush(p.position,center,radius) {continue}
                if stroke.mode==.Erase {selected_remove(tool,{cell.coord,p.id})} else {selected_add(tool,e,{cell.coord,p.id},p.type)}
            }
        }}
        return
    }
    if !tool.begin {return}
    toggle,extend:=.Primary in ctx.input.modifiers,.Shift in ctx.input.modifiers
    // Ctrl drags take out; a drag otherwise adds.
    tool.stroke={active=true,mode=toggle?.Erase:.Paint,point=hit.position,normal=hit.normal}
    if !toggle && !extend {selected_clear(tool)}
    if hit.batch==0 || hit.entity!=e {return}
    entity,coord,type,_,role,found:=foliage.resident_batch_find(resident,hit.batch)
    if !found || entity!=e {return}
    ref,placed,known:=instance_of_batch(source,ground,coord,type,hit.instance,&tool.work,role,owner.rotation)
    if !known {return}
    if toggle && selected_find(sel,ref)>=0 {selected_remove(tool,ref)} else {selected_add(tool,e,ref,placed.type)}
    type_reveal(tool,placed.type)
}

// The selection where the gizmo puts it: each instance as it was at the
// start of the drag, turned, scaled and moved with the pivot.
@(private)
selected_move :: proc(t:^Foliage_Tool,owner:mm.Transform,ground:^foliage.Ground_Owner) -> (changed:bool) {
    sel:=&t.selected
    if len(sel.starts)!=len(sel.refs) {return}
    from,to:=sel.pivot_start,sel.pivot
    turn:=to.rotation*conj(from.rotation)
    grow:=[3]f32{to.scale.x/max(from.scale.x,1e-6),to.scale.y/max(from.scale.y,1e-6),to.scale.z/max(from.scale.z,1e-6)}
    for i in 0..<len(sel.refs) {
        start:=sel.starts[i]
        // The offset from the pivot in the frame of the pivot, scaled, turned back out.
        offset:=mm.quat_rotate(conj(from.rotation),start.position-from.position)*grow
        moved:=mm.Transform{position=to.position+mm.quat_rotate(to.rotation,offset),rotation=linalg.normalize(turn*start.rotation),scale=start.scale*grow}
        if len(sel.refs)==1 {moved=to}
        ref:=sel.refs[i]
        next,ok:=instance_set(&t.edit.source,ground,ref,instance_local(moved,owner,sel.types[i]))
        if !ok {continue}
        changed=true
        sel.refs[i]=next
    }
    return
}

// Takes the selected instances out, as a step.
@(private)
selected_delete :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets) {
    if !tool.selected.active {return}
    edit_baseline(tool)
    many:=len(tool.selected.refs)>1
    if instances_delete(&tool.edit.source,tool.selected.refs[:]) {edit_commit(s,tool,world,assets,many?"Delete foliage instances":"Delete foliage instance")}
    selected_clear(tool)
}

// Stands the selected instances on the ground under them, as a step.
@(private)
selected_ground :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,ground:^foliage.Ground_Owner,owner:mm.Transform) {
    sel:=&tool.selected
    if !sel.active {return}
    edit_baseline(tool)
    changed:=false
    for &ref,i in sel.refs {
        placed,found:=instance_placed(&tool.edit.source,ground,ref,&tool.work)
        if !found {continue}
        coord,in_cell:=foliage.cell_of(placed.position)
        h,_,known:=foliage.ground_at(ground_of(ground,coord),in_cell.x,in_cell.z)
        if !known {continue}
        placed.position.y=h
        if next,ok:=instance_set(&tool.edit.source,ground,ref,placed);ok {ref=next;changed=true}
        _=i
    }
    if changed {edit_commit(s,tool,world,assets,"Stand foliage on the ground")} else {editor.notify(s,"The ground under the selected instances is not known")}
}

// Gives the selected instances another type, as a step.
@(private)
selected_retype :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,ground:^foliage.Ground_Owner,owner:mm.Transform,type:u32) {
    sel:=&tool.selected
    if !sel.active {return}
    edit_baseline(tool)
    changed:=false
    for &ref,i in sel.refs {
        placed,found:=instance_placed(&tool.edit.source,ground,ref,&tool.work)
        if !found {continue}
        placed.type=type
        if next,ok:=instance_set(&tool.edit.source,ground,ref,placed);ok {ref,sel.types[i]=next,type;changed=true}
    }
    if changed {
        type_reveal(tool,type)
        edit_commit(s,tool,world,assets,"Change foliage instances")
    }
}

// Every instance of the selected types, from the source the tool edits.
@(private)
selected_all :: proc(tool:^Foliage_Tool,e:core.Entity,ground:^foliage.Ground_Owner) {
    source:=&tool.edit.source
    selected_clear(tool)
    for &cell in source.cells {
        if !foliage.cell_build(source,&cell,ground_of(ground,cell.coord),&tool.work) {continue}
        for p in tool.work.placed {if slice.contains(tool.painted[:],p.type) {selected_add(tool,e,{cell.coord,p.id},p.type)}}
    }
}
