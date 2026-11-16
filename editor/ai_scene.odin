package editor

import "core:slice"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

AI_GHOST_CAPACITY :: 256

@(storage)
Ai_Scene :: struct {
    figures:[AI_TASK_CAPACITY]Presence,
    // What the turns waiting for review deleted, drawn as their outline only
    // where it was, until the deletion is kept or undone.
    ghosts:[AI_GHOST_CAPACITY]gpu.Instance_Desc,
    ghost_count:int,
    ghost_key:u64, // of the reviews and the scene they were made for; 0: none yet
}

// A turn stands in the scene once it has something there: the context the
// user selected for it, or what it changed, beside which it stands.
@(private)
ai_scene_task_visible :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task) -> bool {
    if !ai_task_current(s,task) || task.review_finished || task.world==nil {return false}
    if task.context_count==0 && len(task.review.changed_ids)==0 && len(task.review.transactions)==0 && !task.figure_shown {return false}
    if task.world!=w.data && (task.world!=s.edit_world || run_of_world(s,w.data)==nil) {return false}
    return ai_agent_visible(task)
}

// Its figure, glyph and name are drawn and take clicks.
@(private)
ai_scene_figure_shown :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task) -> bool {
    return s.ai!=nil && s.ai.show_agents_in_scene && presence_in_scene(s) && ai_scene_task_visible(s,w,task)
}

@(private)
ai_scene_highlights :: proc(s:^Session,w:core.World_Ref,levels:[]u8) {
    m:=s.ai
    if m==nil {return}
    presence_style(s)
    es:=core.world_entities(w)
    // The color of an agent wins over the selection of this end: what it works on shows whose it is.
    mark :: proc(es:^core.Entities,levels:[]u8,id:base.Entity_Id,level:u8) {
        e:=core.entity_of(es,id)
        if at:=core.entity_index(e);e!=core.NONE && at<len(levels) && (levels[at]==0 || level!=AI_CONTEXT_LEVEL && (levels[at]==HIGHLIGHT_SELECTED || levels[at]==HIGHLIGHT_DESCENDANT)) {levels[at]=level}
    }
    for index:=m.task_count-1;index>=0;index-=1 {
        task:=&m.tasks[index]
        if !ai_scene_task_visible(s,w,task) {continue}
        level:=agent_level(int(task.color_index))
        if task.review.pending {
            for changed in task.review.changed_ids {mark(es,levels,changed,level)}
        }
        // What it was given is in its color while it works on it, soft once it ended.
        given:=ai_task_finished(task)?AI_CONTEXT_LEVEL:level
        for selected in task.context_ids[:task.context_count] {mark(es,levels,selected,given)}
    }
    // What hangs from one takes its level, and from the nearest one when several hold it.
    h:=entity_hierarchy(w)
    roots:=make([dynamic]core.Entity,context.temp_allocator)
    for level,i in levels {
        if level>=5 && i<len(es.generation) {append(&roots,core.entity_make(i,es.generation[i]))}
    }
    for root in roots {
        level:=levels[core.entity_index(root)]
        for at:=core.subtree_next(h,root,root);at!=core.NONE; {
            i:=core.entity_index(at)
            if i>=len(levels) || levels[i]>=5 {
                at=core.subtree_next(h,root,at,false)
                continue
            }
            if levels[i]==0 {levels[i]=level}
            at=core.subtree_next(h,root,at)
        }
    }
}

@(private)
ai_scene_anchor :: proc(s:^Session,task:^Ai_Task) -> [3]f32 {
    if task.follows && s.viewport!=nil {
        task.follows=false
        if n:=len(task.review.transactions);n>0 {ai_scene_follow(s,task,edited_world(s),task.review.transactions[n-1].rows[:])}
    }
    if !task.anchor_set {
        point:=s.viewport.orbit.target
        point.y=0.02
        if s.selection!=nil && s.info!=nil {
            world:=shown_world(s)
            if pivot,found:=selection_pivot(s,world);found {point=pivot}
        }
        if task.play {
            if player:=play_player_snapshot(run_ref(s,ai_task_run(s,task)));player.available {point=player.body.entity!=core.NONE?player.body.world_position:player.seat.world_position}
        }
        entities:[]core.Entity
        if !task.play && s.selection!=nil {entities=s.selection.entities[:]}
        ai_scene_place(s,task,shown_world(s),point,entities)
    }
    return task.anchor
}

// Beside what the turn works on, in no body of the scene, looking at the
// middle of what it works on.
@(private)
ai_scene_place :: proc(s:^Session,task:^Ai_Task,w:core.World_Ref,point:[3]f32,entities:[]core.Entity) {
    look:=point
    point:=point
    active:=core.NONE
    if len(entities)>0 {active=entities[len(entities)-1]}
    g:=gizmo_at(s,w,point,active,s.viewport.tool)
    axis:=0
    if g.usable[2] && (!g.usable[0] || abs(g.ends[2].x-g.screen.x)>abs(g.ends[0].x-g.screen.x)) {axis=2}
    axes:=AXES;direction:=axes[axis]
    if g.visible {direction=g.axes[axis]}
    // The gizmo is kept clear only where it is drawn: on what the turn works
    // on while it is selected. Elsewhere the figure stands beside it, at the
    // level of its bottom.
    gizmo:=g.visible && active!=core.NONE && s.selection!=nil && slice.contains(s.selection.entities[:],active)
    distance:=gizmo?max(f32(1.25),g.size+0.55):f32(1)
    height:=gizmo?point.y+g.size+0.35:point.y
    if len(entities)>0 && s.app!=nil && s.app.assets!=nil {
        if low,high,found:=entities_bounds(s,w,entities);found {
            edge:=[3]f32{direction.x>=0?high.x:low.x,direction.y>=0?high.y:low.y,direction.z>=0?high.z:low.z}
            beside:=direction.x*(edge.x-point.x)+direction.y*(edge.y-point.y)+direction.z*(edge.z-point.z)+0.55
            distance=gizmo?max(distance,beside):beside
            height=gizmo?max(height,high.y+0.35):low.y
            look=(low+high)*0.5
        }
    }
    point+=direction*(distance+f32(task.color_index%3)*0.55)
    point.y=gizmo?max(point.y+g.size+0.35,height):height
    if s.app!=nil && s.viewport!=nil {
        if _,low,high,loaded:=presence_mesh(s.app.assets);loaded {point=presence_free_place(presence_space(w,low,high),low,point,look,orbit_position(s.viewport.orbit))}
    }
    task.anchor,task.anchor_set,task.look=point,true,look
}

// The latest entities a transaction changed that the figure of a turn looks at.
AI_SCENE_TARGETS :: 64

@(private)
ai_scene_follow :: proc(s:^Session,task:^Ai_Task,w:core.World_Ref,rows:[]history.Change_Row) {
    targets:[AI_SCENE_TARGETS]core.Entity
    count:=0
    pivot:[3]f32
    #reverse for row in rows {
        if count==len(targets) {break}
        e:=history.change_entity(w,row.id)
        if !entity_alive(w,e) || slice.contains(targets[:count],e) {continue}
        if count==0 {pivot=entity_world(w,e).position}
        targets[count]=e
        count+=1
    }
    if count>0 {
        ai_scene_place(s,task,w,pivot,targets[:count])
        return
    }
    // It only deleted: beside where the last one was.
    #reverse for row in rows {
        if place,deleted:=ai_review_deleted_world(w,task,row.id,0);deleted {
            ai_scene_place(s,task,w,place.position,nil)
            return
        }
    }
}

// The figure stands on its anchor: its eyes are the height of the platform under them above it.
@(private)
ai_scene_eyes :: proc(s:^Session,task:^Ai_Task) -> (eyes:[3]f32,top:f32,ok:bool) {
    _,low,high,loaded:=presence_mesh(s.app.assets)
    if !loaded {return}
    return ai_scene_anchor(s,task)+{0,-low.y,0},high.y,true
}

// The figure of a turn, kept by its place among the tasks.
@(private)
ai_scene_figure_of :: proc(s:^Session,task:^Ai_Task) -> ^Presence {
    m:=s.ai
    if m==nil || s.editor_world==nil || s.info==nil {return nil}
    state:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Ai_Scene)
    index:=int(uintptr(task)-uintptr(&m.tasks[0]))/size_of(Ai_Task)
    if state==nil || index<0 || index>=len(state.figures) {return nil}
    return &state.figures[index]
}

@(private)
ai_scene_figure_prepare :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task,figure:^Presence) -> bool {
    eyes,_,ok:=ai_scene_eyes(s,task)
    return ok && presence_prepare(s,figure,eyes,task.look,ai_agent_color(task),agent_level(int(task.color_index)),u64(task.id),w)
}

@(private)
ai_scene_screen :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task) -> (rect:ui.Rect,ok:bool) {
    eyes,top,loaded:=ai_scene_eyes(s,task)
    if !loaded {return}
    if figure:=ai_scene_figure_of(s,task);figure!=nil {eyes=presence_shown(figure,eyes)}
    return presence_glyph_rect(s,eyes+{0,top,0},s.viewport.view_projection)
}

// The rectangle of the window the figure of a turn covers: its bounds seen
// from the camera of the viewport.
@(private)
ai_scene_body_screen :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task) -> (rect:ui.Rect,ok:bool) {
    _,low,high,loaded:=presence_mesh(s.app.assets)
    if !loaded {return}
    eyes,_,_:=ai_scene_eyes(s,task)
    if figure:=ai_scene_figure_of(s,task);figure!=nil {eyes=presence_shown(figure,eyes)}
    lo,hi:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
    for corner in 0..<8 {
        p:=[3]f32{corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z}+eyes
        screen,_,front:=mm.world_to_screen(p,s.viewport.size,s.viewport.view_projection)
        if !front {return}
        lo,hi={min(lo.x,screen.x),min(lo.y,screen.y)},{max(hi.x,screen.x),max(hi.y,screen.y)}
    }
    origin:=s.viewport.origin
    return {lo.x+origin.x,lo.y+origin.y,hi.x-lo.x,hi.y-lo.y},true
}

@(private)
ai_scene_draw :: proc(s:^Session,w:core.World_Ref) {
    m:=s.ai
    if m==nil || s.editor_world==nil || s.info==nil {return}
    state:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Ai_Scene)
    if state==nil {return}
    presence_style(s)
    if presence_in_scene(s) {ai_scene_ghosts(s,w,state)}
    for &task,index in m.tasks[:m.task_count] {
        if !ai_scene_figure_shown(s,w,&task) {continue}
        task.figure_shown=true
        if ai_scene_figure_prepare(s,w,&task,&state.figures[index]) {host.extras_instance_add(&s.app.extras,state.figures[index].instance)}
        if rect,ok:=ai_scene_screen(s,w,&task);ok {
            color:=ai_agent_color(&task)
            presence_icon_draw(s,rect,ai_agent_icon(&task),color)
            name:=ai_agent_name(m,&task)
            presence_name_draw(s,rect,name,color)
        }
    }
    host.assets_commit(s.app.assets)
}

// The outlines of what the turns waiting for review deleted, made again only
// when a review or the scene changed, and drawn every frame like the figures.
@(private)
ai_scene_ghosts :: proc(s:^Session,w:core.World_Ref,state:^Ai_Scene) {
    m:=s.ai
    if s.app.assets==nil {return}
    key:=m.scene_serial*1_000_003+u64(core.world_entities(w).alive)+1
    if key!=state.ghost_key {
        state.ghost_count=0
        complete:=true
        for &task in m.tasks[:m.task_count] {
            if !ai_scene_task_visible(s,w,&task) {continue}
            level:=agent_level(int(task.color_index))
            for id in task.review.changed_ids {
                if state.ghost_count>=AI_GHOST_CAPACITY || history.change_entity(w,id)!=core.NONE {continue}
                mesh,shown:=ai_review_deleted_value(w,&task,id,erender.Mesh_Renderer)
                if !shown {continue}
                place,placed:=ai_review_deleted_world(w,&task,id,0)
                if !placed {continue}
                instance,ready:=erender.mesh_instance(s.app.assets,mesh,mm.transform_matrix(place))
                if !ready {complete=false;continue}
                instance.object_id=u64(id)|1<<63
                instance.highlight,instance.outline_only=level,true
                state.ghosts[state.ghost_count]=instance
                state.ghost_count+=1
            }
        }
        // A mesh still loading is asked for again the next frame.
        state.ghost_key=complete?key:0
    }
    for instance in state.ghosts[:state.ghost_count] {host.extras_instance_add(&s.app.extras,instance)}
}
