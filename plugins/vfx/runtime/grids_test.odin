package vfx

import "core:testing"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
Grids_World :: struct {
    using world:core.Test_World,
    grids:core.Table(Particle_Grid),
    volumes:core.Table(Particle_Volume),
    textures:core.Table(Particle_World_Texture),
    worlds:core.Table(core.World_Transform),
}

@(private="file")
Grids_Fixture :: struct {
    using w:Grids_World,
    g:Grids,
    problems:core.Problems,
}

@(private="file")
grids_fixture_add :: proc(f:^Grids_Fixture,name:string) -> core.Entity {
    e:=core.create(&f.entities)
    grid:=PARTICLE_GRID_DEFAULT
    base.text_set(grid.name[:],name)
    core.add(&f.grids,e,grid)
    core.add(&f.worlds,e,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
    grids_fixture_settle(f)
    return e
}

@(private="file")
grids_fixture_settle :: proc(f:^Grids_Fixture) {core.test_world_settle(&f.w)}

@(private="file")
grids_fixture_sync :: proc(f:^Grids_Fixture) {
    grids_sync(&f.g,core.read(&f.grids),core.read(&f.volumes),core.read(&f.textures),core.read(&f.worlds),{},&f.problems)
}

// Deleting and adding grids leaves each new one with its own entity, and of
// two with one name the one that had it keeps it, whatever the order of the rows.
@(test)
grids_keep_their_entities_and_names_as_entities_come_and_go :: proc(t:^testing.T) {
    f:Grids_Fixture
    if !core.test_world_init(t,&f.w,test_types) {return}
    defer {
        grids_free(&f.g)
        core.test_world_destroy(&f.w)
    }
    plume:=grids_fixture_add(&f,"plume")
    fluid:=grids_fixture_add(&f,"fluid")
    waves:=grids_fixture_add(&f,"waves")
    grids_fixture_sync(&f)
    // A copy of the fluid, of the same name, is refused: the fluid had it.
    copy:=grids_fixture_add(&f,"fluid")
    grids_fixture_sync(&f)
    testing.expect_value(t,grid_of_entity(&f.g,fluid),grid_find(&f.g,base.name_hash("fluid")))
    testing.expect_value(t,grid_of_entity(&f.g,copy),-1)
    testing.expect(t,core.problem_find(&f.problems,copy,"vfx.grid")!=nil,"the copy is a problem of its own")
    // The fluid goes: the copy, now in its row, takes the name, as itself.
    core.destroy(&f.entities,fluid)
    grids_fixture_settle(&f)
    grids_fixture_sync(&f)
    testing.expect_value(t,len(f.g.entries),3)
    for e in ([]core.Entity{plume,copy,waves}) {
        at:=grid_of_entity(&f.g,e)
        testing.expectf(t,at>=0,"the grid of %v is among those of the world",e)
    }
    testing.expect_value(t,grid_find(&f.g,base.name_hash("fluid")),grid_of_entity(&f.g,copy))
    // Another of that name comes, before the copy among the rows: the copy keeps it.
    core.destroy(&f.entities,plume)
    grids_fixture_settle(&f)
    again:=grids_fixture_add(&f,"fluid")
    core.destroy(&f.entities,waves)
    grids_fixture_settle(&f)
    testing.expect(t,core.entity_at(&f.grids,0)==again,"the new one is in the first row")
    grids_fixture_sync(&f)
    testing.expect_value(t,grid_find(&f.g,base.name_hash("fluid")),grid_of_entity(&f.g,copy))
    testing.expect_value(t,grid_of_entity(&f.g,again),-1)
}

// A grid resource of a program reads the grid its emitter binds, by entity or
// by name; unbound, the first its stages go over is the grid of its own
// entity, and the others the grid of the world of their name.
@(test)
emitters_read_the_grids_they_bind_or_their_own :: proc(t:^testing.T) {
    f:Grids_Fixture
    if !core.test_world_init(t,&f.w,test_types) {return}
    defer {
        grids_free(&f.g)
        core.test_world_destroy(&f.w)
    }
    fluid:=grids_fixture_add(&f,"fluid")
    river:=grids_fixture_add(&f,"river")
    smoke:=grids_fixture_add(&f,"smoke")
    volume:=grids_fixture_add(&f,"volume")
    grids_fixture_sync(&f)
    sync:Particle_Sync
    sync.grids=f.g
    defer sync.grids={}
    shown:Emitter_Shown
    shown.needs.resources[0]={name=base.name_hash("fluid"),kind=.Grid}
    shown.needs.resources[1]={name=base.name_hash("volume"),kind=.Grid}
    shown.needs.stages[0]={kind=.Cells,over=0}
    shown.needs.stages[1]={kind=.Cells,over=1}
    read :: proc(sync:^Particle_Sync,shown:^Emitter_Shown,bindings:^Particle_Bindings,e:core.Entity) -> (grids:[2]int) {
        resources:=emitter_resources(sync,shown,&shown.info,nil,bindings,e,{},nil,nil,{},{},{},nil,nil)
        for &g,at in grids {g=resources[1+at].kind==.Grid?int(resources[1+at].first):-1}
        return
    }
    entry :: proc(sync:^Particle_Sync,e:core.Entity) -> int {return grid_of_entity(&sync.grids,e)}
    // Unbound, on the river: the river is what its stages go over first; the volume of the world after it.
    unbound:Particle_Bindings
    testing.expect_value(t,read(&sync,&shown,&unbound,river),[2]int{entry(&sync,river),entry(&sync,volume)})
    // On an entity without a grid: the grids of the world of their names.
    testing.expect_value(t,read(&sync,&shown,&unbound,core.NONE),[2]int{entry(&sync,fluid),entry(&sync,volume)})
    // Bound by name and by entity.
    bound:Particle_Bindings
    base.text_set(bound.sources[0].resource[:],"fluid")
    base.text_set(bound.sources[0].grid[:],"river")
    base.text_set(bound.sources[1].resource[:],"volume")
    bound.sources[1].entity=smoke
    testing.expect_value(t,read(&sync,&shown,&bound,core.NONE),[2]int{entry(&sync,river),entry(&sync,smoke)})
    // A name no grid has reads nothing: what it binds is not looked for elsewhere.
    base.text_set(bound.sources[0].grid[:],"lake")
    testing.expect_value(t,read(&sync,&shown,&bound,river)[0],-1)
}
