package volume

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import "mirai:std/spatial"

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
    return at(core.read(&f.volumes),core.read(&f.worlds),&f.levels,point,Level{1},mix_level).value
}

// The level at a point through an index, as a library that asks at many
// points: the base where no bounded volume holds it.
@(private="file")
level_indexed :: proc(f:^Fixture,ix:^Index,point:[3]f32) -> f32 {
    levels:=&f.levels
    of :: proc(levels:^core.Table(Level),row:i32) -> Level {return core.at(levels,int(row))}
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
    testing.expect_value(t,plane(2,priority=3),Volume{shape=.Plane,blend=2,priority=3})
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
    // A sea under y=-50, and a wall: everything beyond x=60.
    place(&f,90,plane(blend=10,priority=8),position={0,-50,0})
    wall:=place(&f,70,plane(priority=9),position={60,0,0})
    core.edit(&f.worlds,wall).rotation=mm.quat_axis_angle({0,0,1},mm.PI/2)
    changed,ok:=index_update(&ix,core.read(&f.volumes),core.read(&f.worlds),&f.levels)
    testing.expect(t,changed && ok)
    points:=[?][3]f32{{},{0.5,0,0},{1.5,0,0},{3,0,0},{4.5,0,0},{19,0,0},{21,0,0},{22.5,0,0},{24,0,0},{-30,8,0},{-38,0,0},{100,100,100},{0,-55,0},{-500,-70,900},{61,-70,0}}
    for p in points {
        testing.expectf(t,level_indexed(&f,&ix,p)==level_at(&f,p),"at %v: %v indexed, %v gathered",p,level_indexed(&f,&ix,p),level_at(&f,p))
    }
    testing.expect_value(t,level_indexed(&f,&ix,{-30,8,0}),f32(10))
    testing.expect_value(t,level_indexed(&f,&ix,{-38,0,0}),f32(5))
    testing.expect_value(t,level_indexed(&f,&ix,{-500,-70,900}),f32(90))
    testing.expect_value(t,level_indexed(&f,&ix,{61,-70,0}),f32(70))
    testing.expect(t,index_bounded(&ix))
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
        changed,_:=index_update(ix,core.read(&f.volumes),core.read(&f.worlds),&f.levels)
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

// The one test of what a region holds and what it meets, by shape: a point
// inside at its depth and its weight, a point outside, a box of the world that
// touches it and one that does not; turned, scaled and mirrored as its entity.
@(test)
each_shape_holds_the_points_inside_it_and_meets_the_boxes_that_touch_it :: proc(t:^testing.T) {
    quarter:=mm.quat_axis_angle({0,0,1},mm.PI/2)
    eighth:=mm.quat_axis_angle({0,0,1},mm.PI/4)
    Case :: struct {
        name:string,
        v:Volume,
        pose:mm.Transform,
        inside:[3]f32,
        depth,weight:f32, // of inside
        outside:[3]f32,
        meets,misses:spatial.Aabb,
    }
    cases:=[?]Case{
        {"a box",box({1,2,3}),{position={10,0,0},rotation=1,scale=1},{10.5,0,0},0.5,1,{11.5,0,0},{{11,-1,-1},{12,1,1}},{{11.1,-1,-1},{12,1,1}}},
        // Along the diagonal of x and y: a box of the world beside the diagonal is in its bounds and not in it.
        {"a turned box",box({10,1,1},blend=2),{position={},rotation=eighth,scale=1},{5,5,0},1,0.5,{5,-5,0},{{5,5,-0.5},{6,6,0.5}},{{5,-6,-0.5},{6,-5,0.5}}},
        {"a scaled box",box({1,1,1}),{position={},rotation=quarter,scale={8,1,1}},{0,7,0},1,1,{7,0,0},{{-0.5,7.5,-0.5},{0.5,9,0.5}},{{1.5,7.5,-0.5},{2,9,0.5}}},
        {"a mirrored box",box({1,1,1}),{position={2,0,0},rotation=1,scale={-2,1,1}},{3.5,0,0},0.5,1,{4.5,0,0},{{4,0,0},{5,0.5,0.5}},{{4.1,0,0},{5,0.5,0.5}}},
        // Its radius is scaled by the largest axis.
        {"a sphere",sphere(2,blend=4),{position={},rotation=1,scale={1,3,1}},{0,0,4},2,0.5,{0,0,6.5},{{6,-1,-1},{7,1,1}},{{5,5,5},{6,6,6}}},
        {"a plane",plane(4),{position={0,3,0},rotation=1,scale=1},{100,1,-100},2,0.5,{0,3.5,0},{{0,3,0},{1,4,1}},{{0,3.1,0},{1,4,1}}},
        // Its up is -X: under it is +X of x=1.
        {"a turned plane",plane(),{position={1,0,0},rotation=quarter,scale=1},{3,50,0},2,1,{0,0,0},{{0,0,0},{1.5,1,1}},{{-1,0,0},{0.5,1,1}}},
    }
    for c in cases {
        testing.expectf(t,abs(depth(c.v,c.pose,c.inside)-c.depth)<1e-4,"%s: %v is %v deep, not %v",c.name,c.inside,depth(c.v,c.pose,c.inside),c.depth)
        testing.expectf(t,abs(weight(c.v,c.pose,c.inside)-c.weight)<1e-4,"%s: %v weighs %v, not %v",c.name,c.inside,weight(c.v,c.pose,c.inside),c.weight)
        testing.expectf(t,holds(c.v,c.pose,c.inside) && !holds(c.v,c.pose,c.outside) && weight(c.v,c.pose,c.outside)==0,"%s: holds %v and not %v",c.name,c.inside,c.outside)
        testing.expectf(t,overlaps(c.v,c.pose,c.meets) && !overlaps(c.v,c.pose,c.misses),"%s: meets %v and not %v",c.name,c.meets,c.misses)
        testing.expectf(t,valid(c.v,c.pose),"%s is valid",c.name)
        // What it holds and what it meets are in its bounds.
        b:=bounds(c.v,c.pose)
        testing.expectf(t,mm.aabb_overlaps(b,{c.inside,c.inside}) && mm.aabb_overlaps(b,c.meets),"%s: its bounds %v leave out what it holds",c.name,b)
        // The shader weighs it as the processor does.
        testing.expectf(t,abs(gpu_weight(gpu_volume(c.v,c.pose),c.inside)-c.weight)<1e-4 && gpu_weight(gpu_volume(c.v,c.pose),c.outside)==0,"%s: the shader weighs %v at %v",c.name,gpu_weight(gpu_volume(c.v,c.pose),c.inside),c.inside)
    }
    all:=spatial.Aabb{{-5,-5,-5},{5,5,5}}
    testing.expect(t,holds(world(),mm.TRANSFORM_IDENTITY,{1e30,-1e30,0}) && overlaps(world(),mm.TRANSFORM_IDENTITY,all) && valid(world(),mm.TRANSFORM_IDENTITY))
    testing.expect_value(t,weight(world(),mm.TRANSFORM_IDENTITY,{1,2,3}),f32(1))
}

// volume.slang volume_weight, on the processor.
@(private="file")
gpu_weight :: proc(g:Gpu_Volume,p:[3]f32) -> f32 {
    if g.kind.x==0 {return 1}
    local:[3]f32
    for row,i in g.to_local {local[i]=row.x*p.x+row.y*p.y+row.z*p.z+row.w}
    d:f32
    switch g.kind.x {
    case 1: d=min(g.shape.x-abs(local.x),g.shape.y-abs(local.y),g.shape.z-abs(local.z))
    case 2: d=g.shape.x-linalg.length(local)
    case 3: d=-local.y
    case:   d=-1
    }
    if d<0 {return 0}
    return g.shape.w>0?min(d/g.shape.w,1):1
}

// A size, a pose, a point or a box that is not a number, a size below zero
// and a shape that is none hold nothing, meet nothing and are not valid; no
// value makes them crash.
@(test)
a_hostile_volume_holds_and_meets_nothing :: proc(t:^testing.T) {
    nan:=f32(0)
    nan/=nan
    inf:=max(f32)*2
    still:=mm.TRANSFORM_IDENTITY
    Case :: struct {name:string,v:Volume,pose:mm.Transform}
    cases:=[?]Case{
        {"a box of an extent that is not a number",box({nan,1,1}),still},
        {"a box of a negative extent",box({1,-1,1}),still},
        {"a sphere of a radius that is not a number",sphere(nan),still},
        {"a sphere of a negative radius",sphere(-2),still},
        {"a box at a place that is not a number",box({1,1,1}),{position={nan,0,0},rotation=1,scale=1}},
        {"a sphere at a place that is not a number",sphere(1),{position={0,nan,0},rotation=1,scale=1}},
        {"a plane at a place that is not a number",plane(),{position={0,nan,0},rotation=1,scale=1}},
        {"a box of a turn that is not a number",box({1,1,1}),{rotation=quaternion(w=nan,x=0,y=0,z=0),scale=1}},
        {"a plane of a turn that is not a number",plane(),{rotation=quaternion(w=nan,x=nan,y=nan,z=nan),scale=1}},
        {"a box of a scale that is not a number",box({1,1,1}),{rotation=1,scale={nan,1,1}}},
        {"a box of no size by a scale without end",box({0,1,1}),{rotation=1,scale={inf,1,1}}},
        {"a shape that is none",Volume{shape=Volume_Shape(200),extents={1,1,1}},still},
    }
    points:=[?][3]f32{{},{0.5,-0.5,0.25},{0,-3,0},{nan,0,0},{inf,-inf,0}}
    boxes:=[?]spatial.Aabb{{{-1,-1,-1},{1,1,1}},{{-inf,-inf,-inf},{inf,inf,inf}},{{nan,0,0},{1,1,1}},{{1,1,1},{-1,-1,-1}}}
    for c in cases {
        testing.expectf(t,!valid(c.v,c.pose),"%s is valid",c.name)
        for p in points {
            testing.expectf(t,weight(c.v,c.pose,p)==0 && !holds(c.v,c.pose,p),"%s holds %v",c.name,p)
        }
        for b in boxes {testing.expectf(t,!overlaps(c.v,c.pose,b),"%s meets %v",c.name,b)}
        _=size(c.v,c.pose)
        _=bounds(c.v,c.pose)
        _=gpu_volume(c.v,c.pose)
    }
    // A sound volume holds no point and meets no box that is not a number.
    for v in ([?]Volume{box({1,1,1}),sphere(1),plane(),world()}) {
        testing.expect(t,v.shape==.Unbounded || !holds(v,still,{nan,nan,nan}))
        testing.expect(t,!overlaps(v,still,{{nan,0,0},{1,1,1}}) && !overlaps(v,still,{{1,1,1},{-1,-1,-1}}))
    }
    // No size, or a blend that is not a number or below zero, is not valid either.
    for v in ([?]Volume{box({0,1,1}),sphere(0),box({1,1,1},blend=nan),sphere(1,blend=-1)}) {testing.expectf(t,!valid(v,still),"%v is valid",v)}
    // An index of hostile volumes is made, and its points are not in them.
    f:Fixture
    if !core.test_world_init(t,&f,test_types) {return}
    defer core.test_world_destroy(&f)
    ix:Index;defer index_destroy(&ix)
    for c in cases {
        e:=place(&f,50,c.v)
        core.edit(&f.worlds,e).transform=c.pose
    }
    _,ok:=index_update(&ix,core.read(&f.volumes),core.read(&f.worlds),&f.levels)
    testing.expect(t,ok)
    for p in points[:3] {testing.expectf(t,level_indexed(&f,&ix,p)==1 && level_at(&f,p)==1,"a hostile volume rules at %v",p)}
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
