package rig

import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// Each template stretched by its own skin: some bones longer or shorter by up
// to 30%, the same on both sides, their subtrees and the surface they carry
// moved with them, and the whole made from a tenth to ten times the size. The
// registration should find the moved joints.
@(test)
an_animal_rig_finds_the_joints_of_its_template_stretched_by_its_skin :: proc(t:^testing.T) {
    for kind in Animal {
        template:=ANIMALS[kind]
        nb:=len(template.bones)
        rest:=make([]mm.Vec3,nb,context.temp_allocator)
        turns:=make([]mm.Quat,nb,context.temp_allocator)
        for bone,i in template.bones {
            q:=quaternion(x=bone.rotation[0],y=bone.rotation[1],z=bone.rotation[2],w=bone.rotation[3])
            if bone.parent<0 {rest[i],turns[i]=bone.translation,q;continue}
            rest[i]=rest[bone.parent]+mm.quat_rotate(turns[bone.parent],bone.translation)
            turns[i]=turns[bone.parent]*q
        }
        lo,hi:=mm.Vec3{max(f32),max(f32),max(f32)},mm.Vec3{min(f32),min(f32),min(f32)}
        for s in template.samples {lo,hi=linalg.min(lo,s.position),linalg.max(hi,s.position)}
        size:=max(hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)
        // A stretch by the bone's height and depth, so mirrored bones share it.
        stretch:=make([]f32,nb,context.temp_allocator)
        moved:=make([]mm.Vec3,nb,context.temp_allocator)
        for bone,i in template.bones {
            stretch[i]=1
            if bone.parent<0 {continue}
            h:=u32(i32(rest[i].y*1000))*2654435761~u32(i32(rest[i].z*1000))*40503
            if h%2==0 {stretch[i]=0.7+0.6*f32(h%1000)/1000}
            moved[i]=moved[bone.parent]+(rest[i]-rest[bone.parent])*(stretch[i]-1)
        }
        // The surface: a small triangle on every sample, moved by its weights.
        positions:=make([][3]f32,3*len(template.samples),context.temp_allocator)
        indices:=make([]u32,3*len(template.samples),context.temp_allocator)
        for s,i in template.samples {
            p:=s.position
            for k in 0..<4 {p+=moved[s.bones[k]]*f32(s.weights[k])/255}
            e:=0.002*size
            positions[3*i],positions[3*i+1],positions[3*i+2]=p,p+{e,0,0},p+{0,e,0}
            for k in 0..<3 {indices[3*i+k]=u32(3*i+k)}
        }
        scales:=[3]f32{0.1,1,10}
        scale:=scales[int(kind)%3]
        for &p in positions {p*=scale}
        meshes:=[1]Mesh{{positions=positions,indices=indices}}
        made,ok:=register(template,meshes[:],context.temp_allocator)
        if !testing.expectf(t,ok,"%v registers",kind) {continue}
        total,worst:f32
        for joint,i in made.joints {
            if template.bones[i].parent<0 {continue}
            off:mm.Vec3=joint/scale-(rest[i]+moved[i])
            error:=linalg.length(off)/size
            total+=error
            worst=max(worst,error)
        }
        mean:=total/f32(nb-1)
        testing.expectf(t,mean<0.02,"%v: the joints are within 2%% of its size of the stretched ones on average: %.3f",kind,mean)
        testing.expectf(t,worst<0.08,"%v: and within 8%% each: %.3f",kind,worst)
        testing.expectf(t,made.coverage<COVERAGE_POOR,"%v: it covers the stretched surface: %.3f",kind,made.coverage)
    }
}

// Meshes no template is like still give a rig, or are refused, and never crash.
@(test)
an_animal_rig_of_meshes_that_are_no_animal_is_refused_or_made_without_crashing :: proc(t:^testing.T) {
    flat:=[?][3]f32{{0,0,0},{1,0,0},{0,0,1},{1,0,1}}
    point:=[?][3]f32{{2,3,4},{2,3,4},{2,3,4}}
    far:=[?][3]f32{{1e6,0,1e6},{1e6+1,0,1e6},{1e6,2,1e6}}
    quad:=[?]u32{0,1,2,1,3,2}
    triangle:=[?]u32{0,1,2}
    Case :: struct {name:string,positions:[][3]f32,indices:[]u32,empty:bool}
    cases:=[?]Case{
        {"no triangles",flat[:],nil,true},
        {"a point",point[:],triangle[:],true},
        {"flat",flat[:],quad[:],false},
        {"far away",far[:],triangle[:],false},
    }
    for c in cases {
        meshes:=[1]Mesh{{positions=c.positions,indices=c.indices}}
        made,error:=animal(meshes[:],.Fox,context.temp_allocator)
        if c.empty {
            testing.expectf(t,error==.Empty,"%s is refused",c.name)
            continue
        }
        if !testing.expectf(t,error==.None,"%s gets a rig",c.name) {continue}
        for j in made.joints {
            m:=j.inverse_bind
            for k in 0..<4 {for l in 0..<4 {testing.expectf(t,m[k,l]-m[k,l]==0,"%s: the binds are finite",c.name)}}
        }
    }
}
