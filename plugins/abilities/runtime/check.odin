package abilities

import "core:fmt"
import "core:mem"
import locomotion "plugins:locomotion/runtime"

// What is wrong with a sheet and how to fix it, written into out; empty when it is valid. The
// step reports it as a problem of the user and the API returns it, so both say the same.
ability_check :: proc(a:^Ability,out:[]u8) -> string {
    if a==nil {return ""}
    if a.input.on>max(Ability_Trigger) {return fmt.bprintf(out,"input.on is %d, not a trigger: use none, pressed, released, held or down",u8(a.input.on))}
    if !seconds_ok(a.input.hold) {return fmt.bprintf(out,"input.hold is %v: give the seconds the action is held, 0 or more",a.input.hold)}
    if !seconds_ok(a.input.after) {return fmt.bprintf(out,"input.after is %v: give the seconds into a running ability from which the input counts, 0 or more",a.input.after)}
    if a.input.wait>max(Ability_Wait) {return fmt.bprintf(out,"input.wait is %d: use buffer or running",u8(a.input.wait))}
    if a.input.on==.None && (a.input.after!=0 || a.input.wait!=.Buffer) {return "input.after or input.wait is set but input.on is none, so no input fires: give the trigger, or clear them"}
    if !finite(a.duration) || a.duration<=0 {return fmt.bprintf(out,"duration is %v: give the seconds the ability lasts, above 0",a.duration)}
    if !seconds_ok(a.cooldown) {return fmt.bprintf(out,"cooldown is %v: give the seconds before it starts again, 0 or more",a.cooldown)}
    for c,i in a.conditions {
        if !finite(c.at_least) || !finite(c.at_most) {return fmt.bprintf(out,"conditions[%d] has a bound that is not a number: give finite at_least and at_most",i)}
        if c.attribute==ATTRIBUTE_NONE && (c.at_least!=0 || c.at_most!=0) {return fmt.bprintf(out,"conditions[%d] has bounds and names no attribute: name the attribute it measures",i)}
        if c.at_most>0 && c.at_most<c.at_least {return fmt.bprintf(out,"conditions[%d] asks for at least %v and at most %v: no value is both; raise at_most or set it to 0 for no limit",i,c.at_least,c.at_most)}
    }
    for c,i in a.costs {
        if !finite(c.amount) || c.amount<0 {return fmt.bprintf(out,"costs[%d].amount is %v: give what it takes, 0 or more",i,c.amount)}
        if c.attribute==ATTRIBUTE_NONE && c.amount!=0 {return fmt.bprintf(out,"costs[%d] takes %v of no attribute: name the attribute it takes from",i,c.amount)}
    }
    for &w,i in a.windows {
        if w.to==0 {
            empty:=Ability_Window{}
            if mem.compare_ptrs(&w,&empty,size_of(Ability_Window))!=0 {return fmt.bprintf(out,"windows[%d] does something but its to is 0, which leaves it unused: give it the second it closes at",i)}
            continue
        }
        if !finite(w.from) || !finite(w.to) || w.from<0 || w.from>=w.to {return fmt.bprintf(out,"windows[%d] runs from %v to %v: from must be 0 or more and below to",i,w.from,w.to)}
        if w.clock>max(Ability_Clock) {return fmt.bprintf(out,"windows[%d].clock is %d: use world or own",i,u8(w.clock))}
        if w.clock==.World && w.to>a.duration {return fmt.bprintf(out,"windows[%d] closes at %v, after the duration %v: close it by then or lengthen the ability",i,w.to,a.duration)}
        if text:=modifier_check(w.modify,out);text!="" {return fmt.bprintf(out,"windows[%d].modify %s",i,text)}
        if w.hitbox.shape>max(Hitbox_Shape) {return fmt.bprintf(out,"windows[%d].hitbox.shape is %d: use none, box, sphere or capsule",i,u8(w.hitbox.shape))}
        if w.hitbox.shape!=.None {
            h:=w.hitbox
            for v in h.center {if !finite(v) {return fmt.bprintf(out,"windows[%d].hitbox.center is not a point: give finite metres",i)}}
            used:=3 if h.shape==.Box else 2 if h.shape==.Capsule else 1
            for k in 0..<used {if !finite(h.size[k]) || h.size[k]<=0 {return fmt.bprintf(out,"windows[%d].hitbox.size[%d] is %v: a %v needs it above 0 (box: half extents; sphere: x radius; capsule: x radius and y half height)",i,k,h.size[k],h.shape)}}
            if text:=effect_check(h.effect,out);text!="" {return fmt.bprintf(out,"windows[%d].hitbox.effect %s",i,text)}
        }
        for v in w.move.velocity {if !finite(v) {return fmt.bprintf(out,"windows[%d].move.velocity is not a velocity: give finite metres per second",i)}}
        if w.move.mix>max(locomotion.Move_Mix) {return fmt.bprintf(out,"windows[%d].move.mix is %d: use additive or override",i,u8(w.move.mix))}
    }
    return ""
}

// What is wrong with a kit, written into out; empty when it is valid.
kit_check :: proc(k:^Ability_Kit,out:[]u8) -> string {
    if k==nil {return ""}
    if !seconds_ok(k.buffer) {return fmt.bprintf(out,"buffer is %v: give the seconds an input waits for its ability, 0 or more",k.buffer)}
    return ""
}

// What is wrong with an effect, after the field that holds it.
effect_check :: proc(e:Ability_Effect,out:[]u8) -> string {
    if !finite(e.amount) {return "has an amount that is not a number: give a finite amount"}
    if e.attribute==ATTRIBUTE_NONE && e.amount!=0 {return "changes no attribute by its amount: name the attribute"}
    if !seconds_ok(e.seconds) {return "has seconds that are not 0 or more: give how long its statuses and modifier last"}
    if (e.statuses!=0 || e.modify.attribute!=ATTRIBUTE_NONE) && e.seconds==0 {return "grants statuses or a modifier for 0 seconds: give seconds above 0"}
    if !seconds_ok(e.period) {return "has a period that is not 0 or more seconds"}
    if e.period>0 && (e.seconds==0 || e.attribute==ATTRIBUTE_NONE) {return "repeats every period but lasts 0 seconds or names no attribute: give seconds above 0 and the attribute"}
    if (e.tags!=0 || e.cue!=CUE_NONE) && e.seconds==0 {return "has tags or a cue, which name its timer, but lasts 0 seconds: give seconds above 0"}
    if e.max_stacks>1 && e.tags==0 {return "stacks but has no tags: give it the tags that say what stacks"}
    if text:=modifier_check(e.modify,out);text!="" {return text}
    for v in e.knockback {if !finite(v) {return "has a knockback that is not a velocity: give finite metres per second"}}
    if !seconds_ok(e.knockback_seconds) {return "has knockback_seconds that are not 0 or more"}
    if e.knockback!={} && e.knockback_seconds==0 {return "has a knockback for 0 seconds: give knockback_seconds above 0"}
    return ""
}

@(private)
modifier_check :: proc(m:Ability_Modifier,out:[]u8) -> string {
    if !finite(m.add) || !finite(m.more) {return "has add or more that is not a number: give finite values"}
    if m.attribute==ATTRIBUTE_NONE && (m.add!=0 || m.more!=0) {return "changes no attribute: name the attribute it modifies"}
    if m.more<=-1 {return "has more at -1 or below, which leaves nothing or a negative value: keep it above -1"}
    return ""
}

// The attributes of a user that are not amounts, written into out; empty when they are valid.
attributes_check :: proc(user:^Ability_User,out:[]u8) -> string {
    for entry,i in user.attributes {
        if entry.attribute==ATTRIBUTE_NONE {continue}
        if !finite(entry.base) || !finite(entry.max) || !finite(entry.regen) || entry.max<0 {return fmt.bprintf(out,"attributes[%d] has a base, max or regen that is not a number, or a negative max: give finite values and a max of 0 or more",i)}
        for other in user.attributes[:i] {
            if other.attribute==entry.attribute {return fmt.bprintf(out,"attributes[%d] repeats an attribute of an earlier entry: keep one entry per attribute",i)}
        }
    }
    return ""
}

@(private)
seconds_ok :: #force_inline proc "contextless" (s:f32) -> bool {return finite(s) && s>=0}

finite :: #force_inline proc "contextless" (v:f32) -> bool {return v-v==0}
