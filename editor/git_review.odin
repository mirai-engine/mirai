package editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:editor/git"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// Details while a merge waits: the item the arrows are on, with its fields in
// conflict as two rows, what ours had over what came in, and the components
// one side removed whole. A row clicked is the one the merge takes; the scene
// shows it at once (git_merge_preview).

git_review_shown :: proc(s:^Session) -> bool {
    g:=s.git
    return g!=nil && g.merging && g.merge.loaded && g.merge.shown && g.merge.current>=0 && g.merge.current<len(g.merge.items)
}

git_review_build :: proc(s:^Session,w:core.World_Ref,width,max_height:f32) {
    g:=s.git;ctx:=s.gui.ctx;th:=&ctx.theme
    m:=&g.merge
    index:=m.current
    item:=&m.items[index]
    inner:=width-2*PANEL_PADDING
    // The strip of the arrows, under a line of the color of a conflict.
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(2),fill=th.danger}) {}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control+6),gap=2,align_y=.Center,padding={5,0,7,0}}) {
        count:=len(m.items)
        if ui.button(ctx,ui.id(ctx,"git_previous"),{icon=ui.icon_user(u8(User_Icon.Back)),tip="Previous conflict",style=.Ghost,width=ctx.theme.control,height=ctx.theme.control}).clicked {
            m.current=(index+count-1)%count
            git_merge_focus(s)
        }
        at:[24]u8
        ui.label(ctx,fmt.bprintf(at[:],"%d / %d",index+1,count),th.font_small,th.text_label,40,center=true)
        if ui.button(ctx,ui.id(ctx,"git_next"),{icon=.Chevron_Right,tip="Next conflict",style=.Ghost,width=ctx.theme.control,height=ctx.theme.control}).clicked {
            m.current=(index+1)%count
            git_merge_focus(s)
        }
        ui.spacer(ctx)
        if item.accepted {
            ui.icon(ctx,.Check,th.accent_hover,13)
            ui.label(ctx,"Accepted",th.font_small,th.accent_hover)
        } else {
            if ui.button(ctx,ui.id(ctx,"git_reject"),{icon=.Cross,icon_color=th.danger,tip="Keep mine",style=.Ghost,width=ctx.theme.control,height=ctx.theme.control}).clicked {git_merge_settle(s,index,true)}
            if ui.button(ctx,ui.id(ctx,"git_accept"),{icon=.Check,tip="Accept",style=.Accent,width=ctx.theme.control,height=ctx.theme.control}).clicked {git_merge_settle(s,index,false)}
        }
    }
    ui.divider(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(INSPECTOR_HEAD),padding={11,0,7,0},gap=6,align_y=.Center}) {
        ui.label(ctx,base.text_get(item.name[:]),th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
    }
    if ui.scroll_area(ctx,ui.id(ctx,"git_review_scroll"),&s.inspector.scroll,{height=ui.FIT,max_height=max(max_height-INSPECTOR_HEAD-th.control-16,80),direction=.Column,gap=7,padding={8,7,10,12}}) {
        file:=&m.files[item.file]
        if file.merged==nil {
            git_review_whole(s,index,inner)
            return
        }
        conflicts:=m.conflicts[item.first:][:item.count]
        // A card per component, in the order of the conflicts.
        for &conflict,i in conflicts {
            table:=base.text_get(conflict.table[:])
            first:=true
            for &earlier in conflicts[:i] {
                if base.text_get(earlier.table[:])==table {first=false;break}
            }
            if !first {continue}
            git_review_card(s,index,table,item.first,conflicts,inner)
        }
    }
}

// One component: its fields in conflict, or the whole of it when a side removed it.
@(private)
git_review_card :: proc(s:^Session,index:int,table:string,offset:int,conflicts:[]Git_Conflict,width:f32) {
    g:=s.git;ctx:=s.gui.ctx;th:=&ctx.theme
    removed:^Git_Conflict
    for &conflict in conflicts {
        if base.text_get(conflict.table[:])==table && conflict.kind==.Removed {removed=&conflict}
    }
    fill,stroke:=th.raised,th.rule
    if removed!=nil && !removed.take_ours {
        // What goes is red; what comes back is green.
        if removed.ours_has {fill,stroke=GIT_REMOVED_FILL,GIT_REMOVED_RULE} else {fill,stroke=GIT_ADDED_FILL,GIT_ADDED_RULE}
    }
    ui.id_push(ctx,ui.id(ctx,table))
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,fill=fill,stroke=stroke,stroke_width=1,radius=4}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(25),gap=7,align_y=.Center,padding={9,0,5,0}}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Component)),th.text_muted,14)
            ui.label(ctx,table==TABLE_ENTITIES_NAME?"Entity":table,th.font,th.text,font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            if removed!=nil {
                at:=offset+int((uintptr(removed)-uintptr(raw_data(conflicts)))/size_of(Git_Conflict))
                if ui.button(ctx,ui.id(ctx,"take"),{icon=.Check,tip=removed.ours_has?"Remove it, as they did":"Bring it back, as they have it",style=removed.take_ours?.Ghost:.Field,width=20,height=20,icon_size=12}).clicked {git_conflict_choose(s,at,false)}
                if ui.button(ctx,ui.id(ctx,"keep"),{icon=.Revert,tip=removed.ours_has?"Keep it":"Leave it removed",style=removed.take_ours?.Field:.Ghost,width=20,height=20,icon_size=12}).clicked {git_conflict_choose(s,at,true)}
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.rule}) {}
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={0,3,0,5}}) {
            for &conflict,i in conflicts {
                if base.text_get(conflict.table[:])!=table || conflict.kind!=.Value {continue}
                git_review_field(s,offset+i,&conflict,width)
            }
            if removed!=nil {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(6)}) {}
                text:=removed.ours_has?"Changed by you, removed by them":"Removed by you, changed by them"
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={9,0,9,0}}) {ui.label(ctx,text,th.font_small,th.text_muted)}
            }
        }
    }
}

TABLE_ENTITIES_NAME :: "entities"
GIT_REMOVED_FILL :: ui.Color{46,32,35,255}
GIT_REMOVED_RULE :: ui.Color{104,56,60,255}
GIT_CODE_COLOR :: ui.Color{187,188,200,255}
GIT_FILE_COLOR :: ui.Color{116,119,130,255}
GIT_ADDED_FILL :: ui.Color{32,43,37,255}
GIT_ADDED_RULE :: ui.Color{58,92,70,255}
GIT_CHANGED_FILL :: ui.Color{42,58,92,255}
GIT_CHANGED_RULE :: ui.Color{74,100,160,255}

// A field both sides changed: its name over what ours had, and what came in
// under it, the row the merge takes outlined.
@(private)
git_review_field :: proc(s:^Session,at:int,conflict:^Git_Conflict,width:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    ui.id_push(ctx,ui.id(ctx,"field",at))
    defer ui.id_pop(ctx)
    field:=strings.trim_prefix(strings.trim_prefix(base.text_get(conflict.field[:]),".value"),".")
    if field=="" {field="value"}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2,padding={9,3,20,3},fill=GIT_CHANGED_FILL,stroke=GIT_CHANGED_RULE,stroke_width=1}) {
        for side in 0..<2 {
            ours:=side==0
            chosen:=conflict.take_ours==ours
            text:=base.text_get(ours?conflict.ours[:]:conflict.theirs[:])
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=7,align_y=.Center}) {
                ui.label(ctx,ours?field:"",th.font_small,th.text,th.label_width)
                if git_review_value(s,ui.id(ctx,"side",side),text,chosen,strings.has_suffix(field,"rotation")) {git_conflict_choose(s,at,ours)}
                if !ours {ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),chosen?th.accent_hover:th.text_faint,12)}
                else {ui.box(ctx,{width=ui.fixed(12),height=ui.fixed(12)})}
            }
        }
    }
}

// A value as the boxes of Details show it: one per number of a short list
// (a vector, a color), one for anything else. True when it was clicked.
@(private)
git_review_value :: proc(s:^Session,id:ui.Id,text:string,chosen:bool,rotation:=false) -> bool {
    ctx:=s.gui.ctx;th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    color:=chosen?th.text:th.text_faint
    stroke:=chosen?th.accent:th.well_stroke
    numbers:[4]string
    count:=0
    trimmed:=strings.trim_space(text)
    if strings.has_prefix(trimmed,"[") && strings.has_suffix(trimmed,"]") {
        rest:=trimmed[1:len(trimmed)-1]
        for part in strings.split_iterator(&rest,",") {
            value:=strings.trim_space(part)
            if _,ok:=strconv.parse_f64(value);!ok || count>=len(numbers) {count=-1;break}
            numbers[count]=value
            count+=1
        }
    }
    // A rotation shows as the inspector has it: three angles in degrees, not its quaternion.
    if rotation && count==4 {
        parts:[4]f32
        for value,i in numbers {parts[i]=f32(strconv.parse_f64(value) or_else 0)}
        degrees:=mm.quat_to_euler(transmute(mm.Quat)parts)*mm.DEG_PER_RAD
        for axis in 0..<3 {numbers[axis]=git_number_text(degrees[axis])}
        count=3
    }
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(th.row-3),gap=4,align_y=.Center}) {
        if count>=2 {
            for value,axis in numbers[:count] {
                if ui.box(ctx,{width=ui.GROW,height=ui.GROW,gap=5,align_y=.Center,padding={3,0,3,0},fill=th.well,stroke=stroke,stroke_width=1,radius=3}) {
                    if ui.box(ctx,{width=ui.fixed(3),height=ui.fixed(th.row-11),fill=chosen?th.axis[axis]:th.text_faint,radius=1.5}) {}
                    ui.label(ctx,value,th.font_small,color,0)
                }
            }
        } else if ui.box(ctx,{width=ui.GROW,height=ui.GROW,align_y=.Center,padding={7,0,7,0},fill=th.well,stroke=stroke,stroke_width=1,radius=3,clip_x=true}) {
            // A text shows without the quotes of its JSON.
            shown:=trimmed
            if len(shown)>=2 && shown[0]=='"' && shown[len(shown)-1]=='"' {shown=shown[1:len(shown)-1]}
            ui.label(ctx,shown,th.font_small,color,0)
        }
    }
    return it.clicked
}

// A number as a field shows it: up to two decimals, without trailing zeros.
@(private)
git_number_text :: proc(value:f32) -> string {
    text:=fmt.tprintf("%.2f",value)
    text=strings.trim_right(text,"0")
    text=strings.trim_right(text,".")
    return text=="-0"?"0":text
}

// A file merged whole: yours or theirs, and the AI for text.
@(private)
git_review_whole :: proc(s:^Session,index:int,width:f32) {
    g:=s.git;ctx:=s.gui.ctx;th:=&ctx.theme
    item:=&g.merge.items[index]
    file:=&g.merge.files[item.file]
    options:=[3]struct{label:string,whole:Git_Whole,shown:bool}{
        {"Your version",.Ours,file.stages[1]!=nil},
        {"Their version",.Theirs,file.stages[2]!=nil},
        {"As the AI left it in the folder",.Folder,file.text},
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=4,padding={9,6,20,6},fill=GIT_CHANGED_FILL,stroke=GIT_CHANGED_RULE,stroke_width=1}) {
        for option,i in options {
            if !option.shown {continue}
            chosen:=file.whole==option.whole
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=7,align_y=.Center}) {
                if git_review_value(s,ui.id(ctx,"whole",i),option.label,chosen) {
                    file.whole=option.whole
                    item.accepted=false
                }
                if option.whole==.Theirs {ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),chosen?th.accent_hover:th.text_faint,12)}
                else {ui.box(ctx,{width=ui.fixed(12),height=ui.fixed(12)})}
            }
        }
    }
    if file.text && ui.button(ctx,ui.id(ctx,"git_ai"),{label="Resolve with AI",icon=.Sparkle,style=.Field,width=-1,center=true,disabled=git.working(g)}).clicked {git_merge_ai(s,index)}
}
