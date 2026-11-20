package animation_physics

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

// The matching is told what the body will do: in the air, a body that lets go of the stick keeps
// its course, so the trajectory goes on and not to a stop; a sprint asks for its own speed.
@(test)
the_goal_of_a_walk_follows_what_the_character_does_on_the_ground_and_in_the_air :: proc(t:^testing.T) {
    walk:=locomotion.Walk{max_speed=8,acceleration=24,braking=40,air_control=0.8}
    going:=mm.Vec3{7,-3,0}
    cases:=[?]struct {falling:bool,wish,desired:mm.Vec3,acceleration,braking,speed:f32}{
        {false,{1,0,0},{8,0,0},24,40,8},
        {false,{},{},24,40,8},
        {true,{-1,0,0},{-8,0,0},19.2,19.2,8},
        {true,{},{7,0,0},19.2,19.2,8},
        {false,{0,0,-1},{0,0,-11},24,40,11},
    }
    for c in cases {
        desired,acceleration,braking:=walk_goal(walk,c.falling,c.wish,going,c.speed)
        testing.expectf(t,desired==c.desired && abs(acceleration-c.acceleration)<1e-4 && abs(braking-c.braking)<1e-4,"falling %v wish %v: %v %v %v",c.falling,c.wish,desired,acceleration,braking)
    }
}

@(test)
the_bridge_uses_current_motion_and_ignores_raw_clips_even_with_previous_matching :: proc(t:^testing.T) {
    entities:core.Entities
    core.entities_init(&entities)
    defer core.entities_destroy(&entities)
    actor:=core.create(&entities)
    Tables :: struct {
        bodies:core.Table(phys.Character),
        states:core.Table(locomotion.Locomotion_State),
        found:core.Table(phys.Character_State),
        animations:core.Table(anim.Animation),
        motions:core.Table(core.Motion),
        inputs:core.Table(inp.Move_Input),
        drives:core.Table(locomotion.Locomotion_Drive),
        parkours:core.Table(locomotion.Parkour_State),
        walks:core.Table(locomotion.Walk),
        tacticals:core.Table(locomotion.Tactical_Sprint),
        flights:core.Table(locomotion.Fly),
        swims:core.Table(locomotion.Swim),
        worlds:core.Table(core.World_Transform),
    }
    tables:=new(Tables)
    defer free(tables)
    core.add(&tables.bodies,actor,phys.character_default())
    core.add(&tables.states,actor,{mode=locomotion.MODE_WALKING})
    set_id:=base.Asset_Id{3,2}
    core.add(&tables.animations,actor,{asset=set_id})
    core.add(&tables.worlds,actor,{rotation=1})
    core.add(&tables.motions,actor,{linear={1,0,0}})
    core.table_settle(&tables.bodies,&entities)
    core.table_settle(&tables.states,&entities)
    core.table_settle(&tables.animations,&entities)
    core.table_settle(&tables.worlds,&entities)
    core.table_settle(&tables.motions,&entities)
    defer {
        core.table_destroy(&tables.bodies)
        core.table_destroy(&tables.states)
        core.table_destroy(&tables.animations)
        core.table_destroy(&tables.worlds)
        core.table_destroy(&tables.motions)
    }
    assets:=new(host.Assets)
    defer free(assets)
    assets.registry.by_id=make(map[base.Asset_Id]u32)
    assets.registry.by_id[set_id]=0
    append(&assets.registry.files,asset.Registry_File{id=set_id,kind=anim.CHARACTER_KIND,state=.Asset})
    defer {delete(assets.registry.by_id);delete(assets.registry.files)}
    app:=new(host.App)
    defer free(app)
    app.assets=assets
    sets:anim.Character_Assets
    defer anim.character_assets_free(&sets)
    resize(&sets.contents,1)
    sets.contents[0].id,sets.contents[0].valid=set_id,true
    sets.contents[0].set.match.clips={{modes=1}}
    playback:anim.Playback
    defer anim.playback_free(&playback)
    resize(&playback.states,1)
    playback.states[0].entity=actor
    resize(&playback.rows,core.entity_index(actor)+1)
    playback.rows[core.entity_index(actor)]=1
    playing:=&playback.states[0]
    playing.program.matched,playing.program.ready=true,true
    playing.program.match.body={1,0,0}
    playing.program.match.speed,playing.program.match.rate=1,1
    requests:anim.Animation_Requests
    defer {delete(requests.match_goals.items);delete(requests.locomotion.items)}
    for raw in ([2]bool{false,true}) {
        clear(&requests.match_goals.items);clear(&requests.locomotion.items)
        if raw {core.edit(&tables.animations,actor).asset={3,3}}
        core.edit(&tables.motions,actor).linear={3,0,2}
        animation_locomotion(core.read(&tables.bodies),core.read(&tables.states),
            core.read(&tables.found),core.read(&tables.animations),core.read(&tables.motions),
            core.read(&tables.inputs),core.read(&tables.drives),core.read(&tables.parkours),
            {},core.read(&tables.walks),core.read(&tables.tacticals),
            core.read(&tables.flights),core.read(&tables.swims),core.read(&tables.worlds),
            core.ref(&playback),{},&requests,core.ref(&sets),app)
        if raw {
            testing.expect(t,len(requests.match_goals.items)==0 && len(requests.locomotion.items)==0)
        } else if testing.expect(t,len(requests.match_goals.items)==1 &&
            len(requests.locomotion.items)==1) {
            testing.expect_value(t,requests.match_goals.items[0].velocity,mm.Vec3{3,0,2})
            testing.expect_value(t,requests.locomotion.items[0].velocity,mm.Vec3{3,0,2})
        }
    }
}
