package cinematics_editor

import "core:fmt"
import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:std/base"
import erender "mirai:engine/render"
import "mirai:ui"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

// The Cinematics tool: a timeline of the scene played and scrubbed in Edit.
// The scene shows the timeline at the head because the tool seeks its clip
// there, as the preview of any Animation: the document does not change. The
// tool writes shots and actors as steps of the document; the keys and the
// markers of the clip are written with the animation methods.

TOOL :: "cinematics"
SCOPE :: ui.Id(0x63696e65)
NAMES :: 64 // entities the lists of the panel offer

@(storage)
Cinematic_Editor :: struct {
    timeline:core.Entity,
    head:f32, // ticks
    playing,loop:bool,
    speed:f32,
    active:bool,     // its tool was on in the last frame
    previewing:bool, // the scene shows the timeline at the head
    shown:f32,       // the head the clip was sought at; <0: it has to be sought
    shot_view:bool,  // the viewport looks through the shot at the head
    viewing:bool,    // the view of the viewport is kept in kept
    kept:editor.Orbit,
    strip:editor.Timeline,
    menu:Shot_Mark,
    target:core.Entity,
    camera:core.Entity,
}
CINEMATIC_EDITOR_DEFAULT :: Cinematic_Editor{speed=1,shown=-1}

Shot_Mark :: struct {index:int,tick:f32}

// Stops looking through the shot: the viewport goes back to its view.
view_restore :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    if c.viewing {s.viewport.orbit=c.kept}
    c.viewing=false
}

// Puts the clip of the timeline at a time in the scene, as the preview of its Animation does.
@(private)
clip_seek :: proc(w:core.World_Ref,timeline:core.Entity,seconds:f32) {
    if requests:=core.world_storage_of(w,anim.Animation_Requests);requests!=nil && timeline!=core.NONE {anim.animation_seek(requests,timeline,seconds)}
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

// The entities out of a timeline that its clip moves by name.
@(private)
actors_of :: proc(w:core.World_Ref,timeline:core.Entity) -> (entities:[]core.Entity,values:[]anim.Animation_Target) {
    table:=core.world_table_of(w,anim.Animation_Target)
    if table==nil {return}
    e:=make([dynamic]core.Entity,context.temp_allocator)
    v:=make([dynamic]anim.Animation_Target,context.temp_allocator)
    for row in 0..<core.count(core.read(table)) {
        value:=core.at(core.read(table),row)
        if value.animation==timeline {append(&e,core.entity_at(core.read(table),row));append(&v,value)}
    }
    return e[:],v[:]
}

@(step="frame")
cinematics_frame :: proc(s:^editor.Session,c:^Cinematic_Editor,frame:core.Frame_Time) {
    if editor.playing(s) || !editor.tool_on(s,TOOL) {
        view_restore(s,c)
        // The scene goes back to the start of the clip, as when the preview of an Animation ends.
        if c.shown>=0 && !editor.playing(s) {clip_seek(editor.edited_world(s),c.timeline,0)}
        c.previewing,c.playing,c.shown=false,false,-1
        return
    }
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    if c.timeline==core.NONE {view_restore(s,c);return}
    rate:=tick_rate(s)
    duration:=duration_of(w,c.timeline)*rate
    if c.playing && c.previewing && duration>0 {
        c.head+=frame.dt*rate*max(c.speed,0)
        if c.head>=duration {
            if c.loop {c.head=math.mod(c.head,duration)} else {c.head,c.playing=duration,false}
        }
    }
    c.head=clamp(c.head,0,duration)
    if c.previewing {
        if c.shown!=c.head {clip_seek(w,c.timeline,c.head/rate)}
        c.shown=c.head
    } else if c.shown>=0 {
        clip_seek(w,c.timeline,0)
        c.shown=-1
    }
    if !c.shot_view || !c.previewing {view_restore(s,c);return}
    if _,sample,ok:=shot_view(w,c.timeline,c.head/rate);ok {
        if !c.viewing {c.kept,c.viewing=s.viewport.orbit,true}
        if orbit,made:=editor.orbit_of_camera(sample.pose,{fov=sample.fov,near=sample.near},max(s.viewport.orbit.distance,1));made {s.viewport.orbit=orbit}
    }
}

@(step="ui",after="editor_panels")
cinematics_panel :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    ctx:=g.ctx;th:=&ctx.theme
    // Turned on, it previews and shows no timeline yet.
    active:=editor.tool_on(s,TOOL)
    if active && !c.active {c.previewing,c.shown=true,-1}
    c.active=active
    if !active || s.viewport.pick.active {return}
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    id:=ui.id_derive(ctx,SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        side_rows(s,c,w)
    }
    if c.timeline==core.NONE {return}
    left,right:=th.margin,ctx.size.x-th.margin
    if r:=g.rects.left;r.w>0 {left=r.x+r.w+th.margin}
    if r:=g.rects.right;r.w>0 {right=r.x-th.margin}
    bottom:=th.margin
    if r:=g.rects.bottom;r.h>0 {bottom+=ctx.size.y-r.y}
    strip:=ui.id_derive(ctx,SCOPE,"strip")
    if ui.panel(ctx,strip,{width=ui.fixed(max(right-left,320)),height=ui.FIT,padding={0,4,0,4},anchor=.Bottom_Left,pivot=.Bottom_Left,offset={left,-bottom}}) {
        ui.id_push(ctx,strip);defer ui.id_pop(ctx)
        strip_rows(s,c,w)
    }
}

// The timeline the tool shows and what adds shots and actors to it.
@(private)
side_rows :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    ctx:=s.gui.ctx
    ui.section(ctx,"Cinematic")
    timelines,_:=entity_names(w,cine.Cinematic,false)
    chosen:=-1
    for e,i in timelines.entities {if e==c.timeline {chosen=i}}
    if ui.property(ctx,"Timeline") {
        if ui.dropdown(ctx,ui.id(ctx,"timeline"),{list=timelines.names},&chosen,{width=-1,empty="None"}) && chosen>=0 {
            c.timeline,c.head,c.playing,c.strip,c.shown=timelines.entities[chosen],0,false,{},-1
        }
    }
    if ui.button(ctx,ui.id(ctx,"new"),{label="New timeline",style=.Field,width=-1,center=true}).clicked {
        opened,ready:=editor.edit_open(s,"New cinematic")
        if ready {
            e,_:=part_add(s,w,{part=.Timeline})
            if e!=core.NONE {c.timeline,c.head,c.strip,c.previewing,c.shown=e,0,{},true,-1}
        }
        editor.edit_close(s,opened)
    }
    if !editor.entity_has(w,c.timeline,cine.Cinematic) {return}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        if ui.toggle(ctx,ui.id(ctx,"preview"),"Preview",&c.previewing) {c.playing=false}
        ui.toggle(ctx,ui.id(ctx,"shot_view"),"Shot view",&c.shot_view)
    }

    ui.section(ctx,"Add")
    cameras,_:=entity_names(w,erender.Camera,true)
    choose(ctx,"Camera",cameras,&c.camera)
    if ui.button(ctx,ui.id(ctx,"shot"),{label="Add shot",style=.Field,width=-1,center=true,disabled=c.camera==core.NONE}).clicked {
        add(s,c,w,{part=.Shot,timeline=c.timeline,target=c.camera,time=math.round(c.head)/tick_rate(s)})
    }
    targets,_:=entity_names(w,core.Transform,true)
    choose(ctx,"Entity",targets,&c.target)
    if ui.button(ctx,ui.id(ctx,"actor"),{label="Add actor",style=.Field,width=-1,center=true,disabled=c.target==core.NONE || c.target==c.timeline}).clicked {
        add(s,c,w,{part=.Actor,timeline=c.timeline,target=c.target})
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
    opened,ready:=editor.edit_open(s,fmt.tprintf("Add %v",desc.part))
    if !ready {return}
    defer editor.edit_close(s,opened)
    if _,problem:=part_add(s,w,desc);problem!="" {editor.notify(s,fmt.tprintf("The %v could not be added: %s",desc.part,problem))}
    c.shown=-1
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

// The time strip of the timeline, in fixed ticks: the length of its clip and its shots.
@(private)
strip_rows :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    rate:=tick_rate(s)
    duration:=duration_of(w,c.timeline)*rate
    shots,shot_values:=parts_of(w,c.timeline,cine.Cinematic_Shot)
    marks:=make([]editor.Timeline_Mark,len(shot_values),context.temp_allocator)
    for shot,j in shot_values {marks[j]={frame=shot.time*rate,name=editor.entity_label(w,shot.camera)}}
    lanes:=[]editor.Timeline_Lane{{name="Shots",marks=marks,add=c.camera!=core.NONE}}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),padding={12,0,12,0},gap=8,align_y=.Center}) {
        ui.label(ctx,editor.entity_label(w,c.timeline),th.font_small,th.text,font=ui.FONT_SEMIBOLD)
        if current,_,ok:=shot_view(w,c.timeline,c.head/rate);ok {ui.label(ctx,editor.entity_label(w,current.camera),th.font_small,th.text_muted)}
    }
    clock:=editor.Timeline_Clock{frame=c.head,frames=duration,rate=rate,playing=c.playing,loop=c.loop,speed=c.speed,ask=editor.timeline_can_ask(s)}
    r:=editor.timeline_strip(s,&c.strip,clock,lanes,ui.id(ctx,"timeline"))
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
    case r.moved:
        if r.index<len(shots) {
            shot:=shot_values[r.index]
            shot.time=max(r.to,0)/rate
            component_write(s,w,shots[r.index],shot)
        }
    case r.add: add(s,c,w,{part=.Shot,timeline=c.timeline,target=c.camera,time=max(r.to,0)/rate})
    case r.menu:
        c.menu={r.index,r.to}
        ui.popup_open(ctx,ui.id(ctx,"menu"),r.anchor)
    }
    if ui.popup(ctx,ui.id(ctx,"menu"),{min_width=ui.MENU_CHOICE_WIDTH}) {
        m:=c.menu
        if m.index<0 {
            if ui.menu_item(ctx,ui.id(ctx,"menu_add"),"Add shot",{icon=.Plus}) {add(s,c,w,{part=.Shot,timeline=c.timeline,target=c.camera,time=max(m.tick,0)/rate})}
        } else if ui.menu_item(ctx,ui.id(ctx,"menu_delete"),"Delete shot",{icon=.Cross}) {
            if m.index<len(shots) {editor.entities_delete(s,shots[m.index:][:1])}
        }
    }
}
