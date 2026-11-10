package physics

import "core:testing"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

@(private="file")
Sync_Scene :: struct {holder,free_entity,wall:core.Entity}

// A floor, a stack, a character, and under an entity without a body a wall
// of colliders, a static body, a kinematic one and a dynamic compound, with an
// L of two convex pieces of its own and as a part of the compound.
@(private="file")
sync_scene :: proc(f:^Physics_Test,assets:^host.Assets,pieces:base.Asset_Id) -> (scene:Sync_Scene) {
    f.app.assets=assets
    f.settings={bodies=64,shapes=64,contacts=256,characters=2}
    f.gravity={0,-9.81,0}
    physics_test_box(f,{0,-0.5,0},{20,0.5,20},RIGID_BODY_STATIC)
    for i in 0..<4 {physics_test_box(f,{0,0.5+f32(i)*1.01,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)}
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{4,1,0},1,{1,1,1}})
    core.add(&f.colliders,walker,collider_character())
    core.add(&f.characters,walker,character_default())
    scene.free_entity=core.create(&f.entities)
    core.add(&f.transforms,scene.free_entity,core.Transform{{0,9,0},1,{1,1,1}})
    scene.holder=core.create(&f.entities)
    core.add(&f.transforms,scene.holder,core.Transform{{-6,0,0},1,{1,1,1}})
    under :: proc(f:^Physics_Test,holder:core.Entity,position:[3]f32,rigid:Maybe(Rigid_Body)) -> core.Entity {
        e:=physics_test_box(f,position,{0.4,0.4,0.4},rigid)
        core.add(&f.parents,e,core.Parent{holder,0})
        return e
    }
    scene.wall=under(f,scene.holder,{0,0.4,-3},nil)
    under(f,scene.holder,{0,0.4,3},RIGID_BODY_STATIC)
    under(f,scene.holder,{0,3,0},RIGID_BODY_KINEMATIC)
    compound:=under(f,scene.holder,{2,0.4,0},RIGID_BODY_DYNAMIC)
    under(f,compound,{0,0,1},nil)
    for parent in ([2]core.Entity{scene.holder,compound}) {
        corner:=core.create(&f.entities)
        core.add(&f.transforms,corner,core.Transform{{0,1,-1.5},1,{1,1,1}})
        core.add(&f.colliders,corner,collider_hull())
        core.add(&f.statics,corner,render.Mesh_Renderer{mesh=pieces})
        core.add(&f.parents,corner,core.Parent{parent,0})
    }
    physics_test_settle(f)
    return
}

// The sync of the sealed rows gives the simulation and the rows the sync of
// every body gives, while the editor places and while it plays: a parent
// moved and scaled, a Transform without a body, a collider moved by its own
// row. It goes only through what hangs from what was written.
@(test)
a_sync_of_the_sealed_rows_gives_what_a_sync_of_every_body_gives :: proc(t:^testing.T) {
    tests:=new([2]Physics_Test)
    defer free(tests)
    sealed,whole:=&tests[0],&tests[1]
    if !physics_test_init(t,sealed) {return}
    defer physics_test_destroy(sealed)
    if !physics_test_init(t,whole) {return}
    defer physics_test_destroy(whole)
    whole.whole=true
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=8})) {return}
    defer host.assets_destroy(&assets)
    // An L of two boxes.
    corners:[16]geom.Vec3
    for &p,i in corners {p={f32(i&1)*(i<8?0.4:0.2),f32(i>>1&1)*0.2+(i<8?0:0.2),f32(i>>2&1)*0.4}}
    sizes:=[2]u32{8,8}
    triangle:=[3]geom.Vec3{{0,0,0},{1,0,0},{0,0,1}}
    order:=[3]u32{0,2,1}
    pieces,made:=host.assets_mesh_generate(&assets,{positions=triangle[:],indices=order[:]},options={no_lods=true,hull_points=corners[:],hull_sizes=sizes[:]})
    if !testing.expect(t,made) {return}
    scene:=sync_scene(sealed,&assets,pieces)
    _=sync_scene(whole,&assets,pieces)
    for tick in 0..<80 {
        for f in ([2]^Physics_Test{sealed,whole}) {
            if tick%2==0 {
                holder:=core.get(&f.transforms,scene.holder)
                holder.position.x+=0.05
                holder.rotation=mm.quat_axis_angle({0,1,0},f32(tick)*0.01)
                if tick==40 {holder.scale={1.5,1,1.5}}
            }
            core.get(&f.transforms,scene.free_entity).position.y=9+f32(tick)*0.1
            if tick==51 {core.get(&f.transforms,scene.wall).position.y=1}
        }
        // A sync of every body leaves its scratch as it was.
        clear(&sealed.state.sealed)
        if cap(sealed.state.sealed)>0 {append(&sealed.state.sealed,Sealed_Body{})}
        dt:=f32(tick<12?0:1.0/60)
        physics_test_step(sealed,dt)
        physics_test_step(whole,dt)
        if !testing.expectf(t,sim.world_hash(&sealed.state.world)==sim.world_hash(&whole.state.world),"the simulations differ at tick %v",tick) {return}
        testing.expect_value(t,sealed.state.stats,whole.state.stats)
        for row in 0..<core.count(&whole.transforms) {
            e:=core.entity_at(&whole.transforms,row)
            pose,_:=core.get(core.read(&sealed.transforms),e)
            if !testing.expectf(t,pose==whole.transforms.values[row],"entity %v differs at tick %v",e,tick) {return}
        }
        if tick>=20 {
            through:=tick%2==0?7:(tick==51?1:0)
            testing.expectf(t,len(sealed.state.sealed)==through,"tick %v went through %v bodies, not %v",tick,len(sealed.state.sealed),through)
        }
    }
    testing.expect(t,sealed.state.stats.teleports>0 && sealed.state.stats.shapes_created>sealed.state.stats.bodies_created)
    testing.expect_value(t,sealed.problems.count,whole.problems.count)
    testing.expect_value(t,sealed.problems.count,0)
    hulls,_:=geometry_budget({&sealed.state},.Hull)
    testing.expect_value(t,hulls,2)
}
