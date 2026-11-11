package vfx

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// What particle_fields of particles.slang finds of the gravity at p, a place
// relative to the origin of the frame.
@(private="file")
fields_gravity :: proc(f:Gpu_Fields,p:[3]f32) -> [3]f32 {
    weight :: proc(v:volume.Gpu_Volume,p:[3]f32,outlines:^volume.Gpu_Outlines) -> f32 {
        if v.kind.x==0 {return 1}
        if v.kind.x==5 {return 0}
        local:[3]f32
        for row,i in v.to_local {local[i]=row.x*p.x+row.y*p.y+row.z*p.z+row.w}
        boxed:=v.kind.x==1 || v.kind.x==4
        depth:=boxed?min(v.shape.x-abs(local.x),v.shape.y-abs(local.y),v.shape.z-abs(local.z)):v.shape.x-linalg.length(local)
        if depth<0 {return 0}
        if v.kind.x==4 {
            loop:[volume.VOLUME_OUTLINE_POINTS]mm.Path_Point
            for &q,k in loop[:v.kind.w] {
                at:=v.kind.z+u32(k)
                row:=outlines.rows[at>>1]
                q.position.xz=at&1!=0?row.zw:row.xy
            }
            depth=min(mm.loop_depth(loop[:v.kind.w],local.x,local.z),v.shape.y-abs(local.y))
            if depth<0 {return 0}
        }
        return v.shape.w>0?min(depth/v.shape.w,1):1
    }
    value:=f.fallback.xyz
    g:=f.gravity
    for i in 0..<g.count.x {
        w:=weight(g.volumes[i],p,&g.outlines)
        if w<=0 {continue}
        by:=g.pulls[i].xyz
        if g.centers[i].x!=0 {
            to:=g.pulls[i].xyz-p
            distance:=linalg.length(to)
            strength:=g.centers[i].y
            if surface:=g.centers[i].z;surface>0 {strength*=distance>surface?surface*surface/(distance*distance):distance/surface}
            by=distance>1e-4?to/distance*strength:{}
        }
        if g.volumes[i].kind.y!=0 {value+=by*w} else {value+=(by-value)*w}
    }
    return value
}

@(private)
@(test_world)
Fields_World :: struct {
    using world:Test_World,
    gravities:core.Table(volume.Gravity),
    volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
    splines:core.Table(volume.Spline),
}

// The particles fall with the gravity the bodies fall with, from the same
// fields, far from the centre of the world too: the level, a planet in its
// sphere, a room that adds a push and an L-shaped room whose notch takes none.
@(test)
particles_take_the_gravity_of_their_place_as_the_bodies :: proc(t:^testing.T) {
    w:Fields_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    place :: proc(w:^Fields_World,g:volume.Gravity,v:Maybe(volume.Volume),position:[3]f32,rotation:=mm.QUAT_IDENTITY,outline:=volume.Spline{}) {
        e:=core.create(&w.entities)
        if outline.count>0 {core.add(&w.splines,e,outline)}
        core.add(&w.gravities,e,g)
        if v,ok:=v.?;ok {core.add(&w.volumes,e,v)}
        core.add(&w.worlds,e,core.World_Transform{transform={position=position,rotation=rotation,scale=1}})
        test_world_settle(w)
    }
    place(&w,volume.GRAVITY_DEFAULT,nil,{})
    place(&w,{pull=.Center,acceleration=5,radius=2,zone={blend=2,priority=1}},volume.sphere(10),{10040,0,0})
    place(&w,{acceleration=3,zone={priority=2,mode=.Add}},volume.box({4,4,4}),{10020,0,0},mm.quat_axis_angle({0,0,1},mm.PI/2))
    l:=volume.Spline{count=6,points={0={position={-4,0,-4}},1={position={4,0,-4}},2={position={4,0,0}},3={position={0,0,0}},4={position={0,0,4}},5={position={-4,0,4}}}}
    place(&w,{acceleration=2,zone={blend=1,priority=3,mode=.Add}},volume.outline(4),{10000,0,0},mm.quat_axis_angle({0,1,0},mm.PI/2),l)
    origin:=[3]f32{10032,0,0}
    zones:=volume.Where{volumes=core.read(&w.volumes),worlds=core.read(&w.worlds),splines=core.read(&w.splines)}
    fields:=fields_relative(fields_of(core.read(&w.gravities),{},zones),origin)
    testing.expect(t,fields.gravity.outlines.count.x==6,"the L writes its points")
    Of :: struct {gravities:^core.Table(volume.Gravity,.Read),worlds:^core.Table(core.World_Transform,.Read),point:[3]f32}
    of :: proc(o:Of,row:i32) -> [3]f32 {
        world,_:=core.get(o.worlds,core.entity_at(o.gravities,int(row)))
        return volume.gravity_of(core.at(o.gravities,int(row)),world.transform,o.point)
    }
    // In the L, at its border, in its notch (inside its box), out of it.
    for p in ([?][3]f32{{0,0,0},{10040,4,0},{10048,0,0},{10031,0,0},{10020,1,0},{10060,0,0},{9998,0,-2},{9999.5,0,-2},{10002,0,2},{10002,0,-2}}) {
        want:=volume.combine(volume.gather(zones,core.read(&w.gravities),p),volume.GRAVITY_WORLD,Of{core.read(&w.gravities),core.read(&w.worlds),p},of,volume.mix_linear)
        got:=fields_gravity(fields,p-origin)
        testing.expectf(t,linalg.length(got-want)<1e-3,"at %v: %v on the GPU, %v for a body",p,got,want)
    }
}
