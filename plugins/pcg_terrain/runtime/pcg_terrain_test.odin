package pcg_terrain

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import pcg "plugins:pcg/runtime"
import terrain "plugins:terrain/runtime"

@(test_world)
Stamp_World :: struct {
    using world:Test_World,
    stamps:core.Table(Pcg_Terrain_Stamp),
    beds:core.Table(Pcg_Terrain_Bed),
    conforms:core.Table(terrain.Terrain_Conform),
    zones:core.Table(pcg.Pcg_Zone),
    graphs:core.Table(pcg.Pcg_Graph),
    worlds:core.Table(core.World_Transform),
    splines:core.Table(volume.Spline),
    volumes:core.Table(volume.Volume),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    state:Pcg_Terrain_Seen,
    requests:terrain.Terrain_Requests,
}

@(private="file")
Stamp_Test :: struct {
    using w:Stamp_World,
    problems:core.Problems,
}

@(private="file")
test_init :: proc(t:^testing.T,f:^Stamp_Test) -> bool {
    if !test_world_init(t,&f.w) {return false}
    terrain.terrain_requests_serve(&f.requests,terrain.TERRAIN_SETTINGS_DEFAULT,&f.problems)
    return true
}

// A tick of the bridge; what it asked the terrain for is taken, as the terrain takes it.
@(private="file")
test_step :: proc(f:^Stamp_Test) -> []terrain.Edit_Request {
    w:=&f.w
    pcg_terrain_stamp(&w.state,&w.stamps,core.read(&w.beds),core.read(&w.zones),core.read(&w.graphs),core.read(&w.worlds),core.read(&w.splines),core.read(&w.volumes),core.read(&w.parents),&w.requests,core.commands(w,test_world_info(w)),&f.problems)
    test_world_settle(w)
    asked:=make([dynamic]terrain.Edit_Request,context.temp_allocator)
    append(&asked,..core.take(&w.requests.edits))
    terrain.terrain_requests_serve(&w.requests,terrain.TERRAIN_SETTINGS_DEFAULT,&f.problems)
    return asked[:]
}

@(private="file")
zone_stamp :: proc(f:^Stamp_Test,s:Pcg_Terrain_Stamp,at:[3]f32,graph:=false) -> core.Entity {
    e:=core.create(&f.entities)
    if graph {core.add(&f.graphs,e,pcg.Pcg_Graph{})} else {core.add(&f.zones,e,pcg.PCG_ZONE_DEFAULT)}
    core.add(&f.volumes,e,volume.VOLUME_DEFAULT)
    core.add(&f.worlds,e,core.World_Transform{transform={at,1,{1,1,1}}})
    core.add(&f.stamps,e,s)
    test_world_settle(&f.w)
    return e
}

@(private="file")
stamp_of :: proc(brush:Pcg_Terrain_Brush,strength:f32,radius:f32=4) -> Pcg_Terrain_Stamp {
    s:=PCG_TERRAIN_STAMP_DEFAULT
    s.brush,s.strength,s.radius=brush,strength,radius
    return s
}

// Each brush asks the terrain once, at its entity, as a dig of the terrain's
// own kind; again only when its values or its place change, never on a tick
// where nothing did, and the hash of what it asked stays on the stamp.
@(test)
a_stamp_asks_the_terrain_once_per_change_through_its_requests :: proc(t:^testing.T) {
    Case :: struct {brush:Pcg_Terrain_Brush,strength:f32,kind:terrain.Brush_Kind}
    cases:=[?]Case{{.Flatten,0.5,.Flatten},{.Smooth,0.3,.Smooth},{.Raise,2,.Raise},{.Lower,1,.Lower},{.Noise,0.5,.Noise},{.Paint,1,.Paint},{.Carve,1,.Carve}}
    for c,i in cases {
        f:Stamp_Test
        if !test_init(t,&f) {return}
        at:=[3]f32{10,3,-4}
        e:=zone_stamp(&f,stamp_of(c.brush,c.strength),at,graph=i%2==1)
        asked:=test_step(&f)
        if !testing.expectf(t,len(asked)==1,"%v: %d asked; %v",c.brush,len(asked),core.problems_list(&f.problems)) {test_world_destroy(&f.w);continue}
        b:=asked[0].brush
        testing.expectf(t,asked[0].owner==core.NONE && b.kind==c.kind && b.center==at && b.radius==4 && b.amount==c.strength,"%v: %v",c.brush,b)
        if c.brush==.Flatten {testing.expect_value(t,b.target,at.y)}
        applied:=core.at(&f.stamps,0).applied
        testing.expect(t,applied!=0,"the stamp keeps what it asked")
        testing.expectf(t,len(test_step(&f))==0 && len(test_step(&f))==0,"%v: nothing changed, nothing asked",c.brush)
        // Its strength, then its place.
        core.edit(&f.stamps,e).strength=c.strength*0.5
        test_world_settle(&f.w)
        testing.expectf(t,len(test_step(&f))==1,"%v: a change asks once more",c.brush)
        core.edit(&f.worlds,e).transform.position={0,0,0}
        test_world_settle(&f.w)
        again:=test_step(&f)
        testing.expectf(t,len(again)==1 && again[0].brush.center==[3]f32{},"%v: moved, it asks where it is",c.brush)
        testing.expect_value(t,f.problems.count,0)
        test_world_destroy(&f.w)
    }
}

// A stamp on a spline asks for dabs along it, at most DABS_MAX, every one
// on the path in the world; a stamp whose values are already applied (a
// scene opened again, a world copied for Play) asks nothing.
@(test)
a_stamp_along_a_spline_asks_dabs_along_it_and_a_copy_asks_nothing_again :: proc(t:^testing.T) {
    f:Stamp_Test
    if !test_init(t,&f) {return}
    defer test_world_destroy(&f.w)
    e:=zone_stamp(&f,stamp_of(.Smooth,0.5,2),{0,0,0})
    core.remove(&f.volumes,e)
    core.edit(&f.worlds,e).transform.position={100,0,0}
    spline:=volume.SPLINE_DEFAULT // 12 m along -Z
    core.add(&f.splines,e,spline)
    test_world_settle(&f.w)
    asked:=test_step(&f)
    testing.expectf(t,len(asked)>=12 && len(asked)<=DABS_MAX,"%d dabs",len(asked))
    for a in asked {
        p:=a.brush.center
        testing.expectf(t,a.brush.kind==.Smooth && abs(p.x-100)<1e-4 && p.z<=1e-4 && p.z>=-12-1e-4,"%v",p)
    }
    // A path of a kilometre takes them farther apart, as many as there are room for.
    long:=volume.Spline{count=2,points={0={width=3},1={position={0,0,-1000},width=3}}}
    core.edit(&f.splines,e)^=long
    test_world_settle(&f.w)
    far:=test_step(&f)
    testing.expectf(t,len(far)>DABS_MAX/2 && len(far)<=DABS_MAX,"%d dabs",len(far))
    testing.expect(t,len(far)>0 && abs(far[0].brush.center.z)<1e-3 && abs(far[len(far)-1].brush.center.z+1000)<1e-2,"from one end of the path to the other")
    copy:Stamp_Test
    if !test_init(t,&copy) {return}
    defer test_world_destroy(&copy.w)
    if !testing.expect(t,test_world_copy(&copy.w,&f.w)) {return}
    copy.state={}
    testing.expect_value(t,len(test_step(&copy)),0)
}

// With conform_spline a stamp asks no dab: a derived child holds its spline
// and the Terrain_Conform it gives, which the terrain follows; it is made
// again when the spline or the stamp change, never twice, and goes with
// conform_spline or with the stamp.
@(test)
a_conforming_stamp_keeps_one_derived_bed_of_its_spline :: proc(t:^testing.T) {
    f:Stamp_Test
    if !test_init(t,&f) {return}
    defer test_world_destroy(&f.w)
    s:=stamp_of(.Flatten,0.4,3)
    s.conform_spline,s.smooth,s.material=true,6,base.Asset_Id{9,9}
    e:=zone_stamp(&f,s,{0,0,0})
    core.add(&f.splines,e,volume.SPLINE_DEFAULT)
    test_world_settle(&f.w)
    testing.expect_value(t,len(test_step(&f)),0)
    bed_of :: proc(f:^Stamp_Test) -> (child:core.Entity,c:terrain.Terrain_Conform,spline:volume.Spline,count:int) {
        count=core.count(&f.beds)
        if count==0 {return}
        child=core.entity_at(&f.beds,0)
        c,_=core.get(&f.conforms,child)
        spline,_=core.get(&f.splines,child)
        return
    }
    child,c,spline,count:=bed_of(&f)
    parent,_:=core.get(&f.parents,child)
    testing.expect(t,count==1 && parent.entity==e,"one bed under the stamp")
    testing.expectf(t,c==terrain.Terrain_Conform{depth=0.4,sides=3,smooth=6,paint={9,9}},"%v",c)
    testing.expect(t,spline==volume.SPLINE_DEFAULT,"the bed follows the spline of the stamp")
    test_step(&f)
    same,_,_,count2:=bed_of(&f)
    testing.expect(t,count2==1 && same==child,"nothing changed: the same bed")
    // The spline moves a point: the bed is made again, once.
    core.edit(&f.splines,e).points[1].position={0,0,-20}
    test_world_settle(&f.w)
    testing.expect_value(t,len(test_step(&f)),0)
    moved,_,moved_spline,count3:=bed_of(&f)
    testing.expect(t,count3==1 && moved!=child && moved_spline.points[1].position==[3]f32{0,0,-20})
    // Bad values take the bed away and say why; good ones bring it back.
    core.edit(&f.stamps,e).radius=-1
    test_world_settle(&f.w)
    test_step(&f)
    problems:=core.problems_list(&f.problems)
    testing.expect(t,core.count(&f.beds)==0 && len(problems)==1 && string(cstring(&problems[0].code[0]))=="pcg_terrain.conform")
    core.edit(&f.stamps,e).radius=3
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,core.count(&f.beds),1)
    // Conforming no more, it stamps instead.
    core.edit(&f.stamps,e).conform_spline=false
    test_world_settle(&f.w)
    testing.expect(t,len(test_step(&f))>0 && core.count(&f.beds)==0)
    core.edit(&f.stamps,e).conform_spline=true
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,core.count(&f.beds),1)
    core.remove(&f.stamps,e)
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,core.count(&f.beds),0)
}

// A stamp that cannot be a brush asks nothing and says why: values that are
// not numbers, a radius of 0, a Carve of more than the whole, a layer past
// the terrain's, a stamp on no zone or graph, a conform without a spline.
@(test)
a_stamp_with_hostile_values_asks_nothing_and_is_a_problem :: proc(t:^testing.T) {
    Case :: struct {stamp:Pcg_Terrain_Stamp,at:[3]f32,code:string,owner:bool}
    nan,inf:=math.nan_f32(),math.inf_f32(1)
    paint:=stamp_of(.Paint,1)
    paint.layer=terrain.LAYERS_MAX
    conform:=stamp_of(.Flatten,1)
    conform.conform_spline=true
    cases:=[?]Case{
        {stamp_of(.Raise,nan),{},"pcg_terrain.brush",true},
        {stamp_of(.Raise,-1),{},"pcg_terrain.brush",true},
        {stamp_of(.Smooth,0.5,0),{},"pcg_terrain.brush",true},
        {stamp_of(.Smooth,0.5,inf),{},"pcg_terrain.brush",true},
        {stamp_of(.Carve,2),{},"pcg_terrain.brush",true},
        {stamp_of(.Flatten,0.5),{0,inf,0},"pcg_terrain.brush",true},
        {stamp_of(Pcg_Terrain_Brush(200),1),{},"pcg_terrain.brush",true},
        {paint,{},"pcg_terrain.brush",true},
        {conform,{},"pcg_terrain.spline",true},
        {stamp_of(.Raise,1),{},"pcg_terrain.owner",false},
    }
    for c in cases {
        f:Stamp_Test
        if !test_init(t,&f) {return}
        e:=zone_stamp(&f,c.stamp,c.at)
        if !c.owner {core.remove(&f.zones,e);test_world_settle(&f.w)}
        asked:=test_step(&f)
        problems:=core.problems_list(&f.problems)
        testing.expectf(t,len(asked)==0 && core.count(&f.beds)==0,"%v: asks nothing",c.stamp)
        testing.expectf(t,len(problems)==1 && string(cstring(&problems[0].code[0]))==c.code && problems[0].entity==e,"%v: %v",c.stamp,len(problems))
        test_world_destroy(&f.w)
    }
}

// Once what the stamps asked is applied, a tick reads no row and allocates nothing.
@(test)
a_clean_tick_does_no_work_and_allocates_nothing :: proc(t:^testing.T) {
    f:Stamp_Test
    if !test_init(t,&f) {return}
    defer test_world_destroy(&f.w)
    zone_stamp(&f,stamp_of(.Raise,1),{1,2,3})
    s:=stamp_of(.Flatten,0.2)
    s.conform_spline=true
    e:=zone_stamp(&f,s,{})
    core.add(&f.splines,e,volume.SPLINE_DEFAULT)
    test_world_settle(&f.w)
    testing.expect_value(t,len(test_step(&f)),1)
    test_step(&f)
    passes,asked:=f.state.passes,f.state.asked
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator=mem.tracking_allocator(&track)
        context.temp_allocator=context.allocator
        w:=&f.w
        pcg_terrain_stamp(&w.state,&w.stamps,core.read(&w.beds),core.read(&w.zones),core.read(&w.graphs),core.read(&w.worlds),core.read(&w.splines),core.read(&w.volumes),core.read(&w.parents),&w.requests,core.commands(w,test_world_info(w)),&f.problems)
    }
    testing.expect(t,f.state.passes==passes && f.state.asked==asked && track.total_allocation_count==0 && len(f.requests.edits.items)==0)
}
