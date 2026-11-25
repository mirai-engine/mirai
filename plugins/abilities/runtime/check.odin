package abilities

import "core:fmt"
import "mirai:core"
import inp "mirai:engine/input"
import locomotion "plugins:locomotion/runtime"

// What is wrong with a sheet and how to fix it, written into out; empty when it is valid. The
// step reports it as a problem of the user and the API returns it, so both say the same.
ability_check :: proc(a:^Ability,out:[]u8) -> string {
    if a==nil {return ""}
    if a.input.on>max(Ability_Trigger) {return fmt.bprintf(out,"input.on is %d, not a trigger: use none, pressed, released, held or down",u8(a.input.on))}
    if a.input.on!=.None && int(a.input.action)>=inp.ACTION_CAPACITY {return "input.action is outside the input map: pick an action"}
    if !seconds_ok(a.input.hold) {return fmt.bprintf(out,"input.hold is %v: give the seconds the action is held, 0 or more",a.input.hold)}
    if !seconds_ok(a.input.after) {return fmt.bprintf(out,"input.after is %v: give the seconds into a running ability from which the input counts, 0 or more",a.input.after)}
    if a.input.wait>max(Ability_Wait) {return fmt.bprintf(out,"input.wait is %d: use buffer or running",u8(a.input.wait))}
    if a.input.on==.None && (a.input.after!=0 || a.input.wait!=.Buffer) {return "input.after or input.wait is set but input.on is none, so no input fires: give the trigger, or clear them"}
    if !finite(a.duration) || a.duration<=0 {return fmt.bprintf(out,"duration is %v: give the seconds the ability lasts, above 0",a.duration)}
    if !seconds_ok(a.cooldown) {return fmt.bprintf(out,"cooldown is %v: give the seconds before it starts again, 0 or more",a.cooldown)}
    for c,i in a.conditions {
        if c.kind>max(Ability_Condition_Kind) {return fmt.bprintf(out,"conditions[%d].kind is %d: use attribute or speed",i,u8(c.kind))}
        if !finite(c.at_least) || !finite(c.at_most) {return fmt.bprintf(out,"conditions[%d] has a bound that is not a number: give finite at_least and at_most",i)}
        if c.at_most>0 && c.at_most<c.at_least {return fmt.bprintf(out,"conditions[%d] asks for at least %v and at most %v: no value is both; raise at_most or set it to 0 for no limit",i,c.at_least,c.at_most)}
        switch c.kind {
        case .Attribute:
            if c.attribute==ATTRIBUTE_NONE && (c.at_least!=0 || c.at_most!=0) {return fmt.bprintf(out,"conditions[%d] has bounds and names no attribute: name the attribute it measures",i)}
        case .Speed:
            if c.attribute!=ATTRIBUTE_NONE {return fmt.bprintf(out,"conditions[%d] measures the speed of the Character and names an attribute: clear it",i)}
            if c.at_least<0 {return fmt.bprintf(out,"conditions[%d] asks for a speed of at least %v: give 0 or more metres per second",i,c.at_least)}
        }
    }
    draining:=false
    for c,i in a.costs {
        if !finite(c.amount) || c.amount<0 {return fmt.bprintf(out,"costs[%d].amount is %v: give what it takes, 0 or more",i,c.amount)}
        if !finite(c.per_second) || c.per_second<0 {return fmt.bprintf(out,"costs[%d].per_second is %v: give what it takes every second, 0 or more",i,c.per_second)}
        if c.attribute==ATTRIBUTE_NONE && (c.amount!=0 || c.per_second!=0) {return fmt.bprintf(out,"costs[%d] takes from no attribute: name the attribute it takes from",i)}
        if c.per_second>0 {draining=true}
    }
    if a.pause_modes!=0 && !draining {return "pause_modes pauses the per_second costs and it has none: give a cost per_second, or clear pause_modes"}
    if !seconds_ok(a.end_grace) {return fmt.bprintf(out,"end_grace is %v: give the seconds in its end_modes after which it completes, 0 or more",a.end_grace)}
    if a.end_grace>0 && a.end_modes==0 {return "end_grace is set and end_modes names no mode: name the modes it ends in, or clear end_grace"}
    for &w,i in a.windows {
        has_span:=w.span[0]!=0
        if !has_span && w.to==0 {
            if w!=(Ability_Window{}) {return fmt.bprintf(out,"windows[%d] does something but its to is 0, which leaves it unused: give it the second it closes at or a clip span",i)}
            continue
        }
        if has_span {
            if w.from!=0 || w.to!=0 {return fmt.bprintf(out,"windows[%d] names a clip span and also sets from or to: clear from and to, or clear span",i)}
        } else {
            if !finite(w.from) || !finite(w.to) || w.from<0 || w.from>=w.to {return fmt.bprintf(out,"windows[%d] runs from %v to %v: from must be 0 or more and below to",i,w.from,w.to)}
        }
        if w.clock>max(Ability_Clock) {return fmt.bprintf(out,"windows[%d].clock is %d: use world or own",i,u8(w.clock))}
        if !has_span && w.clock==.World && w.to>a.duration {return fmt.bprintf(out,"windows[%d] closes at %v, after the duration %v: close it by then or lengthen the ability",i,w.to,a.duration)}
        if text:=modifier_check(w.modify,out);text!="" {return fmt.bprintf(out,"windows[%d].modify %s",i,text)}
        for v in w.move.velocity {if !finite(v) {return fmt.bprintf(out,"windows[%d].move.velocity is not a velocity: give finite metres per second",i)}}
        if w.move.mix>max(locomotion.Move_Mix) {return fmt.bprintf(out,"windows[%d].move.mix is %d: use additive or override",i,u8(w.move.mix))}
    }
    return ""
}

hitbox_check :: proc(h:^Ability_Hitbox,out:[]u8) -> string {
    if h.shape==.None || h.shape>max(Hitbox_Shape) {
        return "shape must be box, sphere or capsule"
    }
    for v in h.center {
        if !finite(v) {return "center is not a point: give finite metres"}
    }
    used:=3 if h.shape==.Box else 2 if h.shape==.Capsule else 1
    for i in 0..<used {
        if !finite(h.size[i]) || h.size[i]<=0 {
            return fmt.bprintf(out,"size[%d] must be finite and above 0 for a %v",i,h.shape)
        }
    }
    if text:=effect_check(h.effect,out);text!="" {return fmt.bprintf(out,"effect %s",text)}
    for te,i in h.target_effects {
        if te==(Ability_Effect{}) {continue}
        if te.target_tags.bits==0 {return fmt.bprintf(out,"target_effects[%d] has no target_tags: set target_tags or clear it",i)}
        if text:=effect_check(te,out);text!="" {return fmt.bprintf(out,"target_effects[%d] %s",i,text)}
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
    if !seconds_ok(m.ramp_in) || !seconds_ok(m.ramp_out) {return "has ramp_in or ramp_out that is not 0 or more seconds"}
    if m.attribute==ATTRIBUTE_NONE && (m.add!=0 || m.more!=0 || m.ramp_in!=0 || m.ramp_out!=0) {return "changes no attribute: name the attribute it modifies"}
    if m.more<=-1 {return "has more at -1 or below, which leaves nothing or a negative value: keep it above -1"}
    return ""
}

Attribute_Problem :: enum u8 {None, Number, Duplicate}

attributes_check :: proc(user:^Ability_User) -> (problem:Attribute_Problem,index:int) {
    seen:[256]bool
    for entry,i in user.attributes {
        if entry.attribute==ATTRIBUTE_NONE {continue}
        if !finite(entry.base) || !finite(entry.max) || !finite(entry.regen) || !finite(entry.regen_delay) || entry.max<0 || entry.regen_delay<0 {
            return .Number,i
        }
        id:=int(entry.attribute)
        if seen[id] {return .Duplicate,i}
        seen[id]=true
    }
    return
}

attribute_report :: proc(problems:^core.Problems,e:core.Entity,problem:Attribute_Problem,i:int) {
    switch problem {
    case .None:
    case .Number:
        core.report(problems,e,"abilities.attributes","attributes[%d] needs finite base, max, regen and regen_delay, with max and regen_delay of 0 or more",i)
    case .Duplicate:
        core.report(problems,e,"abilities.attributes","attributes[%d] repeats an attribute: keep one entry per attribute",i)
    }
}

@(private)
seconds_ok :: #force_inline proc "contextless" (s:f32) -> bool {return finite(s) && s>=0}

finite :: #force_inline proc "contextless" (v:f32) -> bool {return v-v==0}
