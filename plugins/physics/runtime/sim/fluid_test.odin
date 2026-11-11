package mirai_physics

import "core:testing"
import cmath "core:math"
import math "mirai:std/math"

@(private="file")
ocean :: proc(w:^World,height:f32=0,density:f32=1000,current:=Vec3{}) -> Fluid_Handle {
    return fluid_create(w,{shape=.Plane,position={0,height,0},density=density,current=current})
}

@(private="file")
dry_box :: proc(w:^World,center,half:Vec3,yaw:f32=0) -> Fluid_Handle {
    return fluid_create(w,{shape=.Box,position=center,half_extents=half,yaw=yaw,priority=1})
}

@(private="file")
solid :: proc(w:^World,geometry:Geometry,position:Vec3,density:f32,rotation:=QUAT_IDENTITY,locks:=Body_Flags{}) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.position,desc.rotation,desc.locks=position,rotation,locks
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=geometry
    shape.density=density
    shape_create(w,body,shape)
    return body
}

// What of a body is in its fluid where it is now, with the center relative to the world.
@(private="file")
submerged :: proc(w:^World,h:Body_Handle) -> (load:Fluid_Load,center:Vec3) {
    body,_:=body_get(w,h)
    wet:Wet
    wet_find(w,body,{},&wet)
    clip:=new(Clip_Scratch)
    defer free(clip)
    if wet.water_count==0 {return}
    load=body_load(w,body,body.center,body.rotation,&wet,0,{},clip)
    if wet.water_count>1 {
        other:=body_load(w,body,body.center,body.rotation,&wet,1,{},clip)
        load.volume+=other.volume
        load.moment+=other.moment
        load.area+=other.area
    }
    if load.volume>0 {center=body.center+load.moment/load.volume}
    return
}

@(test)
the_fluid_at_a_point_gives_the_surface_over_or_under_it_through_the_dry_boxes :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    sea:=fluid_create(&w,{shape=.Plane,density=1025,current={0,0,-1},yaw=0.5*PI})
    dry_box(&w,{0,-5,0},{2,1,2})
    pool:=fluid_create(&w,{shape=.Box,position={20,5,0},half_extents={2,1,2},density=1000})
    testing.expect(t,sea!={} && pool!={})
    expect :: proc(t:^testing.T,w:^World,p:Vec3,height,density:f32,loc:=#caller_location) {
        sample,ok:=fluid_sample(w,p)
        testing.expect(t,ok,loc=loc)
        expect_near(t,sample.height,height,1e-5,loc)
        expect_near(t,sample.density,density,1e-5,loc)
    }
    expect(t,&w,{0,-10,0},-6,1025) // under the base the water ends at its floor
    expect(t,&w,{0,-5,0},-6,0)     // in its air the surface is the floor
    expect(t,&w,{0,-3,0},0,1025)   // over it the sea goes on to its surface
    expect(t,&w,{0,5,0},0,0)
    expect(t,&w,{20,5.5,0},6,1000) // the pool over the sea
    expect(t,&w,{20,2,0},0,0)      // between the two, the sea is the nearest under
    expect(t,&w,{20,9,0},6,0)
    sample,_:=fluid_sample(&w,{0,-1,0})
    expect_near3(t,sample.current,{-1,0,0},1e-5) // the current turns with the yaw of the sea
    expect_near3(t,sample.normal,UP)
    _,found:=fluid_sample(&w,{50,0,50})
    testing.expect(t,found,"the sea reaches everywhere")
    testing.expect_value(t,fluid_create(&w,{shape=.Plane,density=0}),Fluid_Handle{})
    testing.expect_value(t,fluid_create(&w,{shape=.Box,half_extents={1,0,1},density=1000}),Fluid_Handle{})
    found_handles:[4]Fluid_Handle
    testing.expect_value(t,fluids_overlap(&w,{{18,-1,-1},{22,5,1}},found_handles[:]),2) // the pool and the sea under it
    fluid_destroy(&w,pool)
    testing.expect(t,!fluid_valid(&w,pool))
    testing.expect_value(t,world_stats(&w).fluids,2)
}

// Water along a path: its surface goes along the curve of its points, it ends
// at its banks and its ends, and what floats in it drifts with its current.
@(test)
water_along_a_path_holds_between_its_banks_and_carries_what_floats :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // 40 m toward -z falling 2 m, 4 m wide and 2 m deep, at 1 m/s; then 20 m toward -x, level.
    desc:=Fluid_Desc{shape=.Path,density=1000}
    path:=[]Path_Point{{{0,2,0},4,2,1},{{0,0,-40},4,2,1},{{-20,0,-40},4,2,1}}
    river:=fluid_create(&w,desc,path)
    testing.expect(t,river!={})
    back,_:=fluid_desc(&w,river)
    points:[FLUID_PATH_POINTS]Path_Point
    count:=fluid_path(&w,river,&points)
    testing.expect(t,count==len(path) && points[count-1]==path[count-1] && back==desc,"its points and description come back as they were given")
    Case :: struct {p:Vec3,inside:bool,height,density:f32}
    for c in ([]Case{
        {{0,1.5,0},true,2,1000},       // at its first point the surface is at that point
        {{0,0.5,-20},true,0.89,1000},  // half way down, easing into the level stretch
        {{1.5,0.5,-20},true,0.89,1000}, // near a bank
        {{0,1.5,-20},true,0.89,0},     // over the surface
        {{4,0.5,-20},false,0,0},       // past a bank, where the curve bends out before the turn
        {{0,1,5},false,0,0},           // before its first point
        {{-25,-0.5,-40},false,0,0},    // past its last point
        {{-10,-0.5,-42},true,0,1000},  // after the turn, where the curve swings past the points, level
    }) {
        sample,ok:=fluid_sample(&w,c.p)
        testing.expectf(t,ok==c.inside,"at %v",c.p)
        if !ok {continue}
        expect_near(t,sample.height,c.height,0.05)
        expect_near(t,sample.density,c.density,1e-4)
    }
    sample,_:=fluid_sample(&w,{0,0.5,-20})
    testing.expectf(t,sample.normal.z<0 && sample.normal.y>0.99,"the surface leans down the path: %v",sample.normal)
    testing.expectf(t,sample.current.z< -0.99 && abs(sample.current.x)<0.1,"it flows down the path: %v",sample.current)
    bounds:=fluid_bounds(&w,river)
    testing.expect(t,bounds.max.y>=2 && bounds.min.y<= -2 && bounds.min.x<= -20 && bounds.max.z>=0)
    box:=solid(&w,Box{{0.4,0.4,0.4}},{0,0.8,-10},500)
    test_steps(&w,600)
    at:=body_center(&w,box)
    drift:=body_linear_velocity(&w,box)
    testing.expectf(t,at.z< -12 && drift.z< -0.5,"it drifts downstream: at %v at %v m/s",at,drift)
    height,_,_:=fluid_surface(&w,river,at.x,at.z)
    testing.expectf(t,abs(at.y-height)<0.4,"and floats on the surface at %v, %v",at,height)
    nan:=cmath.nan_f32()
    many:[FLUID_PATH_POINTS+1]Path_Point
    for &p,i in many {p={{0,0,-f32(i)},1,1,0}}
    for refused in ([][]Path_Point{
        {{{0,0,0},1,1,0}},
        {{{0,0,0},1,1,0},{{0,1,0},1,1,0}},
        {{{0,0,0},0,1,0},{{0,0,4},1,1,0}},
        {{{0,0,0},1,0,0},{{0,0,4},1,1,0}},
        {{{nan,0,0},1,1,0},{{0,0,4},1,1,0}},
        {{{0,0,0},1,1,nan},{{0,0,4},1,1,0}},
        many[:],
    }) {testing.expect_value(t,fluid_create(&w,{shape=.Path,density=1000},refused),Fluid_Handle{})}
    testing.expect_value(t,fluid_create(&w,{shape=.Path},path),Fluid_Handle{})
    testing.expect_value(t,fluid_create(&w,{shape=.Path,density=1000,current={0,0,-1}},path),Fluid_Handle{})
    for p in ([]Vec3{{nan,0,0},{0,0,nan},{max(f32),0,-max(f32)}}) {
        _,ok:=fluid_sample(&w,p)
        testing.expectf(t,!ok,"no water at %v",p)
    }
}

// A river 1 km long of eleven points over bumpy ground, fast at its middle
// point: its banks follow its curve all along however far apart its points
// are, its surface never rises from its first point to its last, and a body
// drifts faster where it is faster.
@(test)
a_long_river_never_rises_and_flows_at_the_speed_of_its_points :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    bumps:=[11]f32{0,3,-1,2,-2,1,-3,0,-4,-1,-5}
    points:[11]Path_Point
    for &p,i in points {p={{30*cmath.sin(f32(i)),bumps[i],-100*f32(i)},6,2,i==5?4:1}}
    river:=fluid_create(&w,{shape=.Path,density=1000},points[:])
    testing.expect(t,river!={})
    last:=max(f32)
    for k in 0..<1000 {
        at,_:=math.path_at(points[:],k/100,f32(k%100)/100)
        height,_,_:=fluid_surface(&w,river,at.position.x,at.position.z)
        testing.expectf(t,height<=last+1e-5,"the surface rises at %v: %v after %v",at.position,height,last)
        last=height
        sample,ok:=fluid_sample(&w,{at.position.x,height-0.5,at.position.z})
        testing.expectf(t,ok && sample.density==1000,"water under its surface at %v",at.position)
    }
    drift :: proc(w:^World,body:Body_Handle) -> f32 {
        v:=body_linear_velocity(w,body)
        return cmath.sqrt(v.x*v.x+v.z*v.z)
    }
    slow:=solid(&w,Box{{0.4,0.4,0.4}},{points[1].position.x,0.2,-100},500)
    fast:=solid(&w,Box{{0.4,0.4,0.4}},{points[5].position.x,-1.8,-500},500)
    test_steps(&w,240)
    testing.expectf(t,drift(&w,fast)>2.5 && drift(&w,slow)<1.5,"it drifts at %v m/s where it flows at 4, at %v where at 1",drift(&w,fast),drift(&w,slow))
}

// A body takes the water whose column holds it, not one whose box it is in:
// a box in a lake that a river winds around stays afloat, a plank across two
// pools floats level on both, and the air of a dry box over the plank keeps
// both out of it.
@(test)
a_body_floats_in_the_water_it_is_in_and_in_both_across_a_border :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    river:=fluid_create(&w,{shape=.Path,density=1000},{{{-20,0,0},4,1,1},{{-20,0,-40},4,1,1},{{20,0,-40},4,1,1},{{20,0,0},4,1,1}})
    lake:=fluid_create(&w,{shape=.Box,position={0,-1,-20},half_extents={8,1,8},density=1000})
    left:=fluid_create(&w,{shape=.Box,position={-2,-1,40},half_extents={2,1,2},density=1000})
    right:=fluid_create(&w,{shape=.Box,position={2,-1,40},half_extents={2,1,2},density=1000})
    testing.expect(t,river!={} && lake!={} && left!={} && right!={})
    raft:=solid(&w,Box{{0.4,0.4,0.4}},{0,0.2,-20},500)
    plank:=solid(&w,Box{{1.5,0.1,0.5}},{0,0.1,40},500)
    test_steps(&w,600)
    at:=body_center(&w,raft)
    testing.expectf(t,abs(at.y)<0.05,"the raft floats in the lake at %v",at)
    level:=body_center(&w,plank)
    body,_:=body_get(&w,plank)
    up:=q_rotate(body.rotation,UP)
    testing.expectf(t,abs(level.y)<0.02 && up.y>0.999,"the plank floats level across the two pools at %v, up %v",level,up)
    wet,_:=submerged(&w,plank)
    testing.expectf(t,abs(wet.volume-0.3)<0.01,"half of it is in the water of the two: %v m3",wet.volume)
    dry_box(&w,{0,0,40},{2,1,1})
    dry,_:=submerged(&w,plank)
    testing.expectf(t,abs(dry.volume)<1e-5,"none of it is in either under the air: %v m3",dry.volume)
}

// Two paths whose ends meet, the second going on the way the first ends: across
// the join there is water all along.
@(test)
two_paths_whose_ends_meet_hold_water_across_the_join :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    water:=Fluid_Desc{shape=.Path,density=1000}
    up:=fluid_create(&w,water,{{{0,3,0},4,1,0},{{10,2,-10},4,1,0},{{10,1,-30},4,1,0}})
    down:=fluid_create(&w,water,{{{10,1,-30},4,1,0},{{10,0,-50},4,1,0}})
    testing.expect(t,up!={} && down!={})
    for x in ([]f32{8.1,9,10,11,11.9}) {
        for z in ([]f32{-29.9,-30,-30.1}) {
            sample,ok:=fluid_sample(&w,{x,0.5,z})
            testing.expectf(t,ok && sample.density==1000 && abs(sample.height-1)<0.01,"at %v, %v: %v",x,z,sample)
        }
    }
}

@(test)
boxes_and_hulls_cut_by_the_surface_keep_their_exact_volume :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w)
    // Any plane through the center of a box halves it.
    tilt:=q_axis_angle(normalize(Vec3{1,2,3}),0.7)
    a:=solid(&w,Box{{0.5,0.3,0.8}},{0,0,0},1000,tilt)
    load,center:=submerged(&w,a)
    expect_near(t,load.volume,0.5*8*0.5*0.3*0.8,1e-5)
    testing.expect(t,center.y<0)
    // Turned 45 degrees about Z a unit cube shows the surface its diagonal.
    b:=solid(&w,Box{{0.5,0.5,0.5}},{5,0,0},1000,q_axis_angle({0,0,1},0.25*PI))
    load,_=submerged(&w,b)
    expect_near(t,load.volume,0.5,1e-5)
    expect_near(t,load.area,cmath.SQRT_TWO,1e-4)
    // A tilted hull, against the share of a fine grid of its points under the surface.
    vertices:[8]Vec3
    for &v,i in vertices {v={i&1!=0?0.6:-0.6,i&2!=0?0.25:-0.25,i&4!=0?0.4:-0.4}}
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    hull,ok:=hull_create(&w,{vertices[:],counts[:],indices[:]})
    testing.expect(t,ok)
    turn:=q_axis_angle(normalize(Vec3{-1,3,0.5}),1.1)
    c:=solid(&w,hull,{-5,0.13,0},1000,turn)
    load,center=submerged(&w,c)
    GRID :: 64
    under:=0
    moment:Vec3
    for i in 0..<GRID {for j in 0..<GRID {for k in 0..<GRID {
        local:=Vec3{(f32(i)+0.5)/GRID*1.2-0.6,(f32(j)+0.5)/GRID*0.5-0.25,(f32(k)+0.5)/GRID*0.8-0.4}
        p:=Vec3{-5,0.13,0}+q_rotate(turn,local)
        if p.y<0 {under+=1;moment+=p}
    }}}
    volume:=1.2*0.5*0.8*f32(under)/(GRID*GRID*GRID)
    expect_near(t,load.volume,volume,0.005*volume)
    expect_near3(t,center,moment/f32(under),0.01)
}

@(test)
spheres_and_upright_capsules_submerge_in_closed_form :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w)
    // A cap of height 0.5 of a sphere of radius 1: pi h^2 (3r - h) / 3.
    a:=solid(&w,Sphere{1},{0,0.5,0},1000)
    load,center:=submerged(&w,a)
    expect_near(t,load.volume,PI*0.25*2.5/3,1e-5)
    expect_near(t,center.y,0.5-3*(2-0.5)*(2-0.5)/(4*(3-0.5)),1e-3) // 3 (2r - h)^2 / 4 (3r - h) under the center
    expect_near(t,load.area,PI*(1-0.25),1e-4)
    b:=solid(&w,Capsule{0.5,1},{5,0,0},1000)
    load,_=submerged(&w,b)
    expect_near(t,load.volume,0.5*(PI*0.25*2+4.0/3*PI*0.125),1e-5)
    expect_near(t,load.area,PI*0.25,1e-5)
    // Leaning, as spheres along its axis: the volume a half of it has, near enough.
    c:=solid(&w,Capsule{0.5,1},{10,0,0},1000,q_axis_angle({0,0,1},0.5*PI))
    load,_=submerged(&w,c)
    expect_near(t,load.volume,0.5*(PI*0.25*2+4.0/3*PI*0.125),1e-4)
    // A cylinder a wall of a box cuts, as a prism of its volume.
    d:=solid(&w,Cylinder{0.5,1},{20,-3,0},1000)
    dry_box(&w,{20,-3,-5},{3,3,5})
    load,_=submerged(&w,d)
    expect_near(t,load.volume,0.5*PI*0.25*2,0.01)
}

@(test)
a_box_of_half_the_density_of_water_floats_half_submerged_and_settles :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w)
    box:=solid(&w,Box{{0.5,0.5,0.5}},{0,0.5,0},500)
    test_steps(&w,600)
    // After ten seconds the bobbing has died down below a millimetre a second.
    fastest:f32
    for _ in 0..<60 {
        world_step(&w,1.0/60)
        fastest=max(fastest,length(body_linear_velocity(&w,box)))
    }
    testing.expectf(t,fastest<0.01,"still bobbing at %v m/s",fastest)
    submersion:=0.5-body_center(&w,box).y
    testing.expectf(t,abs(submersion-0.5)<=0.005,"submerged %v of its height",submersion)
    expect_near(t,length(body_angular_velocity(&w,box)),0,0.01)
}

@(test)
a_body_with_the_density_of_water_stays_where_it_is_let_go :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w,0,1000)
    box:=solid(&w,Box{{0.4,0.2,0.6}},{0,-3,0},1000,q_axis_angle({1,0,0},0.3))
    ball:=solid(&w,Sphere{0.3},{3,-2,0},1000)
    test_steps(&w,180)
    expect_near3(t,body_center(&w,box),{0,-3,0},1e-4)
    expect_near3(t,body_center(&w,ball),{3,-2,0},1e-4)
}

@(test)
a_sinking_sphere_reaches_its_terminal_velocity :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w,100,1000)
    r:f32=0.1
    ball:=solid(&w,Sphere{r},{0,50,0},2000)
    test_steps(&w,300)
    // (m - rho V) g = 1/2 rho Cd A v^2
    volume:=4.0/3*PI*r*r*r
    terminal:=cmath.sqrt(2*(2000-1000)*volume*9.81/(1000*CD_SPHERE*PI*r*r))
    speed:=-body_linear_velocity(&w,ball).y
    testing.expectf(t,abs(speed-terminal)<=0.02*terminal,"sinks at %v m/s, terminal %v",speed,terminal)
}

@(test)
the_current_carries_a_still_body_and_a_character_to_its_speed :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    current:=Vec3{1,0,0.5}
    ocean(&w,0,1000,current)
    box:=solid(&w,Box{{0.5,0.5,0.5}},{0,-5,0},1000)
    ch:=character_create(&w,CHARACTER_DESC_DEFAULT,{0,-4,10})
    move:=character_move(&w,ch)
    move.flags={.Airborne}
    move.air={}
    character_set_move(&w,ch,move)
    test_steps(&w,600)
    ride:=character_velocity(&w,ch)
    testing.expectf(t,length(Vec3{ride.x,0,ride.z}-current)<=0.05*length(current),"the character drifts at %v",ride)
    test_steps(&w,3000)
    drift:=body_linear_velocity(&w,box)
    testing.expectf(t,length(drift-current)<=0.05*length(current),"the body drifts at %v",drift)
    state:=character_state(&w,ch)
    expect_near3(t,state.fluid_velocity,current,1e-5)
}

@(test)
a_dry_box_takes_the_buoyancy_out_and_a_body_halfway_keeps_the_wet_part :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ocean(&w,10,1000)
    dry_box(&w,{0,0,0},{2,2,2})
    inside:=solid(&w,Box{{0.5,0.5,0.5}},{0,0,0},1000)
    halfway:=solid(&w,Box{{0.5,0.5,0.5}},{2,0,0},500,locks={.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z})
    wet:=solid(&w,Box{{0.5,0.5,0.5}},{0,0,6},1000)
    load,center:=submerged(&w,halfway)
    expect_near(t,load.volume,0.5,1e-5)
    expect_near(t,center.x,2.25,1e-4)
    test_steps(&w,18)
    // In the air of the base a body falls as in air; half of a body of half the density of water floats it.
    expect_near(t,body_linear_velocity(&w,inside).y,-9.81*0.3,0.01)
    expect_near(t,body_center(&w,halfway).y,0,1e-3)
    expect_near3(t,body_center(&w,wet),{0,0,6},1e-4)
}

@(test)
a_character_floats_with_its_head_out_and_knows_how_deep_its_head_is :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    ocean(&w)
    test_static_box(&w,{2,1,2},{4,-0.7,0}) // its top 0.3 m over the sea
    d:=CHARACTER_DESC_DEFAULT
    ch:=character_create(&w,d,{0,-4,0})
    move:=character_move(&w,ch)
    move.flags={.Airborne}
    character_set_move(&w,ch,move)
    test_steps(&w,1)
    state:=character_state(&w,ch)
    testing.expect_value(t,state.fluid,Fluid_Flags{.In_Fluid,.Underwater})
    expect_near(t,state.submersion,1)
    expect_near(t,state.head_depth,-(character_position(&w,ch).y+d.height),1e-4)
    // Lighter than water, it rises by itself, slowly.
    start:=character_position(&w,ch).y
    test_steps(&w,60)
    rise:=character_velocity(&w,ch).y
    testing.expectf(t,character_position(&w,ch).y>start && rise>0 && rise<0.5,"rises at %v m/s",rise)
    // Floating, it holds its head 0.3 m out.
    move.flags={.Airborne,.Float}
    move.float_height=0.3
    character_set_move(&w,ch,move)
    test_steps(&w,600)
    state=character_state(&w,ch)
    expect_near(t,state.head_depth,-0.3,0.02)
    testing.expect_value(t,state.fluid,Fluid_Flags{.In_Fluid})
    expect_near(t,character_velocity(&w,ch).y,0,0.01)
    // Climbing out toward the ledge, against the drag of the water, it lands on it.
    move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
    move.air={{1.5,4.85,0},d.traction_force}
    character_set_move(&w,ch,move)
    test_steps(&w,40)
    move.flags={}
    move.air={{1.5,0,0},d.traction_force}
    move.ground={{},d.traction_force}
    character_set_move(&w,ch,move)
    test_steps(&w,120)
    state=character_state(&w,ch)
    testing.expect(t,.Standing in state.ground,"it stands on the ledge")
    expect_near(t,character_position(&w,ch).y,0.3,0.02)
    testing.expect_value(t,state.fluid,Fluid_Flags{})
    expect_near(t,state.head_depth,-(0.3+d.height),0.02)
}

@(private="file")
fluid_scene :: proc(w:^World) -> (room:Fluid_Handle,ch:Character_Handle) {
    test_ground(w,{50,1,50})
    ocean(w,6)
    room=dry_box(w,{8,3,0},{3,4,3},0.3)
    vertices:[8]Vec3
    for &v,i in vertices {v={i&1!=0?0.7:-0.7,i&2!=0?0.2:-0.2,i&4!=0?0.5:-0.5}}
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    hull,_:=hull_create(w,{vertices[:],counts[:],indices[:]})
    for i in 0..<12 {
        position:=Vec3{f32(i%4)*2-3,7+f32(i/4)*0.8,f32(i/4)*2-2}
        solid(w,hull,position,300+f32(i)*40,q_axis_angle(normalize(Vec3{1,f32(i),2}),0.4))
    }
    solid(w,Sphere{0.3},{8,9,0},2500)
    solid(w,Capsule{0.2,0.5},{9,8,1},600,q_axis_angle({1,0,0},1))
    ch=character_create(w,CHARACTER_DESC_DEFAULT,{-6,3,0})
    move:=character_move(w,ch)
    move.flags={.Airborne,.Float}
    move.float_height=0.25
    move.air={{1,0,0.3},800}
    character_set_move(w,ch,move)
    return
}

@(test)
fluids_repeat_bit_for_bit_from_a_snapshot_and_when_resimulated :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_character_world(&a) && test_character_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    room,_:=fluid_scene(&a)
    fluid_scene(&b)
    test_steps(&a,60)
    buffer:World
    defer world_destroy(&buffer)
    ok:=test_keep(&buffer,&a)
    testing.expect(t,ok)
    run :: proc(w:^World,room:Fluid_Handle) {
        for step in 0..<120 {
            if step==40 {
                // The room floods: its air rises off the floor.
                desc,_:=fluid_desc(w,room)
                desc.position.y+=1
                desc.half_extents.y-=1
                fluid_set(w,room,desc)
            }
            world_step(w,1.0/60)
        }
    }
    run(&a,room)
    first:=world_hash(&a)
    testing.expect(t,test_restore(&a,&buffer))
    run(&a,room)
    testing.expect_value(t,world_hash(&a),first)
    testing.expect(t,test_restore(&b,&buffer))
    run(&b,room)
    testing.expect_value(t,world_hash(&b),first)
    // And with any number of workers.
    pool:Test_Pool
    test_pool_init(&pool,4)
    defer test_pool_destroy(&pool)
    c:World
    testing.expect(t,test_character_world(&c,8,&pool))
    defer world_destroy(&c)
    fluid_scene(&c)
    testing.expect(t,test_restore(&c,&buffer))
    run(&c,room)
    testing.expect_value(t,world_hash(&c),first)
}

@(test)
debug_draw_shows_fluid_boxes_and_a_grid_on_the_sea :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    lines:[4096]Debug_Line
    out:=Debug_Draw{lines=lines[:]}
    dry_box(&w,{0,0,0},{1,1,1})
    world_debug_draw(&w,&out,{.Fluids})
    testing.expect_value(t,out.line_count,12)
    testing.expect_value(t,lines[0].kind,Debug_Kind.Dry)
    ocean(&w,2)
    world_debug_draw(&w,&out,{.Fluids},{{-10,0,-10},{10,5,10}})
    testing.expect_value(t,out.line_count,12+2*(DEBUG_PLANE_LINES+1)*DEBUG_PLANE_PIECES)
    for line in lines[12:out.line_count] {
        testing.expect_value(t,line.kind,Debug_Kind.Fluid)
        expect_near(t,line.a.y,2)
    }
}

@(test)
a_fluid_made_or_changed_is_a_change_of_the_static_world :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    since,_,_:=static_changes(&w,0,nil)
    room:=dry_box(&w,{4,1,0},{2,1,2})
    boxes:[4]Aabb
    next,count,overflow:=static_changes(&w,since,boxes[:])
    testing.expect(t,!overflow && count==1)
    expect_near3(t,boxes[0].min,{2,0,-2})
    desc,_:=fluid_desc(&w,room)
    desc.position.y+=1
    fluid_set(&w,room,desc)
    _,count,_=static_changes(&w,next,boxes[:])
    testing.expect_value(t,count,2) // where it was and where it is
}

@(test)
a_floating_body_says_how_much_of_it_is_under_the_surface :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    w.gravity={0,-9.81,0}
    ocean(&w,0)
    box:=solid(&w,Box{{0.5,0.5,0.5}},{0,2,0},500)
    for _ in 0..<600 {world_step(&w,1.0/60)}
    found:[4]Fluid_Body
    count:=fluid_bodies(&w,found[:])
    // Floating still, it may be asleep: a push wakes it, and the next step lists it.
    if count==0 {
        body_apply_impulse(&w,box,{0,0.01,0})
        world_step(&w,1.0/60)
        count=fluid_bodies(&w,found[:])
    }
    testing.expect_value(t,count,1)
    testing.expect(t,found[0].body==box)
    expect_near(t,found[0].whole,1,1e-5)
    expect_near(t,found[0].volume,0.5,0.02)
    expect_near(t,found[0].surface,0,1e-5)
}
