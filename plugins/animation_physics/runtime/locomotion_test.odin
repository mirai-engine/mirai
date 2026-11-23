package animation_physics

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import mm "mirai:std/math"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

@(private="file")
Bridge_Tables :: struct {
    states:core.Table(locomotion.Locomotion_State),
    found:core.Table(phys.Character_State),
    animations:core.Table(anim.Animation),
    motions:core.Table(core.Motion),
    mantles:core.Table(locomotion.Mantle_State),
    worlds:core.Table(core.World_Transform),
    verticals:core.Table(core.Vertical),
}

// A matching rig of a .character played by actor, with what animation_locomotion reads of it.
@(private="file")
Bridge :: struct {
    entities:core.Entities,
    tables:^Bridge_Tables,
    assets:^host.Assets,
    app:^host.App,
    sets:anim.Character_Assets,
    playback:anim.Playback,
    requests:anim.Animation_Requests,
    clips:[1]anim.Match_Source,
    actor:core.Entity,
}

@(private="file")
bridge_init :: proc(b:^Bridge,state:locomotion.Locomotion_State,velocity:mm.Vec3,up_frame:mm.Quat) {
    core.entities_init(&b.entities)
    b.actor=core.create(&b.entities)
    b.tables=new(Bridge_Tables)
    set_id:=base.Asset_Id{3,2}
    core.add(&b.tables.states,b.actor,state)
    core.add(&b.tables.animations,b.actor,{asset=set_id})
    core.add(&b.tables.worlds,b.actor,{rotation=up_frame})
    core.add(&b.tables.motions,b.actor,{linear=velocity})
    core.add(&b.tables.verticals,b.actor,{frame=up_frame})
    core.table_settle(&b.tables.states,&b.entities)
    core.table_settle(&b.tables.animations,&b.entities)
    core.table_settle(&b.tables.worlds,&b.entities)
    core.table_settle(&b.tables.motions,&b.entities)
    core.table_settle(&b.tables.verticals,&b.entities)
    b.assets=new(host.Assets)
    b.assets.registry.by_id=make(map[base.Asset_Id]u32)
    b.assets.registry.by_id[set_id]=0
    append(&b.assets.registry.files,asset.Registry_File{id=set_id,kind=anim.CHARACTER_KIND,state=.Asset})
    b.app=new(host.App)
    b.app.assets=b.assets
    resize(&b.sets.contents,1)
    b.sets.contents[0].id,b.sets.contents[0].valid=set_id,true
    b.clips[0].modes=1<<u32(state.mode)
    b.sets.contents[0].set.match.clips=b.clips[:]
    resize(&b.playback.states,1)
    b.playback.states[0].entity=b.actor
    resize(&b.playback.rows,core.entity_index(b.actor)+1)
    b.playback.rows[core.entity_index(b.actor)]=1
    playing:=&b.playback.states[0]
    playing.program.matched,playing.program.ready=true,true
    playing.program.match.body={1,0,0}
    playing.program.match.speed,playing.program.match.rate=1,1
}

@(private="file")
bridge_tick :: proc(b:^Bridge) {
    clear(&b.requests.match_goals.items);clear(&b.requests.locomotion.items)
    animation_locomotion(core.read(&b.tables.states),core.read(&b.tables.found),core.read(&b.tables.animations),core.read(&b.tables.motions),
        core.read(&b.tables.mantles),core.read(&b.tables.worlds),core.read(&b.tables.verticals),core.ref(&b.playback),{},&b.requests,core.ref(&b.sets),b.app)
}

@(private="file")
bridge_destroy :: proc(b:^Bridge) {
    delete(b.requests.match_goals.items);delete(b.requests.locomotion.items)
    anim.playback_free(&b.playback)
    b.sets.contents[0].set.match.clips=nil
    anim.character_assets_free(&b.sets)
    delete(b.assets.registry.by_id);delete(b.assets.registry.files)
    free(b.assets);free(b.app)
    core.value_free(b.tables,type_info_of(Bridge_Tables))
    free(b.tables)
    core.entities_destroy(&b.entities)
}

// On a planet, where the up of a body is +Z of the world, a walk forward is told to the matching
// along the ground of the planet: the velocity its locomotion heads to, the acceleration of its
// Walk, where it turns at its turn_speed, and to the warping the velocity of the body across that
// up. None of it loses the part along +Y of the world, which is across its up there.
@(test)
planetary_locomotion_feeds_the_matching_across_the_up_of_its_vertical :: proc(t:^testing.T) {
    up_frame:=mm.quat_axis_angle({1,0,0},math.PI/2) // its up is +Z of the world and its front +Y
    up:=mm.quat_rotate(up_frame,mm.Vec3{0,1,0})
    testing.expect(t,linalg.length(up-{0,0,1})<1e-5)
    walk:=locomotion.WALK_DEFAULT
    state:=locomotion.Locomotion_State{mode=locomotion.MODE_WALKING,speed_scale=1}
    ground:=phys.Character_State{standing=true,walkable=true,ground_normal=up}
    asked:=inp.Move_Input{move=mm.quat_rotate(up_frame,mm.Vec3{0,0,-1})}
    given:=locomotion.move_facing(asked,0,up_frame)
    _=locomotion.locomotion_move(&state,phys.character_default(),walk,{},nil,ground,up_frame,given,0,1,2,{},-up*9.81,1.0/60)
    state.facing,state.turn_speed=mm.quat_forward(up_frame),walk.turn_speed
    testing.expectf(t,linalg.length(state.desired-mm.Vec3{0,walk.max_speed,0})<1e-4,"it heads along the planet: %v",state.desired)
    b:Bridge
    bridge_init(&b,state,{0,3,1},up_frame)
    defer bridge_destroy(&b)
    bridge_tick(&b)
    if !testing.expect(t,len(b.requests.match_goals.items)==1 && len(b.requests.locomotion.items)==1) {return}
    goal:=b.requests.match_goals.items[0]
    testing.expectf(t,goal.desired==state.desired && goal.acceleration==walk.acceleration && goal.braking==walk.braking,"%v",goal)
    testing.expectf(t,linalg.length(goal.facing-mm.Vec3{0,1,0})<1e-5 && goal.turn_rate==walk.turn_speed && goal.velocity==mm.Vec3{0,3,1},"%v",goal)
    testing.expectf(t,linalg.length(b.requests.locomotion.items[0].velocity-mm.Vec3{0,3,0})<1e-5,"across its up: %v",b.requests.locomotion.items[0].velocity)
}

// The goal of a rig is the motion of this tick, and a raw clip that is no .character gets none.
@(test)
the_bridge_uses_current_motion_and_ignores_raw_clips_even_with_previous_matching :: proc(t:^testing.T) {
    b:Bridge
    bridge_init(&b,{mode=locomotion.MODE_WALKING},{1,0,0},mm.QUAT_IDENTITY)
    defer bridge_destroy(&b)
    for raw in ([2]bool{false,true}) {
        if raw {core.edit(&b.tables.animations,b.actor).asset={3,3}}
        core.edit(&b.tables.motions,b.actor).linear={3,0,2}
        bridge_tick(&b)
        if raw {
            testing.expect(t,len(b.requests.match_goals.items)==0 && len(b.requests.locomotion.items)==0)
        } else if testing.expect(t,len(b.requests.match_goals.items)==1 && len(b.requests.locomotion.items)==1) {
            testing.expect_value(t,b.requests.match_goals.items[0].velocity,mm.Vec3{3,0,2})
            testing.expect_value(t,b.requests.locomotion.items[0].velocity,mm.Vec3{3,0,2})
        }
    }
}
