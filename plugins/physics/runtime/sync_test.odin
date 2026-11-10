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
                holder:=core.edit(&f.transforms,scene.holder)
                holder.position.x+=0.05
                holder.rotation=mm.quat_axis_angle({0,1,0},f32(tick)*0.01)
                if tick==40 {holder.scale={1.5,1,1.5}}
            }
            core.edit(&f.transforms,scene.free_entity).position.y=9+f32(tick)*0.1
            if tick==51 {core.edit(&f.transforms,scene.wall).position.y=1}
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

@(private="file")
Back_Scene :: struct {stack:[3]core.Entity,kicked,rider,placed,wall,carried,ghost:core.Entity}

@(private="file")
back_scene :: proc(f:^Physics_Test) -> (scene:Back_Scene) {
    f.settings={bodies=32,shapes=32,contacts=256,characters=2}
    f.gravity={0,-9.81,0}
    physics_test_box(f,{0,-0.5,0},{20,0.5,20},RIGID_BODY_STATIC)
    for &e,i in scene.stack {e=physics_test_box(f,{0,0.5+f32(i)*1.01,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)}
    scene.kicked=physics_test_box(f,{3,0.5,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    // A body under a body: its Transform is taken under the one of its parent, as the order of the links leaves it.
    scene.rider=physics_test_box(f,{0,1.2,0},{0.2,0.2,0.2},RIGID_BODY_DYNAMIC)
    core.add(&f.parents,scene.rider,core.Parent{scene.kicked,0})
    scene.placed=physics_test_box(f,{6,0.5,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    scene.wall=physics_test_box(f,{-3,1,0},{0.2,1,1})
    // Once carried it keeps its velocity, and pushes the stack.
    scene.carried=physics_test_box(f,{-6,1,0},{0.5,0.5,0.5},RIGID_BODY_KINEMATIC)
    scene.ghost=core.create(&f.entities)
    core.add(&f.transforms,scene.ghost,core.Transform{{3,0.5,0},1,{1,1,1}})
    // While an entity has a target the bodies that move are grouped.
    beacon:=core.create(&f.entities)
    core.add(&f.transforms,beacon,core.Transform{{0,20,0},1,{1,1,1}})
    core.add(&f.replicas,beacon,core.Pose_Target{position={0,20,0},rotation=1,scale={1,1,1}})
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{9,1,0},1,{1,1,1}})
    core.add(&f.colliders,walker,collider_character())
    core.add(&f.characters,walker,character_default())
    physics_test_settle(f)
    return
}

// What a tick does to the bodies besides stepping them; the time of the step.
@(private="file")
back_tick :: proc(f:^Physics_Test,scene:Back_Scene,tick:int) -> (dt:f32) {
    dt=1.0/60
    switch {
    case tick>=40 && tick<70:   move_kinematic(&f.requests,scene.carried,{-6+f32(tick-39)*0.05,1,0})
    case tick==100:
        // Asleep, its center of mass moves.
        collider:=collider_box({0.5,0.5,0.5})
        collider.center={0,0,0.1}
        core.add(&f.colliders,scene.stack[1],collider)
    case tick==120:             set_velocity(&f.requests,scene.placed,{0,2,0})
    // Left at rest while it moves: asleep without a step.
    case tick==125:             core.add(&f.replicas,scene.placed,core.Pose_Target{placed=1,rest=true,position={6,0.5,2},rotation=1,scale={1,1,1}})
    case tick==150:             _=proxy_set(&f.state,scene.ghost,body_of(core.ref(&f.state),scene.kicked),{3,0.5,0},1)
    case tick>=160 && tick<180: manipulation_target(&f.requests,scene.wall,{-3+f32(tick-159)*0.02,1,0})
    case tick==180:             manipulation_end(&f.requests,scene.wall)
    case tick==210:             set_velocity(&f.requests,scene.kicked,{0,3,0})
    case tick>=260 && tick<280: core.add(&f.replicas,scene.placed,core.Pose_Target{follow=true,placed=1,rest=true,position={6,0.5+f32(tick-259)*0.05,2},rotation=1,scale={1,1,1}})
    case tick==280:             core.remove(&f.replicas,scene.placed)
    case tick==330:             core.add(&f.colliders,scene.stack[1],collider_box({0.5,0.5,0.3}))
    case tick==335:             core.add(&f.rigids,scene.stack[2],RIGID_BODY_STATIC)
    case tick==340:             proxy_remove(&f.state,scene.ghost)
    case tick==345:
        // The editor places a body while nothing is stepped.
        core.edit(&f.transforms,scene.stack[0]).position.x=1
        dt=0
    case tick==350:             apply_impulse(&f.requests,scene.stack[0],{0,2,0})
    case tick==400:             teleport(&f.requests,scene.kicked,{3,4,0})
    }
    return
}

@(private="file")
rows_same :: proc(t:^testing.T,a,b:^core.Table($T),what:string,tick:int) -> bool {
    if !testing.expectf(t,core.count(a)==core.count(b),"%v %s rows and %v at tick %v",core.count(a),what,core.count(b),tick) {return false}
    for row in 0..<core.count(a) {
        e:=core.entity_at(a,row)
        if !testing.expectf(t,e==core.entity_at(b,row) && a.values[row]==b.values[row],"the %s of %v differs at tick %v: %v and %v",what,e,tick,a.values[row],b.values[row]) {return false}
    }
    return true
}

// The step brings back the rows of the bodies it moved or woke and of the links something else changed. They
// are the rows a walk of every link brings back, tick by tick: of bodies that fall asleep, that a request, a
// target or a manipulation moves or leaves at rest, that change while asleep or while nothing is stepped, of a
// body under another, of a proxy and of a character.
@(test)
the_rows_of_what_moved_are_those_a_walk_of_every_link_brings_back :: proc(t:^testing.T) {
    tests:=new([2]Physics_Test)
    defer free(tests)
    moved,walked:=&tests[0],&tests[1]
    if !physics_test_init(t,moved) {return}
    defer physics_test_destroy(moved)
    if !physics_test_init(t,walked) {return}
    defer physics_test_destroy(walked)
    scene:=back_scene(moved)
    _=back_scene(walked)
    for tick in 0..<460 {
        dt:f32
        for f in ([2]^Physics_Test{moved,walked}) {
            dt=back_tick(f,scene,tick)
            physics_test_settle(f)
            physics_pose_targets(&f.state,core.read(&f.replicas),&f.transforms,core.read(&f.parents),core.read(&f.rigids),core.read(&f.characters))
            walked.state.touched_all=true
            physics_test_run(f,dt)
            physics_test_settle(f)
        }
        if !testing.expectf(t,sim.world_hash(&moved.state.world)==sim.world_hash(&walked.state.world),"the simulations differ at tick %v",tick) {return}
        if !rows_same(t,&moved.transforms,&walked.transforms,"Transform",tick) || !rows_same(t,&moved.bodies,&walked.bodies,"Motion",tick) || !rows_same(t,&moved.character_states,&walked.character_states,"Character_State",tick) {return}
        if tick==99 {
            asleep:=!sim.body_is_awake(&moved.state.world,body_of(core.ref(&moved.state),scene.stack[2]))
            testing.expect(t,asleep && !moved.state.touched_all && cap(moved.state.touched)>0 && len(moved.state.touched)==0,"the stack sleeps, and no link waits to be written")
        }
    }
    testing.expect_value(t,moved.problems.count,walked.problems.count)
    testing.expect_value(t,moved.problems.count,0)
    testing.expect(t,core.has(core.read(&moved.bodies),scene.ghost),"the proxy got the Motion of its body")
}
