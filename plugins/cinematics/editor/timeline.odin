package cinematics_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:editor/kit"
import "mirai:ui"
import aed "plugins:animation/editor"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

// The Cinematics tool: the Tracks tool of the animation plugin opened on the clip of a timeline,
// which shows the scene at its head, with the shots and the actors of the timeline. It writes
// shots and actors as steps of the document; the keys of the clip are those of the Tracks tool.

TOOL :: "cinematics"
SCOPE :: ui.Id(0x63696e65)
NAMES :: 64 // entities the lists of the panel offer

@(storage)
Cinematic_Editor :: struct {
    timeline:core.Entity,
    shot_view:bool, // the viewport looks through the shot at the head
    viewing:bool,   // the view of the viewport is kept in kept
    kept:editor.Orbit,
    target:core.Entity,
    camera:core.Entity,
}

// Stops looking through the shot: the viewport goes back to its view.
view_restore :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    if c.viewing {s.viewport.orbit=c.kept}
    c.viewing=false
}

// The timeline the tool edits: the one it had, else the one of the selection, else the first of the scene.
@(private)
timeline_choose :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    if editor.entity_has(w,c.timeline,cine.Cinematic) {return}
    c.timeline=core.NONE
    for e in s.selection.entities {
        if t:=timeline_of(w,e);t!=core.NONE {c.timeline=t;return}
    }
    if table:=core.world_table_of(w,cine.Cinematic);table!=nil && core.count(table)>0 {c.timeline=core.entity_at(table,0)}
}

// The entities of a part of a timeline, in the order of their table.
@(private)
parts_of :: proc(w:core.World_Ref,timeline:core.Entity,$T:typeid) -> (entities:[]core.Entity,values:[]T) {
    table:=core.world_table_of(w,T)
    if table==nil {return}
    e:=make([dynamic]core.Entity,context.temp_allocator)
    v:=make([dynamic]T,context.temp_allocator)
    for row in 0..<core.count(table) {
        value:=core.at(table,row)
        if value.timeline==timeline {append(&e,core.entity_at(table,row));append(&v,value)}
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
cinematics_frame :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    if editor.playing(s) || !editor.tool_on(s,TOOL) {view_restore(s,c);return}
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    if c.timeline==core.NONE {view_restore(s,c);return}
    aed.tracks_open(s,c.timeline,TOOL)
    head,_,shown:=aed.tracks_head(s,c.timeline)
    if !c.shot_view || !shown {view_restore(s,c);return}
    if _,sample,ok:=shot_view(w,c.timeline,head);ok {
        if !c.viewing {c.kept,c.viewing=s.viewport.orbit,true}
        if orbit,made:=editor.orbit_of_camera(sample.pose,{fov=sample.fov,near=sample.near},max(s.viewport.orbit.distance,1));made {s.viewport.orbit=orbit}
    }
}

@(step="ui",after="editor_panels")
cinematics_panel :: proc(s:^editor.Session,c:^Cinematic_Editor) {
    g:=s.gui
    if !g.begun || editor.playing(s) || !editor.tool_on(s,TOOL) || s.viewport.pick.active {return}
    ctx:=g.ctx
    w:=editor.edited_world(s)
    timeline_choose(s,c,w)
    id:=ui.id_derive(ctx,SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        side_rows(s,c,w)
        if editor.entity_has(w,c.timeline,cine.Cinematic) {aed.tracks_rows(s)}
    }
}

// The timeline the tool shows and what adds shots and actors to it.
@(private)
side_rows :: proc(s:^editor.Session,c:^Cinematic_Editor,w:core.World_Ref) {
    ctx:=s.gui.ctx
    kit.section(ctx,"Cinematic")
    timelines,_:=entity_names(w,cine.Cinematic,false)
    chosen:=-1
    for e,i in timelines.entities {if e==c.timeline {chosen=i}}
    if kit.property(ctx,"Timeline") {
        if ui.dropdown(ctx,ui.id(ctx,"timeline"),{list=timelines.names},&chosen,{width=-1,empty="None"}) && chosen>=0 {c.timeline=timelines.entities[chosen]}
    }
    if ui.button(ctx,ui.id(ctx,"new"),{label="New timeline",variant="field",width=-1,center=true}).clicked {
        opened,ready:=editor.edit_open(s,"New cinematic")
        if ready {
            if e,_:=part_add(s,w,{part=.Timeline});e!=core.NONE {c.timeline=e}
        }
        editor.edit_close(s,opened)
    }
    if !editor.entity_has(w,c.timeline,cine.Cinematic) {return}
    kit.toggle(ctx,ui.id(ctx,"shot_view"),"Shot view",&c.shot_view)

    kit.section(ctx,"Add")
    cameras,_:=entity_names(w,erender.Camera,true)
    choose(ctx,"Camera",cameras,&c.camera)
    if ui.button(ctx,ui.id(ctx,"shot"),{label="Add shot",variant="field",width=-1,center=true,disabled=c.camera==core.NONE}).clicked {
        head,_,_:=aed.tracks_head(s,c.timeline)
        add(s,w,{part=.Shot,timeline=c.timeline,target=c.camera,time=head})
    }
    targets,_:=entity_names(w,core.Transform,true)
    choose(ctx,"Entity",targets,&c.target)
    if ui.button(ctx,ui.id(ctx,"actor"),{label="Add actor",variant="field",width=-1,center=true,disabled=c.target==core.NONE || c.target==c.timeline}).clicked {
        add(s,w,{part=.Actor,timeline=c.timeline,target=c.target})
    }

    choose :: proc(ctx:^ui.Context,label:string,names:Names,value:^core.Entity) {
        chosen:=-1
        for e,i in names.entities {if e==value^ {chosen=i}}
        if kit.property(ctx,label) {
            if ui.dropdown(ctx,ui.id(ctx,label),{list=names.names},&chosen,{width=-1,empty="None"}) && chosen>=0 {value^=names.entities[chosen]}
        }
    }
}

@(private)
add :: proc(s:^editor.Session,w:core.World_Ref,desc:Part_Desc) {
    opened,ready:=editor.edit_open(s,fmt.tprintf("Add %v",desc.part))
    if !ready {return}
    defer editor.edit_close(s,opened)
    if _,problem:=part_add(s,w,desc);problem!="" {editor.notify(s,fmt.tprintf("The %v could not be added: %s",desc.part,problem))}
    // A new actor takes its place at the head.
    aed.tracks_command(s,desc.timeline,.Seek,0,false,0)
}

Names :: struct {entities:[]core.Entity,names:[]string}

// The entities with a component, by name, for a list of the panel.
@(private)
entity_names :: proc(w:core.World_Ref,$T:typeid,numbered:bool) -> (names:Names,complete:bool) {
    table:=core.world_table_of(w,T)
    if table==nil {return {},true}
    count:=min(core.count(table),NAMES)
    names.entities=make([]core.Entity,count,context.temp_allocator)
    names.names=make([]string,count,context.temp_allocator)
    for row in 0..<count {
        e:=core.entity_at(table,row)
        names.entities[row]=e
        names.names[row]=numbered?fmt.tprintf("%s (%d)",editor.entity_label(w,e),row+1):editor.entity_label(w,e)
    }
    return names,count==core.count(table)
}
