package ui

import "core:math"

// Pointer, keyboard and gamepad reach widgets through three ids of the
// context: hot (under the pointer), active (holds the pointer since it was
// pressed there) and focus (the keyboard and the gamepad act on it).
//
// The pointer is tested against the rectangles of the previous frame: the
// ones that were on screen when the input happened. The highest layer wins
// and, inside it, the widget registered last.

Interaction :: struct {
    hot:bool,      // the pointer is over it
    active:bool,   // it holds the pointer
    focused:bool,
    pressed:bool,  // the left button went down on it this frame
    released:bool, // the left button it held came up this frame
    clicked:bool,  // activated: by the pointer (on press or on release, as the theme says) or by navigation
    double:bool,   // pressed with the second click of a double click
    right:bool,    // the right button went down on it this frame
}

@(private)
affine_apply :: #force_inline proc "contextless" (m:Affine,p:[2]f32) -> [2]f32 {
    return {m[0,0]*p.x+m[0,1]*p.y+m[0,2],m[1,0]*p.x+m[1,1]*p.y+m[1,2]}
}

@(private)
effect_hit :: proc(ctx:^Context,index:u16,point:[2]f32) -> bool {
    for index:=index;index!=0;index=ctx.previous_effects[index].parent {
        if int(index)>=ctx.previous_effect_count {return false}
        e:=&ctx.previous_effects[index]
        if e.suppressed || e.opacity<=0 {return false}
        p:=point
        if e.scope!=0 && int(e.scope)<ctx.previous_scope_count {p=affine_apply(ctx.previous_scopes[e.scope],point)}
        if !rect_contains(e.rect,p) {return false}
        radius:=clamp(e.radius,0,min(e.rect.w,e.rect.h)*0.5)
        q:=[2]f32{abs(p.x-e.rect.x-e.rect.w*0.5),abs(p.y-e.rect.y-e.rect.h*0.5)}-{e.rect.w*0.5-radius,e.rect.h*0.5-radius}
        outside:=[2]f32{max(q.x,0),max(q.y,0)}
        if math.sqrt(outside.x*outside.x+outside.y*outside.y)+min(max(q.x,q.y),0)>radius {return false}
    }
    return true
}

@(private)
widget_hit :: proc(ctx:^Context,surface:u16,point:[2]f32) -> ^Widget {
    best:^Widget
    for &w in ctx.previous[:ctx.previous_count] {
        if w.surface!=surface || .Passive in w.flags {continue}
        p:=point
        if w.scope!=0 && int(w.scope)<ctx.previous_scope_count {p=affine_apply(ctx.previous_scopes[w.scope],point)}
        if !rect_contains(w.area,p) || !effect_hit(ctx,w.effect_clip,point) {continue}
        if best==nil || w.layer>=best.layer {best=&w}
    }
    return best
}

// Whether the pointer is over a widget that takes no input, such as a text,
// and nothing on a higher layer covers it.
@(private)
widget_under :: proc(ctx:^Context,id:Id) -> bool {
    if ctx.input.pointer_absent || id==0 {return false}
    w:=widget_previous(ctx,id)
    if w==nil || ctx.hot!=0 && w.layer<ctx.hot_layer {return false}
    point:=ctx.screen_pointer if w.surface==0 else ctx.previous_panels[w.surface-1].pointer
    p:=point
    if w.scope!=0 && int(w.scope)<ctx.previous_scope_count {p=affine_apply(ctx.previous_scopes[w.scope],point)}
    return rect_contains(w.area,p) && effect_hit(ctx,w.effect_clip,point)
}

@(private)
input_route :: proc(ctx:^Context) {
    ctx.hot=0;ctx.hot_layer=min(i16);ctx.over=false;ctx.wheel_target=0
    hit:^Widget
    if !ctx.input.pointer_absent {hit=widget_hit(ctx,0,ctx.screen_pointer)}
    if world:=panels_route(ctx,hit==nil);world!=nil {hit=world}
    if hit!=nil {
        ctx.over=true;ctx.hot=hit.id;ctx.hot_layer=hit.layer
        if ctx.input.wheel!={} {
            // The wheel belongs to the innermost scroll area of that layer under the pointer.
            point:=ctx.screen_pointer if hit.surface==0 else ctx.previous_panels[hit.surface-1].pointer
            target:^Widget
            for &w in ctx.previous[:ctx.previous_count] {
                if .Scroll not_in w.flags || w.surface!=hit.surface || w.layer<hit.layer {continue}
                p:=point
                if w.scope!=0 && int(w.scope)<ctx.previous_scope_count {p=affine_apply(ctx.previous_scopes[w.scope],point)}
                if !rect_contains(w.area,p) || !effect_hit(ctx,w.effect_clip,point) {continue}
                if target==nil || w.layer>=target.layer {target=&w}
            }
            if target!=nil {ctx.wheel_target=target.id}
        }
    }
    // Until the widget that holds the pointer lets it go, no other one is under it.
    if ctx.active!=0 && ctx.hot!=ctx.active {ctx.hot=0}
    // A press of any button that no focusable widget takes, as on what is under the UI, takes the focus away.
    // Where the keys and the gamepad navigate, the focus stays where it is and only its ring goes: a
    // menu keeps its place for the gamepad while the mouse clicks around it.
    if ctx.input.pressed!={} && ctx.active==0 && (hit==nil || .Focusable not_in hit.flags || .Disabled in hit.flags) {
        if ctx.navigation {ctx.focus_ring=false} else {ctx.focus=0}
    }
}

@(private)
input_frame_end :: proc(ctx:^Context) {
    if ctx.active!=0 && (.Left not_in ctx.input.down || ctx.active_frame!=ctx.stats.frame) {ctx.active=0}
    if ctx.edit.id!=0 && ctx.edit.frame!=ctx.stats.frame {ctx.edit={}}
    if ctx.scrub.id!=0 && ctx.active!=ctx.scrub.id {ctx.scrub={}}
    if ctx.edit_request!=0 && ctx.stats.frame>ctx.edit_request_frame {ctx.edit_request=0}
    ctx.navigation_layer=min(i16)
    if ctx.popup.count>0 {ctx.navigation_layer=ctx.popup.stack[ctx.popup.count-1].layer} else if ctx.modal_open {ctx.navigation_layer=ctx.modal_layer}
}

// A ring around the widget navigation is on, over everything else.
@(private)
focus_ring_draw :: proc(ctx:^Context,effect:u16=0) {
    if ctx.focus==0 || !ctx.focus_ring || ctx.theme.focus[3]==0 {return}
    for &w in ctx.widgets[:ctx.widget_count] {
        if w.id!=ctx.focus || .Passive in w.flags || .Disabled in w.flags || w.effect_clip!=effect || w.area.w<=0 || w.area.h<=0 {continue}
        visible:=true
        for index:=w.effect_clip;index!=0;index=ctx.effects[index].parent {e:=&ctx.effects[index];if e.opacity<=0 || e.suppressed {visible=false;break}}
        if !visible {continue}
        paint_select(ctx,w.surface,w.scope)
        draw_rounded_stroke(ctx,{w.rect.x-2,w.rect.y-2,w.rect.w+4,w.rect.h+4},ctx.theme.radius_control+2,2,ctx.theme.focus)
        return
    }
}

// The pointer side of a widget. Call it once per frame for every element the
// pointer or the focus can reach, with the id its element has.
interact :: proc(ctx:^Context,id:Id,flags:Widget_Flags={}) -> (it:Interaction) {
    flags:=flags
    if ctx.disabled_depth>0 {flags+={.Disabled}}
    if ctx.effect_refused>0 || ctx.invisible>0 {flags+={.Disabled,.Passive}}
    widget_add(ctx,id,flags)
    if .Disabled in flags {
        if ctx.active==id {ctx.active=0}
        return
    }
    if id==0 || ctx.skipped>0 {return}
    it.hot=ctx.hot==id
    if it.hot && .Left in ctx.input.pressed && !ctx.press_used && ctx.active==0 {
        ctx.active=id;ctx.press=ctx.pointer;ctx.press_used=true
        it.pressed=true;it.double=ctx.input.clicks>=2
        if .Focusable in flags {ctx.focus=id;ctx.focus_ring=false}
    }
    if ctx.active==id {
        it.active=true;ctx.active_frame=ctx.stats.frame
        if .Left in ctx.input.released || .Left not_in ctx.input.down {it.released=true;ctx.active=0}
    }
    if it.hot && .Right in ctx.input.pressed && !ctx.right_press_used {it.right=true;ctx.right_press_used=true}
    it.focused=ctx.focus==id
    it.clicked=it.pressed if ctx.theme.activate_on_press else it.released&&it.hot
    if ctx.activate==id && ctx.activate!=0 {it.clicked=true}
    return
}

disabled_begin :: proc(ctx:^Context) {ctx.disabled_depth+=1}
disabled_end :: proc(ctx:^Context) {ctx.disabled_depth=max(ctx.disabled_depth-1,0)}

// A surface that takes the pointer and does nothing with it: a panel, a backdrop.
block :: proc(ctx:^Context,id:Id) {widget_add(ctx,id,{.Block})}

focus_set :: proc(ctx:^Context,id:Id) {ctx.focus=id;ctx.focus_ring=false}

// ---------------------------------------------------------------- navigation

@(private)
navigation_candidate :: proc(ctx:^Context,w:^Widget) -> bool {
    for index:=w.effect_clip;index!=0;index=ctx.previous_effects[index].parent {
        if int(index)>=ctx.previous_effect_count {return false}
        e:=&ctx.previous_effects[index]
        if e.opacity<=0 || e.suppressed {return false}
    }
    return .Focusable in w.flags && .Disabled not_in w.flags && w.layer>=ctx.navigation_layer && (w.area.w>0 && w.area.h>0 || .Scrolled in w.flags)
}

// Moves the focus to the next (step 1) or the previous (step -1) focusable
// widget of the navigation group of the one it is on: those with an order
// first, by it, then the rest in the order they were built, wrapping around.
focus_advance :: proc(ctx:^Context,step:int) -> Id {
    count:=ctx.previous_count
    if count==0 {return 0}
    group:Id
    focused,has_focus:=id_table_find(&ctx.previous_ids,ctx.focus)
    if has_focus {group=ctx.previous[focused].group}
    // Sorted by (order, index), where 0 sorts after every order.
    key :: proc "contextless" (w:^Widget,index:int) -> i64 {
        order:=i64(w.order) if w.order!=0 else i64(max(i16))+1
        return order<<32|i64(index)
    }
    from:i64=-1
    if has_focus {from=key(&ctx.previous[focused],int(focused))}
    best,first:=-1,-1
    best_key,first_key:i64
    for &w,i in ctx.previous[:count] {
        if !navigation_candidate(ctx,&w) || w.group!=group {continue}
        k:=key(&w,i)
        if step>0 {
            if from>=0 && k>from && (best<0 || k<best_key) {best,best_key=i,k}
            if first<0 || k<first_key {first,first_key=i,k}
        } else {
            if from>=0 && k<from && (best<0 || k>best_key) {best,best_key=i,k}
            if first<0 || k>first_key {first,first_key=i,k}
        }
    }
    if best<0 {best=first}
    if best<0 {return 0}
    ctx.focus=ctx.previous[best].id;ctx.focus_ring=true
    return ctx.focus
}

// Moves the focus to the widget focus_neighbor finds; with none to go from,
// to the first one.
focus_move :: proc(ctx:^Context,direction:[2]f32) -> Id {
    from:=widget_previous(ctx,ctx.focus)
    if from==nil || !navigation_candidate(ctx,from) {return focus_advance(ctx,1)}
    next:=focus_neighbor(ctx,from.id,direction)
    if next==0 {return 0}
    ctx.focus=next;ctx.focus_ring=true
    return next
}

// Where navigation goes from the widget from in a direction, as the last
// frame laid it out, without moving the focus: the one its link names for
// that side, or the nearest focusable widget of its group that way, or,
// inside a container that wraps in that axis, the farthest one on its other
// side. 0: none.
focus_neighbor :: proc(ctx:^Context,from_id:Id,direction:[2]f32) -> Id {
    from:=widget_previous(ctx,from_id)
    if from==nil {return 0}
    side:=0 if direction.y<0 else 1 if direction.x>0 else 2 if direction.y>0 else 3
    for link in ctx.previous_links[:ctx.previous_link_count] {
        if link.from!=from.id || link.to[side]==0 {continue}
        for &w in ctx.previous[:ctx.previous_count] {
            if w.id==link.to[side] && navigation_candidate(ctx,&w) {return w.id}
        }
    }
    origin:=rect_center(from.rect)
    best:^Widget;best_score:=max(f32)
    for &w in ctx.previous[:ctx.previous_count] {
        if &w==from || w.surface!=from.surface || w.group!=from.group || !navigation_candidate(ctx,&w) {continue}
        delta:=rect_center(w.rect)-origin
        along:=delta.x*direction.x+delta.y*direction.y
        if along<=0.5 {continue}
        across:=abs(delta.x*direction.y-delta.y*direction.x)
        // What faces the widget across that side comes first; the rest counts
        // while it lies inside a cone around the direction.
        facing:=min(from.rect.y+from.rect.h,w.rect.y+w.rect.h)>max(from.rect.y,w.rect.y) if direction.y==0 else min(from.rect.x+from.rect.w,w.rect.x+w.rect.w)>max(from.rect.x,w.rect.x)
        if !facing && across>along*2 {continue}
        score:=along if facing else 1e6+along+across*2
        if score<best_score {best,best_score=&w,score}
    }
    if best==nil {best=focus_wrap(ctx,from,direction)}
    if best==nil {return 0}
    return best.id
}

// The widget the focus wraps to from from: inside the innermost group that
// holds it and wraps in the axis of direction, the one farthest the other way
// among those that face it across that axis, or among all when none does.
@(private)
focus_wrap :: proc(ctx:^Context,from:^Widget,direction:[2]f32) -> ^Widget {
    group:Rect
    found:=false
    for g in ctx.previous_groups[:ctx.previous_group_count] {
        if direction.x!=0 && !g.x || direction.y!=0 && !g.y {continue}
        r,ok:=widget_rect(ctx,g.id)
        if !ok || !rect_contains(r,rect_center(from.rect)) {continue}
        if !found || r.w*r.h<group.w*group.h {group,found=r,true}
    }
    if !found {return nil}
    best:^Widget
    best_score:=max(f32)
    for facing_only in ([2]bool{true,false}) {
        for &w in ctx.previous[:ctx.previous_count] {
            if &w==from || w.surface!=from.surface || w.group!=from.group || !navigation_candidate(ctx,&w) || !rect_contains(group,rect_center(w.rect)) {continue}
            facing:=min(from.rect.y+from.rect.h,w.rect.y+w.rect.h)>max(from.rect.y,w.rect.y) if direction.y==0 else min(from.rect.x+from.rect.w,w.rect.x+w.rect.w)>max(from.rect.x,w.rect.x)
            if facing_only && !facing {continue}
            center:=rect_center(w.rect)
            // Farthest the other way: the least along the direction.
            score:=center.x*direction.x+center.y*direction.y
            if score<best_score {best,best_score=&w,score}
        }
        if best!=nil {break}
    }
    return best
}

@(private)
navigation_route :: proc(ctx:^Context) {
    if !ctx.navigation || ctx.edit.id!=0 {return}
    in_:=&ctx.input
    shift:=.Shift in in_.modifiers
    if .Tab in in_.keys_repeated {focus_advance(ctx,-1 if shift else 1)}
    if .Next in in_.pad {focus_advance(ctx,1)}
    if .Previous in in_.pad {focus_advance(ctx,-1)}
    focused:=widget_previous(ctx,ctx.focus)
    adjusts:=focused!=nil && .Adjusts in focused.flags
    if !adjusts {
        if .Left in in_.keys_repeated || .Left in in_.pad {focus_move(ctx,{-1,0})}
        if .Right in in_.keys_repeated || .Right in in_.pad {focus_move(ctx,{1,0})}
    }
    if .Up in in_.keys_repeated || .Up in in_.pad {focus_move(ctx,{0,-1})}
    if .Down in in_.keys_repeated || .Down in in_.pad {focus_move(ctx,{0,1})}
    if ctx.focus!=0 && (.Enter in in_.keys_pressed || .Space in in_.keys_pressed || .Accept in in_.pad) {
        ctx.activate=ctx.focus;ctx.focus_ring=true
    }
}
