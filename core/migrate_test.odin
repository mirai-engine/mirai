package core

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file") Before_Spin :: struct {speed:f32,axis:[3]f32}
@(private="file") After_Spin :: struct {axis:[3]f32,turns:i32,speed:f64}
@(private="file") Kept_Tag :: struct {value:u32}
@(private="file") Added_Tag :: struct {value:u32}
@(private="file") Before_Score :: struct {points:i32}
@(private="file") After_Score :: struct {lives:u8,points:i64}

@(private="file")
Before_World :: struct {
    entities:Entities,
    spin:Table(Before_Spin),
    kept:Table(Kept_Tag),
    score:Before_Score,
}

@(private="file")
After_World :: struct {
    entities:Entities,
    kept:Table(Kept_Tag),
    added:Table(Added_Tag),
    spin:Table(After_Spin),
    score:After_Score,
}

@(private="file")
before_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Before_World)data
    entities_init(&w.entities,allocator) or_return
    table_init(&w.spin,"Spin",allocator)
    table_init(&w.kept,"Kept_Tag",allocator)
    entities_tables(&w.entities,2) or_return
    table_follow(&w.spin,&w.entities,0);table_follow(&w.kept,&w.entities,1)
    return true
}

@(private="file")
before_destroy :: proc(data:rawptr) {
    w:=cast(^Before_World)data
    entities_destroy(&w.entities)
    table_destroy(&w.spin)
    table_destroy(&w.kept)
}

@(private="file")
after_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^After_World)data
    entities_init(&w.entities,allocator) or_return
    table_init(&w.kept,"Kept_Tag",allocator)
    table_init(&w.added,"Added_Tag",allocator)
    table_init(&w.spin,"Spin",allocator)
    entities_tables(&w.entities,3) or_return
    table_follow(&w.kept,&w.entities,0);table_follow(&w.added,&w.entities,1);table_follow(&w.spin,&w.entities,2)
    w.score.lives=3
    return true
}

@(private="file")
after_destroy :: proc(data:rawptr) {
    w:=cast(^After_World)data
    entities_destroy(&w.entities)
    table_destroy(&w.kept)
    table_destroy(&w.added)
    table_destroy(&w.spin)
}

@(private="file")
spin_default :: proc(dst:rawptr) {(cast(^After_Spin)dst)^={turns=7}}

@(test)
a_world_migrates_to_another_layout_by_names :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    allocator:=mem.tracking_allocator(&tracking)
    context.allocator=allocator

    before:World_Info
    before.sizes[.World],before.aligns[.World]=size_of(Before_World),align_of(Before_World)
    before.entities=offset_of(Before_World,entities)
    before_tables:=[]Table_Info{
        {name="Spin",type=Before_Spin,info=type_info_of(Before_Spin),offset=offset_of(Before_World,spin)},
        {name="Kept_Tag",type=Kept_Tag,info=type_info_of(Kept_Tag),offset=offset_of(Before_World,kept)},
    }
    before_storages:=[]Storage_Info{{name="Score",type=Before_Score,info=type_info_of(Before_Score),offset=offset_of(Before_World,score)}}
    before.tables,before.storages=before_tables,before_storages
    before.init[.World],before.destroy[.World]=before_init,before_destroy

    after:World_Info
    after.sizes[.World],after.aligns[.World]=size_of(After_World),align_of(After_World)
    after.entities=offset_of(After_World,entities)
    after_tables:=[]Table_Info{
        {name="Kept_Tag",type=Kept_Tag,info=type_info_of(Kept_Tag),offset=offset_of(After_World,kept)},
        {name="Added_Tag",type=Added_Tag,info=type_info_of(Added_Tag),offset=offset_of(After_World,added)},
        {name="Spin",type=After_Spin,info=type_info_of(After_Spin),offset=offset_of(After_World,spin),default=spin_default},
    }
    after_storages:=[]Storage_Info{{name="Score",type=After_Score,info=type_info_of(After_Score),offset=offset_of(After_World,score)}}
    after.tables,after.storages=after_tables,after_storages
    after.init[.World],after.destroy[.World]=after_init,after_destroy

    old:=new(Before_World)
    testing.expect(t,before_init(old,allocator))
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
    testing.expect(t,after_init(fresh,allocator))
    place_migrate(&m,.World,old,fresh,allocator)
    before_destroy(old)
    mem.free(old)

    testing.expect(t,fresh.entities.alive==2,"The entities move")
    spin:=get(read(&fresh.spin),a) or_else After_Spin{}
    testing.expect(t,spin.speed==2.5 && spin.axis=={0,1,0} && spin.turns==7,"A field takes its value by name; a new one its default")
    other:=get(read(&fresh.spin),b) or_else After_Spin{}
    testing.expect(t,other.speed==-1)
    kept:=get(read(&fresh.kept),b) or_else Kept_Tag{}
    testing.expect(t,kept.value==42 && !has(&fresh.kept,a),"A table of the same layout moves")
    testing.expect(t,count(&fresh.added)==0)
    testing.expect(t,fresh.score.points==1234 && fresh.score.lives==3,"A storage converts over what the new library starts it with")
    // The table takes rows again with the new type.
    c:=create(&fresh.entities)
    add(&fresh.spin,c,After_Spin{speed=9})
    // It says that it waits where the new World looks for it, not where the old one did.
    testing.expect(t,fresh.entities.pending[2] && !fresh.entities.pending[0] && !fresh.entities.pending[1])
    testing.expect(t,table_settle(&fresh.spin,&fresh.entities))
    testing.expect(t,(get(read(&fresh.spin),c) or_else After_Spin{}).speed==9)
    after_destroy(fresh)
    mem.free(fresh)
    world_migration_destroy(&m)
    testing.expect_value(t,len(tracking.allocation_map),0)
}

@(private="file") Test_Action :: distinct u8
@(private="file") Aim_Tag :: struct {action:Test_Action}

@(private="file")
Aim_World :: struct {
    entities:Entities,
    aim:Table(Aim_Tag),
    kept:Table(Kept_Tag),
}

@(private="file")
aim_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Aim_World)data
    entities_init(&w.entities,allocator) or_return
    table_init(&w.aim,"Aim_Tag",allocator)
    table_init(&w.kept,"Kept_Tag",allocator)
    return true
}

@(private="file")
aim_destroy :: proc(data:rawptr) {
    w:=cast(^Aim_World)data
    entities_destroy(&w.entities)
    table_destroy(&w.aim)
    table_destroy(&w.kept)
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

    tables:=[]Table_Info{
        {name="Aim_Tag",type=Aim_Tag,info=type_info_of(Aim_Tag),offset=offset_of(Aim_World,aim)},
        {name="Kept_Tag",type=Kept_Tag,info=type_info_of(Kept_Tag),offset=offset_of(Aim_World,kept)},
    }
    types:=[]Named_Type_Info{{type=Test_Action,name="Test_Action",path="mirai:core",actions=true}}
    world :: proc(tables:[]Table_Info,types:[]Named_Type_Info,names:[]Name_Info) -> (info:World_Info) {
        info.sizes[.World],info.aligns[.World]=size_of(Aim_World),align_of(Aim_World)
        info.entities=offset_of(Aim_World,entities)
        info.tables,info.named_types,info.names=tables,types,names
        info.init[.World],info.destroy[.World]=aim_init,aim_destroy
        return
    }
    before:=world(tables,types,{{type=Test_Action,value=0,name="jump"},{type=Test_Action,value=1,name="aim"}})
    moved:=world(tables,types,{{type=Test_Action,value=0,name="crouch"},{type=Test_Action,value=1,name="jump"},{type=Test_Action,value=2,name="aim"}})
    renamed:=world(tables,types,{{type=Test_Action,value=0,name="jump"},{type=Test_Action,value=1,name="point"}})

    m:World_Migration
    testing.expect(t,world_migration_make(&m,&before,&moved))
    testing.expect(t,.World in m.places)
    testing.expect(t,m.tables[0]==.Convert && m.tables[1]==.Move)
    old:=new(Aim_World)
    testing.expect(t,aim_init(old,allocator))
    a:=create(&old.entities)
    add(&old.aim,a,Aim_Tag{1})
    testing.expect(t,table_settle(&old.aim,&old.entities))
    fresh:=new(Aim_World)
    testing.expect(t,aim_init(fresh,allocator))
    place_migrate(&m,.World,old,fresh,allocator)
    testing.expect_value(t,(get(read(&fresh.aim),a) or_else Aim_Tag{}).action,Test_Action(2))
    aim_destroy(old);mem.free(old)
    aim_destroy(fresh);mem.free(fresh)
    world_migration_destroy(&m)

    testing.expect(t,world_migration_make(&m,&before,&renamed))
    testing.expect(t,m.places=={} && m.tables[0]==.Move)
    world_migration_destroy(&m)
    testing.expect_value(t,len(tracking.allocation_map),0)
}
