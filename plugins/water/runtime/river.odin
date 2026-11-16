package water

import "core:math/linalg"
import "core:mem"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import geom "mirai:std/geom"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The surface of water along a path (a river): a ribbon along the curve of the
// points the physics follows (phys.fluid_path, mm.path_sample), level across
// from bank to bank, made again only when those points or the waters they meet
// change. Where another water holds the river, as the physics decides by
// priority, that one draws and the ribbon ends. Its vertex colors carry the
// flow of each point (water_surface.slang FLOW_REACH): the small waves of its
// surface drift with it.

FLOW_REACH :: f32(8) // m/s of flow the colors of a ribbon carry, either way along x and z
@(private) RIVER_SAMPLES :: 4096 // of the curve of a ribbon, 1 m apart or farther on a longer river

@(private)
Ribbon :: struct {
    entity:core.Entity,
    mesh:base.Asset_Id,
    key:u64,
    seen:u64,
}

// Whether another water of the frame holds a point of a river instead of it: it holds the point under its
// still surface and the physics takes it there, by a higher priority or, at the same one, an earlier slot.
@(private)
river_yields :: proc(physics:core.Ref(phys.Physics_State),found:[]phys.Fluid_Info,river:int,p:[3]f32) -> bool {
    mine:=found[river].desc.priority
    for other,i in found {
        d:=other.desc
        if i==river || d.density<=0 || d.priority<mine || d.priority==mine && i>river {continue}
        if d.shape==.Plane ? p.y<=d.position.y : phys.fluid_holds(physics,other.fluid,p) {return true}
    }
    return false
}

// The ribbon of the river `river` of found along its samples, from where it starts to be its own water to
// where another takes it; false with no part of it its own.
@(private)
ribbon_build :: proc(physics:core.Ref(phys.Physics_State),found:[]phys.Fluid_Info,river:int,curve:[]mm.Path_Point,out:^geom.Mesh_Buffer,tangents:^[dynamic][4]f32) -> bool {
    count:=len(curve)
    if count<2 {return false}
    // A point a little under the surface, which the river holds while it is its own.
    under :: proc(p:mm.Path_Point) -> [3]f32 {return p.position-{0,0.05*p.height,0}}
    own:=make([]bool,count,context.temp_allocator)
    for p,j in curve {own[j]=!river_yields(physics,found,river,under(p))}
    current:=found[river].desc.current
    section :: proc(out:^geom.Mesh_Buffer,tangents:^[dynamic][4]f32,p:mm.Path_Point,along,current:[3]f32,run:^int) {
        across:=linalg.normalize0([3]f32{-along.z,0,along.x})
        n:=linalg.normalize0(linalg.cross(across,along))
        if n.y<=0 {n={0,1,0}}
        // Along it at the speed of the point, and across by the current: +X to its right.
        flow:=across*current.x+along*p.speed
        color:=[4]f32{0.5+0.5*clamp(flow.x/FLOW_REACH,-1,1),0.5+0.5*clamp(flow.z/FLOW_REACH,-1,1),0,1}
        x:=linalg.normalize0([3]f32{1,0,0}-n*n.x)
        for side in ([2]f32{-1,1}) {
            at:=p.position+across*(side*0.5*p.width)
            append(&out.positions,at)
            append(&out.normals,n)
            append(&out.uvs,[2]f32{at.x,at.z})
            append(&out.colors,color)
            append(tangents,[4]f32{x.x,x.y,x.z,-1})
        }
        if run^>0 {
            // From the section before to this one, counter-clockwise seen from above.
            a:=u32(len(out.positions)-4)
            append(&out.indices,a,a+2,a+1,a+1,a+2,a+3)
        }
        run^+=1
    }
    // The way of the path at a sample: from the sample before it to the one after it.
    along :: proc(curve:[]mm.Path_Point,j:int) -> [3]f32 {
        a,b:=curve[max(j-1,0)].position,curve[min(j+1,len(curve)-1)].position
        return linalg.normalize0(b-a)
    }
    // Where between two samples the river stops being its own (from_own), or starts to be: by halves.
    edge :: proc(physics:core.Ref(phys.Physics_State),found:[]phys.Fluid_Info,river:int,a,b:mm.Path_Point,from_own:bool) -> mm.Path_Point {
        mix :: proc(a,b:mm.Path_Point,t:f32) -> mm.Path_Point {
            return {a.position+(b.position-a.position)*t,a.width+(b.width-a.width)*t,a.height+(b.height-a.height)*t,a.speed+(b.speed-a.speed)*t}
        }
        lo,hi:=f32(0),f32(1)
        for _ in 0..<12 {
            mid:=0.5*(lo+hi)
            p:=mix(a,b,mid)
            if !river_yields(physics,found,river,under(p))==from_own {lo=mid} else {hi=mid}
        }
        return mix(a,b,from_own?lo:hi)
    }
    run:=0
    for j in 0..<count {
        if own[j] {
            if run==0 && j>0 {section(out,tangents,edge(physics,found,river,curve[j-1],curve[j],false),along(curve,j),current,&run)}
            section(out,tangents,curve[j],along(curve,j),current,&run)
        } else if run>0 {
            section(out,tangents,edge(physics,found,river,curve[j-1],curve[j],true),along(curve,j),current,&run)
            run=0
        }
    }
    return len(out.indices)>0
}

// The ribbon of each river of the frame, made again when its key changes; those of rivers no longer drawn
// go in ribbons_release.
@(private)
ribbon_place :: proc(state:^Water_Gpu,app:^host.App,physics:core.Ref(phys.Physics_State),found:[]phys.Fluid_Info,river:int,material:u32) {
    info:=found[river]
    points:[phys.FLUID_PATH_POINTS]mm.Path_Point
    count:=phys.fluid_path(physics,info.fluid,&points)
    key:=base.hash64(mem.slice_to_bytes(points[:count]),base.hash64(mem.ptr_to_bytes(&found[river].desc)))
    for &other in found {
        if other.entity!=info.entity && other.desc.density>0 {key=base.hash64(mem.ptr_to_bytes(&other.desc),key)}
    }
    at:=-1
    for &r,i in state.ribbons {
        if r.mesh!={} && r.entity==info.entity {at=i;break}
        if r.mesh=={} && at<0 {at=i}
    }
    if at<0 {return}
    r:=&state.ribbons[at]
    r.seen=state.frame
    if r.mesh=={} || r.key!=key || r.entity!=info.entity {
        buffer:geom.Mesh_Buffer
        geom.mesh_buffer_init(&buffer,context.temp_allocator)
        tangents:=make([dynamic][4]f32,context.temp_allocator)
        id:base.Asset_Id
        curve:=make([]mm.Path_Point,RIVER_SAMPLES,context.temp_allocator)
        if ribbon_build(physics,found,river,curve[:mm.path_sample(points[:count],1,curve)],&buffer,&tangents) {
            id,_=host.assets_mesh_generate(app.assets,geom.mesh_buffer_view(&buffer),options={no_lods=true,tangents=tangents[:]})
        }
        if r.mesh!={} {host.assets_mesh_release(app.assets,r.mesh)}
        r^={entity=info.entity,mesh=id,key=key,seen=state.frame}
        if id=={} {return}
    }
    instance,usable:=render.mesh_instance(app.assets,{mesh=r.mesh},mm.MAT4_IDENTITY)
    if !usable {return}
    instance.material=render.Material_Handle(material)
    instance.object_id,instance.copy_owner=u64(info.entity),base.name_hash("water")
    render.instance_add(&app.extras,instance)
}

// The ribbons of rivers no frame drew go.
@(private)
ribbons_release :: proc(state:^Water_Gpu,assets:^host.Assets) {
    for &r in state.ribbons {
        if r.mesh=={} || r.seen==state.frame {continue}
        if assets!=nil {host.assets_mesh_release(assets,r.mesh)}
        r={}
    }
}
