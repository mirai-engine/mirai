package core

import "base:runtime"
import "core:mem"
import "core:testing"

@(private) Before_Spin :: struct {speed:f32,axis:[3]f32}
@(private) After_Spin :: struct {axis:[3]f32,turns:i32,speed:f64}
@(private) Kept_Tag :: struct {value:u32}
@(private) Added_Tag :: struct {value:u32}
@(private) Before_Score :: struct {points:i32}
@(private) After_Score :: struct {lives:u8,points:i64}
@(private) AFTER_SPIN_DEFAULT :: After_Spin{turns=7}
@(private) AFTER_SCORE_DEFAULT :: After_Score{lives=3}

@(private)
@(test_world)
Before_World :: struct {
    using world:Test_World,
    spin:Table(Before_Spin) `mirai:"name=Spin"`,
    kept:Table(Kept_Tag),
    score:Before_Score `mirai:"name=Score"`,
}

@(private)
@(test_world)
After_World :: struct {
    using world:Test_World,
    kept:Table(Kept_Tag),
    added:Table(Added_Tag),
    spin:Table(After_Spin) `mirai:"name=Spin"`,
    score:After_Score `mirai:"name=Score"`,
}

@(test)
a_world_migrates_to_another_layout_by_names :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    allocator:=mem.tracking_allocator(&tracking)
    context.allocator=allocator

    before,before_ok:=test_info(t,Before_World)
    after,after_ok:=test_info(t,After_World)
    if !before_ok || !after_ok {return}

    old:=new(Before_World)
    testing.expect(t,world_init(&before,.World,old,allocator))
    a,b:=create(&old.entities),create(&old.entities)
    add(&old.spin,a,Before_Spin{speed=2.5,axis={0,1,0}})
    add(&old.spin,b,Before_Spin{speed=-1,axis={1,0,0}})
    add(&old.kept,b,Kept_Tag{42})
    testing.expect(t,table_settle(&old.spin,&old.entities))
    testing.expect(t,table_settle(&old.kept,&old.entities))
    old.score.points=1234

    m:World_Migration
    testing.expect(t,world_migration_make(&m,&before,&after))
    testing.expect(t,.World in m.places)
    testing.expect(t,m.tables[0]==.Move && m.tables[1]==.New && m.tables[2]==.Convert)
    testing.expect(t,m.table_map[0]==2 && m.table_map[1]==0 && !world_migration_keeps_indices(&m))

    fresh:=new(After_World)
    testing.expect(t,world_init(&after,.World,fresh,allocator))
    place_migrate(&m,.World,old,fresh,allocator)
    world_destroy(&before,.World,old)
    mem.free(old)

    testing.expect(t,fresh.entities.alive==2,"The entities move")
    spin:=get(&fresh.spin,a) or_else After_Spin{}
    testing.expect(t,spin.speed==2.5 && spin.axis=={0,1,0} && spin.turns==7,"A field takes its value by name; a new one its default")
    other:=get(&fresh.spin,b) or_else After_Spin{}
    testing.expect(t,other.speed==-1)
    kept:=get(&fresh.kept,b) or_else Kept_Tag{}
    testing.expect(t,kept.value==42 && !has(&fresh.kept,a),"A table of the same layout moves")
    testing.expect(t,count(&fresh.added)==0)
    testing.expect(t,fresh.score.points==1234 && fresh.score.lives==3,"A storage converts over what the new library starts it with")
    // The table takes rows again with the new type.
    c:=create(&fresh.entities)
    add(&fresh.spin,c,After_Spin{speed=9})
    // It says that it waits where the new World looks for it, not where the old one did.
    testing.expect(t,fresh.entities.pending[2] && !fresh.entities.pending[0] && !fresh.entities.pending[1])
    testing.expect(t,table_settle(&fresh.spin,&fresh.entities))
    testing.expect(t,(get(&fresh.spin,c) or_else After_Spin{}).speed==9)
    world_destroy(&after,.World,fresh)
    mem.free(fresh)
    world_migration_destroy(&m)
    test_info_destroy(&before)
    test_info_destroy(&after)
    testing.expect_value(t,len(tracking.allocation_map),0)
}

@(private) Test_Action :: distinct u8
@(private) Aim_Tag :: struct {action:Test_Action}

@(private)
@(test_world)
Aim_World :: struct {
    using world:Test_World,
    aim:Table(Aim_Tag),
    kept:Table(Kept_Tag),
}

// A library that gives an action another number converts what holds actions,
// which keeps each by name; one that only renames an action moves them as they are.
@(test)
a_world_keeps_its_actions_by_name_when_their_numbers_move :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    allocator:=mem.tracking_allocator(&tracking)
    context.allocator=allocator

    before,ok:=test_info(t,Aim_World)
    if !ok {return}
    before.named_types={{type=Test_Action,name="Test_Action",path="mirai:core",actions=true}}
    moved,renamed:=before,before
    before.names={{type=Test_Action,value=0,name="jump"},{type=Test_Action,value=1,name="aim"}}
    moved.names={{type=Test_Action,value=0,name="crouch"},{type=Test_Action,value=1,name="jump"},{type=Test_Action,value=2,name="aim"}}
    renamed.names={{type=Test_Action,value=0,name="jump"},{type=Test_Action,value=1,name="point"}}

    m:World_Migration
    testing.expect(t,world_migration_make(&m,&before,&moved))
    testing.expect(t,.World in m.places)
    testing.expect(t,m.tables[0]==.Convert && m.tables[1]==.Move)
    old:=new(Aim_World)
    testing.expect(t,world_init(&before,.World,old,allocator))
    a:=create(&old.entities)
    add(&old.aim,a,Aim_Tag{1})
    testing.expect(t,table_settle(&old.aim,&old.entities))
    fresh:=new(Aim_World)
    testing.expect(t,world_init(&before,.World,fresh,allocator))
    place_migrate(&m,.World,old,fresh,allocator)
    testing.expect_value(t,(get(&fresh.aim,a) or_else Aim_Tag{}).action,Test_Action(2))
    world_destroy(&before,.World,old);mem.free(old)
    world_destroy(&before,.World,fresh);mem.free(fresh)
    world_migration_destroy(&m)

    testing.expect(t,world_migration_make(&m,&before,&renamed))
    testing.expect(t,m.places=={} && m.tables[0]==.Move)
    world_migration_destroy(&m)
    test_info_destroy(&before)
    testing.expect_value(t,len(tracking.allocation_map),0)
}
