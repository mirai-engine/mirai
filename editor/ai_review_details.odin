package editor

import "core:fmt"
import "mirai:core"
import "mirai:ui"

// Details of an entity a turn changed while it waits for review: the entity
// as it is, which is what keeping it leaves, in the Details of every entity,
// with the fields the turn changed in the color of its agent and their
// arrows back; over it, the strip that walks the changes and keeps the
// entity or puts it back.

AI_REVIEW_STRIP :: f32(2) // the line of the color of the agent over the strip

// The turn waiting for review that changed the entity, if any.
ai_review_details_task :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> ^Ai_Task {
    m:=s.ai
    if m==nil || e==core.NONE {return nil}
    owners:[AI_TASK_CAPACITY]int
    for owner in owners[:ai_review_tasks_of(s,m,w,e,owners[:])] {
        if task:=ai_task_find(m,owner);task!=nil && ai_task_reviewable(task) && ai_task_current(s,task) {return task}
    }
    return nil
}

// The height of the strip over Details.
ai_review_strip_height :: proc(ctx:^ui.Context) -> f32 {return AI_REVIEW_STRIP+ui.metric(ctx,"control")+6+1}

// The strip of the review over Details: the previous and the next change,
// which of them this is, putting back what the agent did to the entity and
// keeping it.
ai_review_strip :: proc(s:^Session,w:core.World_Ref,task:^Ai_Task,e:core.Entity) {
    m:=s.ai;ctx:=s.gui.ctx
    color:=ai_agent_color(task)
    id:=api_entity_id(w,e)
    count:=ai_review_count(task)
    at:=-1
    for changed,i in task.review.changed_ids {
        if changed==id {at=i;break}
    }
    walked:=m.review_task==task.id && m.review_at==at
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_REVIEW_STRIP),fill=color}) {}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")+6),gap=2,align_y=.Center,padding={5,0,7,0},fill=ui.color_alpha(color,10)}) {
        if ui.button(ctx,ui.id(ctx,"ai_previous"),{icon=ui.icon_user(u8(User_Icon.Back)),tip="Previous change",variant="ghost",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control"),disabled=count<2}).clicked {
            if m.review_task!=task.id || m.review_at<0 {m.review_task,m.review_at=task.id,at}
            ai_review_walk(s,task,-1)
        }
        position:[24]u8
        ui.label(ctx,fmt.bprintf(position[:],"%d / %d",max(at,0)+1,count),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),40,center=true)
        if ui.button(ctx,ui.id(ctx,"ai_next"),{icon=.Chevron_Right,tip="Next change",variant="ghost",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control"),disabled=count<2}).clicked {
            if m.review_task!=task.id || m.review_at<0 {m.review_task,m.review_at=task.id,at}
            ai_review_walk(s,task)
        }
        ui.spacer(ctx)
        ui.icon(ctx,ai_agent_icon(task),color,16)
        if ui.button(ctx,ui.id(ctx,"ai_reject"),{icon=.Cross,icon_color=ui.tone(ctx,"danger"),tip="Put back what the agent did",variant="ghost",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control")}).clicked {
            if message:=ai_review_entity_revert(s,m,task,id);message!="" {notify(s,message);return}
            ai_review_resolved(s,task,id,walked || m.review_task!=task.id)
            return
        }
        if ui.button(ctx,ui.id(ctx,"ai_accept"),{icon=.Check,tip="Keep what the agent did",variant="accent",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control")}).clicked {
            ai_review_entity_accept(s,m,task,id)
            ai_review_resolved(s,task,id,walked || m.review_task!=task.id)
            return
        }
    }
    ui.divider(ctx)
}
