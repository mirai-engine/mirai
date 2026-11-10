package cinematics_editor

import "core:fmt"
import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:std/base"
import erender "mirai:engine/render"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "mirai:ui"
import cine "plugins:cinematics/runtime"

// The Cinematics tool: a timeline of the scene played and scrubbed in Edit.
// The scene shows the timeline at the head through a preview of the editor
// that puts the targets where the tracks say; another change of the scene
// (undo, save, an edit by API, a selection from Hierarchy) ends it, and the
// scene shows the document until the head moves again. Keys, shots and
// markers are written as steps of the document.

TOOL :: "cinematics"
SCOPE :: ui.Id(0x63696e65)
LANES :: 24 // shots, tracks and markers the strip shows
NAMES :: 64 // entities the lists of the panel offer

@(storage)
Cinematic_Editor :: struct {
    timeline:core.Entity,
    head:f32, // ticks
    playing,loop:bool,
    speed:f32,
    previewing:bool, // the scene shows the timeline at the head
    shown:f32,       // the head the preview put the targets at; <0: the preview has to begin
    shot_view:bool,  // the viewport looks through the shot at the head
    viewing:bool,    // the view of the viewport is kept in kept
    kept:editor.Orbit,
    strip:editor.Timeline,
    gizmo:editor.Tool_Gizmo,
    pose:mm.Transform, // what the gizmo moves, in the world
    menu:Lane_Mark,
    target:core.Entity,
    property:cine.Cinematic_Property,
    camera:core.Entity,
    scroll:f32,
}
CINEMATIC_EDITOR_DEFAULT :: Cinematic_Editor{speed=1,shown=-1}

Lane_Kind :: enum u8 {Shots,Track,Markers}
Lane :: struct {kind:Lane_Kind,track:core.Entity}
Lane_Mark :: struct {lane,index:int,tick:f32}

// The preview puts the targets back the next frame, after a write of the tool.
preview_restart :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    if editor.tool_preview_active(s,TOOL) {editor.tool_preview_end(s,TOOL,false)}
    c.shown=-1
}

// Stops looking through the shot: the viewport goes back to its view.
view_restore :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    if c.viewing {s.viewport.orbit=c.kept}
    c.viewing=false
}

@(private)
duration_of :: proc(w:core.World_Ref,timeline:core.Entity) -> f32 {
    c,ok:=editor.entity_get(w,timeline,cine.Cinematic)
    return ok?f32(min(c.duration_ticks,cine.MAX_DURATION)):0
}

// The timeline the tool edits: the one it had, else the one of the selection, else the first of the scene.
@(private)
timeline_choose :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    if editor.entity_has(w,c.timeline,cine.Cinematic) {return}
    c.timeline,c.head,c.playing,c.shown=core.NONE,0,false,-1
    for e in s.selection.entities {
        if t:=timeline_of(w,e);t!=core.NONE {c.timeline=t;return}
    }
    if table:=core.world_table_of(w,cine.Cinematic);table!=nil && core.count(core.read(table))>0 {c.timeline=core.entity_at(core.read(table),0)}
}

@(private)
lanes_of :: proc(w:core.World_Ref,timeline:core.Entity) -> []Lane {
    lanes:=make([dynamic]Lane,0,LANES,context.temp_allocator)
    append(&lanes,Lane{kind=.Shots})
    if tracks:=core.world_table_of(w,cine.Cinematic_Track);tracks!=nil {
        for row in 0..<core.count(core.read(tracks)) {
            if len(lanes)>=LANES-1 {break}
            if core.at(core.read(tracks),row).timeline==timeline {append(&lanes,Lane{kind=.Track,track=core.entity_at(core.read(tracks),row)})}
        }
    }
    append(&lanes,Lane{kind=.Markers})
    return lanes[:]
}

// The entities of a part of a timeline, in the order of their table: the marks of a lane.
@(private)
parts_of :: proc(w:core.World_Ref,timeline:core.Entity,$T:typeid) -> (entities:[]core.Entity,values:[]T) {
    table:=core.world_table_of(w,T)
    if table==nil {return}
    e:=make([dynamic]core.Entity,context.temp_allocator)
    v:=make([dynamic]T,context.temp_allocator)
    for row in 0..<core.count(core.read(table)) {
        value:=core.at(core.read(table),row)
        if value.timeline==timeline {append(&e,core.entity_at(core.read(table),row));append(&v,value)}
    }
    return e[:],v[:]
}

// The target the gizmo moves: the one of the track chosen in the strip, when a track of it keys its pose.
@(private)
gizmo_target :: proc(c:^Cinematic_Editor,w:core.World_Ref,lanes:[]Lane) -> core.Entity {
    lane:=c.strip.mark[0]
    if c.strip.mark[1]<=0 || lane<0 || lane>=len(lanes) || lanes[lane].kind!=.Track {return core.NONE}
    track,ok:=editor.entity_get(w,lanes[lane].track,cine.Cinematic_Track)
    if !ok || track.property>.Scale || !editor.entity_has(w,track.target,core.Transform) {return core.NONE}
    return track.target
}

// Keys the pose of a target at the head into every track of the timeline that keys its place or scale.
@(private)
pose_key :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,target:core.Entity,pose:mm.Transform) {
    tick:=math.round(c.head)
    local,_:=mm.transform_relative(pose,editor.entity_parent_world(w,target))
    preview_restart(s,c)
    opened,ready:=editor.edit_open(s,"Key pose")
    if !ready {return}
    defer editor.edit_close(s,opened)
    entities,tracks:=parts_of(w,c.timeline,cine.Cinematic_Track)
    for &track,i in tracks {
        if track.target!=target {continue}
        value:mm.Vec4
        switch track.property {
        case .Position: value.xyz=pose.position
        case .Rotation: value=lib.quat_vec4(pose.rotation)
        case .Scale: value.xyz=local.scale
        case .Fov,.Near: continue
        }
        key:=lib.Keyframe{time=tick,value=value}
        for held in track.keys[:min(track.key_count,cine.CINEMATIC_KEYS)] {
            if held.time==tick {key.ease,key.interpolation=held.ease,held.interpolation}
        }
        if !key_put(&track,key) {editor.notify(s,"A track holds 16 keys");continue}
        component_write(s,w,entities[i],track)
    }
}

@(step="frame",after="editor_tools")
cinematics_frame :: proc(s:^editor.Session,c:^Cinematic_Editor,frame:core.Frame_Time) {
    if editor.playing(s) || !editor.tool_on(s,TOOL) {
        view_restore(s,c)
        c.previewing,c.playing,c.shown=false,false,-1
        return
    }
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    if c.timeline==core.NONE {view_restore(s,c);return}
    duration:=duration_of(w,c.timeline)
    if c.playing && c.previewing && duration>0 {
        c.head+=frame.dt*tick_rate(s)*max(c.speed,0)
        if c.head>=duration {
            if c.loop {c.head=math.mod(c.head,duration)} else {c.head,c.playing=duration,false}
        }
    }
    c.head=clamp(c.head,0,duration)
    if c.previewing && !editor.tool_preview_active(s,TOOL) {
        // Ended by another change of the scene: the scene shows the document.
        if c.shown>=0 || !editor.tool_preview_begin(s,TOOL,"Cinematic preview") {c.previewing,c.playing,c.shown=false,false,-1}
    }
    lanes:=lanes_of(w,c.timeline)
    if c.previewing {
        if c.shown!=c.head && !c.gizmo.drag.active {targets_place(s,w,c.timeline,c.head)}
        c.shown=c.head
        if target:=gizmo_target(c,w,lanes);target!=core.NONE {
            if !c.gizmo.drag.active {
                c.pose=editor.entity_world(w,target)
                tracks:=core.world_table_of(w,cine.Cinematic_Shot)
                if tracks!=nil && cine.cinematic_shot_camera(core.read(tracks),c.timeline,target) {
                    if sample,ok:=camera_at(w,c.timeline,target,c.head);ok {c.pose=sample.pose}
                }
            }
            #partial switch editor.tool_gizmo(s,&c.gizmo,&c.pose,s.viewport.tool) {
            case .Moved:
                if local,ok:=mm.transform_relative(c.pose,editor.entity_parent_world(w,target));ok {editor.transform_set(s,target,local)}
            case .Ended: pose_key(s,c,w,target,c.pose)
            case .Cancelled: c.shown=-1
            }
            editor.tool_gizmo_draw(s,&c.gizmo,c.pose,s.viewport.tool)
        }
    }
    if !c.shot_view || !c.previewing {view_restore(s,c);return}
    if _,sample,ok:=shot_view(w,c.timeline,c.head);ok {
        if !c.viewing {c.kept,c.viewing=s.viewport.orbit,true}
        if orbit,made:=editor.orbit_of_camera(sample.pose,{fov=sample.fov,near=sample.near},max(s.viewport.orbit.distance,1));made {s.viewport.orbit=orbit}
    }
}

@(step="ui",after="editor_panels")
cinematics_panel :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    ctx:=g.ctx;th:=&ctx.theme
    active:=editor.tool_on(s,TOOL)
    if editor.tool_button(g,ui.id_derive(ctx,SCOPE,"tool"),.Play,"Cinematics","",active) {
        editor.tool_set(s,TOOL,!active)
        if !active {c.previewing,c.shown=true,-1}
    }
    if !editor.tool_on(s,TOOL) || s.viewport.pick.active {return}
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    id:=ui.id_derive(ctx,SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        side_rows(s,c,w)
    }
    if c.timeline==core.NONE {return}
    lanes:=lanes_of(w,c.timeline)
    left,right:=th.margin,ctx.size.x-th.margin
    if r:=g.rects.left;r.w>0 {left=r.x+r.w+th.margin}
    if r:=g.rects.right;r.w>0 {right=r.x-th.margin}
    bottom:=th.margin
    if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
    strip:=ui.id_derive(ctx,SCOPE,"strip")
    if ui.panel(ctx,strip,{width=ui.fixed(max(right-left,320)),height=ui.FIT,padding={0,4,0,4},anchor=.Bottom_Left,pivot=.Bottom_Left,offset={left,-bottom}}) {
        ui.id_push(ctx,strip);defer ui.id_pop(ctx)
        strip_rows(s,c,w,lanes)
    }
}

// The settings of the timeline and what adds parts to it.
@(private)
side_rows :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    ctx:=s.gui.ctx
    ui.section(ctx,"Cinematic")
    timelines,_:=entity_names(w,cine.Cinematic,false)
    chosen:=-1
    for e,i in timelines.entities {if e==c.timeline {chosen=i}}
    if ui.property(ctx,"Timeline") {
        if ui.dropdown(ctx,ui.id(ctx,"timeline"),{list=timelines.names},&chosen,{width=-1,empty="None"}) && chosen>=0 {
            c.timeline,c.head,c.playing,c.strip=timelines.entities[chosen],0,false,{}
            preview_restart(s,c)
        }
    }
    if ui.button(ctx,ui.id(ctx,"new"),{label="New timeline",style=.Field,width=-1,center=true}).clicked {
        preview_restart(s,c)
        opened,ready:=editor.edit_open(s,"New cinematic")
        if ready {
            e,_:=part_add(s,w,{part=.Timeline,duration_ticks=u32(tick_rate(s)*5)})
            if e!=core.NONE {c.timeline,c.head,c.strip,c.previewing=e,0,{},true}
        }
        editor.edit_close(s,opened)
    }
    value,has:=editor.entity_get(w,c.timeline,cine.Cinematic)
    if !has {return}
    rate:=tick_rate(s)
    seconds:=f64(f32(value.duration_ticks)/rate)
    if ui.property(ctx,"Duration") {
        if ui.number_field(ctx,ui.id(ctx,"duration"),&seconds,{has_min=true,min=f64(1/rate),has_max=true,max=3600,speed=0.05,decimals=2,unit="s"}).changed {
            changed:=value
            changed.duration_ticks=u32(max(math.round(f32(seconds)*rate),1))
            preview_restart(s,c)
            component_write(s,w,c.timeline,changed)
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        looping,auto_play:=value.looping,value.auto_play
        changed_looping:=ui.toggle(ctx,ui.id(ctx,"looping"),"Looping",&looping)
        if ui.toggle(ctx,ui.id(ctx,"auto_play"),"Auto play",&auto_play) || changed_looping {
            changed:=value
            changed.looping,changed.auto_play=looping,auto_play
            preview_restart(s,c)
            component_write(s,w,c.timeline,changed)
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        if ui.toggle(ctx,ui.id(ctx,"preview"),"Preview",&c.previewing) {c.playing,c.shown=false,-1}
        ui.toggle(ctx,ui.id(ctx,"shot_view"),"Shot view",&c.shot_view)
    }

    ui.section(ctx,"Add")
    targets,_:=entity_names(w,core.Transform,true)
    choose(ctx,"Target",targets,&c.target)
    properties:=[len(cine.Cinematic_Property)]string{"Position","Rotation","Scale","Fov","Near"}
    property:=int(c.property)
    if ui.property(ctx,"Property") {
        if ui.dropdown(ctx,ui.id(ctx,"property"),{list=properties[:]},&property,{width=-1}) {c.property=cine.Cinematic_Property(property)}
    }
    if ui.button(ctx,ui.id(ctx,"track"),{label="Add track",style=.Field,width=-1,center=true,disabled=c.target==core.NONE}).clicked {
        add(s,c,w,{part=.Track,timeline=c.timeline,target=c.target,property=c.property,tick=u32(math.round(c.head))})
    }
    cameras,_:=entity_names(w,erender.Camera,true)
    choose(ctx,"Camera",cameras,&c.camera)
    if ui.button(ctx,ui.id(ctx,"shot"),{label="Add shot",style=.Field,width=-1,center=true,disabled=c.camera==core.NONE}).clicked {
        add(s,c,w,{part=.Shot,timeline=c.timeline,target=c.camera,tick=u32(math.round(c.head))})
    }
    if ui.button(ctx,ui.id(ctx,"marker"),{label="Add marker",style=.Field,width=-1,center=true}).clicked {
        add(s,c,w,{part=.Marker,timeline=c.timeline,tick=u32(math.round(c.head))})
    }

    choose :: proc(ctx:^ui.Context,label:string,names:Names,value:^core.Entity) {
        chosen:=-1
        for e,i in names.entities {if e==value^ {chosen=i}}
        if ui.property(ctx,label) {
            if ui.dropdown(ctx,ui.id(ctx,label),{list=names.names},&chosen,{width=-1,empty="None"}) && chosen>=0 {value^=names.entities[chosen]}
        }
    }
}

@(private)
add :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,desc:Part_Desc) {
    preview_restart(s,c)
    opened,ready:=editor.edit_open(s,fmt.tprintf("Add %v",desc.part))
    if !ready {return}
    defer editor.edit_close(s,opened)
    if _,problem:=part_add(s,w,desc);problem!="" {editor.notify(s,fmt.tprintf("The %v could not be added: %s",desc.part,problem))}
}

Names :: struct {entities:[]core.Entity,names:[]string}

// The entities with a component, by name, for a list of the panel.
@(private)
entity_names :: proc(w:core.World_Ref,$T:typeid,numbered:bool) -> (names:Names,complete:bool) {
    table:=core.world_table_of(w,T)
    if table==nil {return {},true}
    count:=min(core.count(core.read(table)),NAMES)
    names.entities=make([]core.Entity,count,context.temp_allocator)
    names.names=make([]string,count,context.temp_allocator)
    for row in 0..<count {
        e:=core.entity_at(core.read(table),row)
        names.entities[row]=e
        names.names[row]=numbered?fmt.tprintf("%s (%d)",editor.entity_label(w,e),row+1):editor.entity_label(w,e)
    }
    return names,count==core.count(core.read(table))
}

// The time strip of the timeline: its shots, a lane per track with its keys and its markers.
@(private)
strip_rows :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,lanes:[]Lane) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    duration:=duration_of(w,c.timeline)
    shots,shot_values:=parts_of(w,c.timeline,cine.Cinematic_Shot)
    markers,marker_values:=parts_of(w,c.timeline,cine.Cinematic_Marker)
    strip_lanes:=make([]editor.Timeline_Lane,len(lanes),context.temp_allocator)
    for lane,i in lanes {
        switch lane.kind {
        case .Shots:
            marks:=make([]editor.Timeline_Mark,len(shot_values),context.temp_allocator)
            for shot,j in shot_values {marks[j]={frame=f32(shot.tick),name=editor.entity_label(w,shot.camera)}}
            strip_lanes[i]={name="Shots",marks=marks,add=c.camera!=core.NONE}
        case .Track:
            track,_:=editor.entity_get(w,lane.track,cine.Cinematic_Track)
            count:=int(min(track.key_count,cine.CINEMATIC_KEYS))
            marks:=make([]editor.Timeline_Mark,count,context.temp_allocator)
            for key,j in track.keys[:count] {marks[j]={frame=key.time}}
            strip_lanes[i]={name=fmt.tprintf("%v %s",track.property,editor.entity_label(w,track.target)),marks=marks,add=true}
        case .Markers:
            marks:=make([]editor.Timeline_Mark,len(marker_values),context.temp_allocator)
            for marker,j in marker_values {marks[j]={frame=f32(marker.tick)}}
            strip_lanes[i]={name="Markers",marks=marks,add=true}
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),padding={12,0,12,0},gap=8,align_y=.Center}) {
        ui.label(ctx,editor.entity_label(w,c.timeline),th.font_small,th.text,font=ui.FONT_SEMIBOLD)
        if current,_,ok:=shot_view(w,c.timeline,c.head);ok {ui.label(ctx,editor.entity_label(w,current.camera),th.font_small,th.text_muted)}
    }
    clock:=editor.Timeline_Clock{frame=c.head,frames=duration,rate=tick_rate(s),playing=c.playing,loop=c.loop,speed=c.speed,ask=editor.timeline_can_ask(s)}
    r:=editor.timeline_strip(s,&c.strip,clock,strip_lanes,ui.id(ctx,"timeline"))
    if (r.ask || r.copy) && c.strip.range {
        lo,hi:=editor.timeline_range(&c.strip,duration)
        range:=editor.Ai_Range{kind=.Cinematic,from=u64(lo),to=u64(hi)}
        if s.document!=nil {base.text_set(range.path[:],editor.document_path(s.document))}
        base.text_set(range.name[:],editor.entity_label(w,c.timeline))
        editor.timeline_range_use(s,r,range)
    }
    if r.seek {c.head,c.playing,c.previewing=r.frame,false,true}
    if r.loop {c.loop=!c.loop}
    if r.speed>0 {c.speed=r.speed}
    if r.play {
        c.playing,c.previewing=!c.playing,true
        if c.playing && c.head>=duration {c.head=0}
    }
    switch {
    case r.moved: mark_move(s,c,w,lanes[r.lane],r.index,r.to,shots,markers)
    case r.add: mark_add(s,c,w,lanes[r.lane],r.to)
    case r.menu:
        c.menu={r.lane,r.index,r.to}
        ui.popup_open(ctx,ui.id(ctx,"menu"),r.anchor)
    }
    if ui.popup(ctx,ui.id(ctx,"menu"),{min_width=ui.MENU_CHOICE_WIDTH}) {
        m:=c.menu
        if m.lane>=0 && m.lane<len(lanes) {
            lane:=lanes[m.lane]
            if m.index<0 {
                if ui.menu_item(ctx,ui.id(ctx,"menu_add"),lane.kind==.Track?"Add key":lane.kind==.Shots?"Add shot":"Add marker",{icon=.Plus}) {mark_add(s,c,w,lane,m.tick)}
            } else if ui.menu_item(ctx,ui.id(ctx,"menu_delete"),lane.kind==.Track?"Delete key":lane.kind==.Shots?"Delete shot":"Delete marker",{icon=.Cross}) {
                mark_delete(s,c,w,lane,m.index,shots,markers)
            }
        }
    }
}

// A mark dropped at another tick: a key, a shot or a marker moves there.
@(private)
mark_move :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,lane:Lane,index:int,to:f32,shots,markers:[]core.Entity) {
    preview_restart(s,c)
    switch lane.kind {
    case .Shots:
        if index>=len(shots) {return}
        shot,_:=editor.entity_get(w,shots[index],cine.Cinematic_Shot)
        shot.tick=u32(to)
        component_write(s,w,shots[index],shot)
    case .Track:
        track,ok:=editor.entity_get(w,lane.track,cine.Cinematic_Track)
        if !ok || index>=int(min(track.key_count,cine.CINEMATIC_KEYS)) {return}
        if key_move(&track,track.keys[index].time,to) {component_write(s,w,lane.track,track)}
    case .Markers:
        if index>=len(markers) {return}
        marker,_:=editor.entity_get(w,markers[index],cine.Cinematic_Marker)
        marker.tick=u32(to)
        component_write(s,w,markers[index],marker)
    }
}

// A mark at a tick: a key of the target as it is now, a shot of the camera of the panel, a marker.
@(private)
mark_add :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,lane:Lane,at:f32) {
    switch lane.kind {
    case .Shots: add(s,c,w,{part=.Shot,timeline=c.timeline,target=c.camera,tick=u32(at)})
    case .Markers: add(s,c,w,{part=.Marker,timeline=c.timeline,tick=u32(at)})
    case .Track:
        track,ok:=editor.entity_get(w,lane.track,cine.Cinematic_Track)
        if !ok {return}
        value,captured:=track_capture(w,track)
        if !captured {editor.notify(s,"The target of the track has nothing to key");return}
        preview_restart(s,c)
        if !key_put(&track,{time=at,value=value}) {editor.notify(s,"A track holds 16 keys");return}
        component_write(s,w,lane.track,track)
    }
}

@(private)
mark_delete :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref,lane:Lane,index:int,shots,markers:[]core.Entity) {
    preview_restart(s,c)
    switch lane.kind {
    case .Shots: if index<len(shots) {editor.entities_delete(s,shots[index:][:1])}
    case .Markers: if index<len(markers) {editor.entities_delete(s,markers[index:][:1])}
    case .Track:
        track,ok:=editor.entity_get(w,lane.track,cine.Cinematic_Track)
        if !ok || index>=int(min(track.key_count,cine.CINEMATIC_KEYS)) {return}
        if key_put(&track,track.keys[index],true) {component_write(s,w,lane.track,track)}
    }
}
