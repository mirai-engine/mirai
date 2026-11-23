package game

import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/ai"
import anim "plugins:animation/runtime"
import behavior "plugins:behavior/runtime"
import locomotion "plugins:locomotion/runtime"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

@(private)
@(test_world)
Arena_World :: struct {
    using world:Test_World,
    arenas:core.Table(AI_Arena),
    built:core.Table(AI_Arena_State),
    worlds:core.Table(core.World_Transform),
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    characters:core.Table(phys.Character),
    colliders:core.Table(phys.Collider),
    walks:core.Table(locomotion.Walk),
    nav_agents:core.Table(nav.Nav_Agent),
    meshes:core.Table(render.Mesh_Renderer),
    materials:core.Table(render.Material_Values),
    patrols:core.Table(behavior.Patrol),
    perceivers:core.Table(behavior.Perceiver),
    perceivables:core.Table(behavior.Perceivable),
    minds:core.Table(behavior.Mind_Agent),
    animations:core.Table(anim.Animation),
    zombies:core.Table(Zombie),
}

// An arena is built once: the ticks after the first add no agents, though nothing writes the
// AI_Arena that the scene authored.
@(test)
an_arena_builds_its_agents_once :: proc(t:^testing.T) {
    w:=new(Arena_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    commands:=core.commands(w,test_world_info(w))
    arena:=core.create(&w.entities)
    core.add(&w.arenas,arena,AI_Arena{kind=.Horde,agents=4})
    test_world_settle(w)
    for tick in u64(1)..=3 {
        arena_build(commands,core.read(&w.arenas),&w.built,core.read(&w.worlds),{tick=tick,dt=1.0/60,playing=true},nil)
        test_world_settle(w)
        testing.expectf(t,core.count(&w.zombies)==4 && core.count(&w.characters)==5,"after tick %d: %d zombies and %d characters, want 4 and 5 (the runner)",tick,core.count(&w.zombies),core.count(&w.characters))
        testing.expect(t,core.has(&w.built,arena))
    }
}

@(test)
a_zombie_closes_in_to_bite_while_a_place_is_free_and_circles_when_none_is :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    worlds:core.Table(core.World_Transform);perceptions:core.Table(behavior.Perception)
    perceivables:core.Table(behavior.Perceivable);agents:core.Table(nav.Nav_Agent)
    defer {core.table_destroy(&worlds);core.table_destroy(&perceptions);core.table_destroy(&perceivables);core.table_destroy(&agents)}
    zombie,runner:=core.create(&es),core.create(&es)
    core.add(&worlds,zombie,core.World_Transform{})
    core.add(&worlds,runner,core.World_Transform{})
    core.add(&perceptions,zombie,behavior.Perception{})
    core.table_settle(&worlds,&es);core.table_settle(&perceptions,&es)
    ai.memory_perceive(&core.edit(&perceptions,zombie).memory,u64(runner),{},.Sight,1,0)
    core.table_settle(&perceptions,&es)
    w:=Arena{core.read(&worlds),core.read(&perceptions),core.read(&perceivables),core.read(&agents)}
    cases:=[]struct{distance:f32,taken:int,want:Zombie_Act}{
        {3,0,.Chase},              // within circling distance, a place free: on to bite
        {1,ZOMBIE_BITERS-1,.Bite}, // the last place
        {1,ZOMBIE_BITERS,.Circle}, // every place taken
        {3,ZOMBIE_BITERS,.Circle},
        {10,0,.Chase},
    }
    for c in cases {
        core.edit(&worlds,runner).position={c.distance,0,0}
        core.table_settle(&worlds,&es)
        places:ai.Reservations
        for k in 0..<c.taken {testing.expect(t,ai.reserve_take(&places,{u64(runner),0},u64(1000+k),ZOMBIE_BITERS,1))}
        ctx:=ai.Mind_Context{tick=1,dt=1.0/60,holder=u64(zombie),reservations=&places}
        mind:ai.Mind
        think:=ai.Think(Zombie_Act){ctx=&ctx,mind=&mind,best=-1,running=-1,excluded=-1}
        zombie_think(&think,w)
        testing.expectf(t,think.best==int(c.want),"at %v m with %d places taken: %v, want %v",c.distance,c.taken,Zombie_Act(think.best),c.want)
    }
}
