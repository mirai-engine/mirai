package volume

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(private="file")
Level :: struct {value:f32}

@(private="file")
mix_level :: proc(value:^Level,by:Level,weight:f32,add:bool) {mix_linear(&value.value,by.value,weight,add)}

@(private="file")
Fixture :: struct {
    using world:core.Test_World,
    volumes:core.Table(Volume),
    worlds:core.Table(core.World_Transform),
    levels:core.Table(Level),
}

@(private="file")
place :: proc(f:^Fixture,level:f32,v:Maybe(Volume),position:[3]f32={},scale:f32=1) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.levels,e,Level{level})
    if v,ok:=v.?;ok {core.add(&f.volumes,e,v)}
    core.add(&f.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale=scale}})
    core.test_world_settle(f)
    return e
}

@(private="file")
level_at :: proc(f:^Fixture,point:[3]f32) -> f32 {
    return at(core.read(&f.volumes),core.read(&f.worlds),core.read(&f.levels),point,Level{1},mix_level).value
}

// The level at a point through an index, as a library that asks at many
// points: the base where no bounded volume holds it.
@(private="file")
level_indexed :: proc(f:^Fixture,ix:^Index,point:[3]f32) -> f32 {
    levels:=core.read(&f.levels)
    of :: proc(levels:core.Read(Level),row:i32) -> Level {return core.at(levels,int(row))}
    h,_:=index_hits(ix,point)
    return combine(h,Level{1},levels,of,mix_level).value
}

// Without a Volume the value rules the world; a box replaces it inside and
// fades over its blend; a smaller box of the same priority goes on top.
// What the shapes make, and an Unbounded volume with extents is a problem once.
@(test)
the_shapes_are_as_their_constructors_say_and_a_world_volume_with_extents_is_reported :: proc(t:^testing.T) {
    testing.expect_value(t,box({1,2,3},0.5),Volume{shape=.Box,extents={1,2,3},blend=0.5})
    testing.expect_value(t,sphere(4),Volume{shape=.Sphere,extents={4,0,0}})
    testing.expect_value(t,world(),Volume{})
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    check:Volume_Check
    problems:core.Problems
    place(&f,1,box({1,1,1}))
    volumes_check(core.read(&f.volumes),&check,&problems)
    testing.expect_value(t,problems.count,0)
    e:=place(&f,2,Volume{extents={4,4,4}})
    volumes_check(core.read(&f.volumes),&check,&problems)
    volumes_check(core.read(&f.volumes),&check,&problems)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,e,"volume.unbounded_extents")!=nil && problems.entries[0].count==1)
}

@(test)
a_box_replaces_the_level_inside_and_fades_at_its_border :: proc(t:^testing.T) {
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    testing.expect_value(t,level_at(&f,{}),1)
    place(&f,2,nil)
    testing.expect_value(t,level_at(&f,{}),2)
    place(&f,10,Volume{shape=.Box,extents={4,4,4},blend=2})
    testing.expect_value(t,level_at(&f,{}),10)
    testing.expect_value(t,level_at(&f,{3,0,0}),6)
    testing.expect_value(t,level_at(&f,{5,0,0}),2)
    place(&f,20,Volume{shape=.Box,extents={1,1,1}})
    testing.expect_value(t,level_at(&f,{}),20)
    testing.expect_value(t,level_at(&f,{1.5,0,0}),10)
}

// A bounded volume under an unbounded one of higher priority stays under it;
// one that adds goes on top of what is below.
@(test)
priority_orders_bounded_and_unbounded_and_add_sums :: proc(t:^testing.T) {
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    place(&f,5,Volume{shape=.Sphere,extents={2,0,0}})
    place(&f,3,Volume{shape=.Unbounded,priority=1})
    testing.expect_value(t,level_at(&f,{}),3)
    testing.expect_value(t,level_at(&f,{10,0,0}),3)
    place(&f,4,Volume{shape=.Sphere,extents={1,0,0},priority=2,mode=.Add},position={0,0,0},scale=2)
    testing.expect_value(t,level_at(&f,{1.5,0,0}),7)
    testing.expect_value(t,level_at(&f,{2.5,0,0}),3)
}

// An unbounded volume of a section rules in the box of the section, and
// nowhere while that box has no size.
@(test)
an_unbounded_volume_of_a_section_rules_in_its_box :: proc(t:^testing.T) {
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    section:=core.create(&f.entities)
    core.add(&f.worlds,section,core.World_Transform{transform={position={100,0,0},rotation=1,scale=1}})
    core.test_world_settle(&f)
    place(&f,9,Volume{shape=.Unbounded,scope=section,scope_extents={10,10,10}})
    testing.expect_value(t,level_at(&f,{100,0,0}),9)
    testing.expect_value(t,level_at(&f,{0,0,0}),1)
    core.edit(&f.volumes,core.entity_at(&f.volumes,0)).scope_extents={}
    testing.expect_value(t,level_at(&f,{100,0,0}),1)
}

// Overlapping volumes of several priorities give through the index what
// they give gathered one by one, at points inside, across borders and
// outside; a turned box is found where it is, not where its axes would be.
@(test)
the_index_finds_overlapping_volumes_by_priority_as_a_pass_over_them :: proc(t:^testing.T) {
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    ix:Index;defer index_destroy(&ix)
    place(&f,2,nil)
    place(&f,3,Volume{shape=.Unbounded,priority=5,mode=.Add})
    place(&f,10,Volume{shape=.Box,extents={4,4,4},blend=2})
    place(&f,20,Volume{shape=.Box,extents={1,1,1}},position={1,0,0})
    place(&f,40,Volume{shape=.Sphere,extents={3,0,0},priority=7},position={20,0,0})
    place(&f,-6,Volume{shape=.Sphere,extents={2,0,0},priority=6,mode=.Add,blend=1},position={21,0,0})
    turned:=place(&f,7,Volume{shape=.Box,extents={10,1,1},priority=1},position={-30,0,0})
    core.edit(&f.worlds,turned).rotation=mm.quat_axis_angle({0,0,1},mm.PI/2)
    changed,ok:=index_update(&ix,core.read(&f.volumes),core.read(&f.worlds),core.read(&f.levels))
    testing.expect(t,changed && ok)
    points:=[?][3]f32{{},{0.5,0,0},{1.5,0,0},{3,0,0},{4.5,0,0},{19,0,0},{21,0,0},{22.5,0,0},{24,0,0},{-30,8,0},{-38,0,0},{100,100,100}}
    for p in points {
        testing.expectf(t,level_indexed(&f,&ix,p)==level_at(&f,p),"at %v: %v indexed, %v gathered",p,level_indexed(&f,&ix,p),level_at(&f,p))
    }
    testing.expect_value(t,level_indexed(&f,&ix,{-30,8,0}),f32(10))
    testing.expect_value(t,level_indexed(&f,&ix,{-38,0,0}),f32(5))
}

// The index is made again only when a volume, a value or one of their places
// changes; something else that moves leaves it as it was. Without bounded
// volumes every point gets the unbounded ones alone: the value combined once.
@(test)
the_index_is_made_again_only_when_its_volumes_change :: proc(t:^testing.T) {
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    ix:Index;defer index_destroy(&ix)
    update :: proc(f:^Fixture,ix:^Index) -> bool {
        changed,_:=index_update(ix,core.read(&f.volumes),core.read(&f.worlds),core.read(&f.levels))
        return changed
    }
    place(&f,2,nil)
    place(&f,4,Volume{shape=.Unbounded,priority=1,mode=.Add})
    testing.expect(t,update(&f,&ix))
    testing.expect(t,!update(&f,&ix),"nothing changed")
    for p in ([?][3]f32{{},{1000,-50,3},{-7,7,7}}) {
        h,bounded:=index_hits(&ix,p)
        testing.expect(t,!bounded && h.count==2,"without bounded volumes a point has the unbounded ones")
    }
    testing.expect_value(t,level_indexed(&f,&ix,{5,5,5}),f32(6))

    other:=core.create(&f.entities)
    core.add(&f.worlds,other,core.World_Transform{transform={rotation=1,scale=1}})
    core.test_world_settle(&f)
    core.edit(&f.worlds,other).position={3,0,0}
    testing.expect(t,!update(&f,&ix),"what moves is not one of its volumes")
    zone:=place(&f,10,Volume{shape=.Box,extents={1,1,1},priority=2})
    testing.expect(t,update(&f,&ix),"a volume came")
    testing.expect_value(t,level_indexed(&f,&ix,{}),f32(10))
    core.edit(&f.worlds,zone).position={5,0,0}
    testing.expect(t,update(&f,&ix),"a volume moved")
    testing.expect_value(t,level_indexed(&f,&ix,{}),f32(6))
    testing.expect_value(t,level_indexed(&f,&ix,{5,0,0}),f32(10))
}

// The depth of a point in a box of a scale that mirrors it is measured with
// the size of the box, as its weight.
@(test)
a_mirrored_box_holds_what_is_inside_it :: proc(t:^testing.T) {
    pose:=mm.Transform{position={2,0,0},rotation=1,scale={-2,1,1}}
    v:=Volume{shape=.Box,extents={1,1,1}}
    testing.expect_value(t,depth(v,pose,{3.5,0,0}),f32(0.5))
    testing.expect(t,depth(v,pose,{4.5,0,0})<0)
    testing.expect_value(t,weight(v,pose,{3.5,0,0}),f32(1))
}

// Far from the centre of the world, a volume for a shader whose places are
// relative to the origin of the renderer finds the place of a point in it as
// the world does, and the winds move with it.
@(test)
a_volume_relative_to_the_origin_keeps_where_it_is :: proc(t:^testing.T) {
    pose:=mm.Transform{position={20000.5,3,-15000.25},rotation=mm.quat_axis_angle({0,1,0},0.7),scale=1}
    g:=gpu_volume(Volume{shape=.Box,extents={2,1,3}},pose)
    origin:=[3]f32{20480,0,-14336}
    relative:=gpu_volume_relative(g,origin)
    local_of :: proc(g:Gpu_Volume,p:[3]f64) -> (local:[3]f64) {
        for row,i in g.to_local {local[i]=f64(row.x)*p.x+f64(row.y)*p.y+f64(row.z)*p.z+f64(row.w)}
        return
    }
    point:=[3]f64{20001.25,3.5,-15001}
    want:=local_of(g,point)
    got:=local_of(relative,point-[3]f64{f64(origin.x),f64(origin.y),f64(origin.z)})
    for axis in 0..<3 {testing.expectf(t,abs(got[axis]-want[axis])<1e-3,"axis %d: %v from the origin, %v from the world",axis,got[axis],want[axis])}
    winds:Gpu_Wind
    winds.count.x,winds.volumes[0],winds.volumes[1]=1,g,g
    moved:=gpu_wind_relative(winds,origin)
    testing.expect(t,moved.volumes[0]==relative && moved.volumes[1]==g,"the winds the frame has move, and only them")
}
