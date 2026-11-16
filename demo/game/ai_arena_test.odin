package game

import "core:testing"
import "mirai:core"
import "mirai:std/ai"
import behavior "plugins:behavior/runtime"
import nav "plugins:navigation/runtime"

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
