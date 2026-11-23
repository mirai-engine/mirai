package animation_physics

import "mirai:core"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// The feet of a Character plant only while it stands: every tick the grounding of the rig of its
// animation, when the rig has one, weighs 1 while its Character_State stands and 0 in the air, so
// a jump or a fall lifts no foot toward the ground under it. A game writes no code for it.
@(step="fixed",stage="simulate",after="physics_step",before="animation_sample")
animation_grounding :: proc(found:^core.Table(phys.Character_State,.Read),animations:^core.Table(anim.Animation,.Read),modifiers:core.Ref(anim.Modifier_Runtime),sets:core.Ref(anim.Character_Assets),requests:^anim.Animation_Requests) {
    for row in 0..<core.count(found) {
        entity:=core.entity_at(found,row)
        if !core.has(animations,entity) {continue}
        profile:=anim.modifier_profile(modifiers,sets,entity)
        if profile==nil || anim.modifier_count(profile^,.Grounding)==0 {continue}
        name,_,_:=anim.modifier_definition(profile,.Grounding,0)
        anim.modifier(requests,{rig=entity,kind=.Grounding,weight=1 if core.at(found,row).standing else 0,enabled=true,goal=true},name)
    }
}
