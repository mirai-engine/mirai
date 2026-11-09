package geom

import "base:runtime"
import "core:slice"

// Approximate convex decomposition: a few convex hulls that together stand
// for a mesh that is not convex, as the collider of a body needs. The mesh is
// taken apart by its islands and then cut, one part at a time, with the
// axis-aligned plane that leaves the least concavity, until every part is as
// convex as asked or there are as many parts as allowed. The concavity of a
// part is the volume its hull adds over it, so the measure and the cuts,
// which cap what they open, are those of a closed mesh: an open one is still
// covered by hulls, cut by a measure that means less.

DECOMPOSE_DEFAULT_HULLS :: 8
DECOMPOSE_DEFAULT_HULL_VERTICES :: 32
DECOMPOSE_DEFAULT_CONCAVITY :: 0.01
DECOMPOSE_DEFAULT_PLANES :: 5

Decompose_Desc :: struct {
    max_hulls:int,         // 0: DECOMPOSE_DEFAULT_HULLS
    max_hull_vertices:int, // 0: DECOMPOSE_DEFAULT_HULL_VERTICES; a hull bounded by it lies inside the hull of its part
    // A part is cut while its hull adds more volume over it than this share
    // of the volume of the hull of the whole mesh. 0: DECOMPOSE_DEFAULT_CONCAVITY.
    concavity:f32,
    planes_per_axis:int,   // cuts tried along each axis of a part, evenly spaced inside it. 0: DECOMPOSE_DEFAULT_PLANES
    tolerance:f32,         // of the cuts and the hulls. 0: tolerance_noise of the mesh
}

Decompose_Error :: enum {
    None,
    Invalid_Mesh,
    No_Volume, // the points of the mesh span no volume: there is no hull to give
    Out_Of_Memory,
}

Decomposition :: struct {
    hulls:[]Hull,
    volume:f32,      // of the hulls, added
    mesh_volume:f32, // of what the triangles of the mesh enclose
    concavity:f32,   // what the hulls of the parts add over them, as a share of the hull of the mesh
    allocator:runtime.Allocator,
}

decomposition_destroy :: proc(d:^Decomposition) {
    for &hull in d.hulls {hull_destroy(&hull)}
    delete(d.hulls,d.allocator)
    d^={}
}

@(private="file")
Part :: struct {
    mesh:Mesh_Buffer,
    concavity:f32,
    whole:bool, // no cut improves it
}

@(private="file")
part_concavity :: proc(positions:[]Vec3,indices:[]u32,tolerance:f32) -> f32 {
    return max(points_hull_volume(positions,{tolerance=tolerance})-abs(mesh_volume(positions,indices)),0)
}

mesh_decompose :: proc(mesh:Mesh,desc:Decompose_Desc={},allocator:=context.allocator) -> (result:Decomposition,error:Decompose_Error) {
    if !mesh_is_valid(mesh) || desc.max_hulls<0 || desc.max_hull_vertices<0 || desc.planes_per_axis<0 || !(desc.concavity>=0) || !(desc.tolerance>=0) {return {},.Invalid_Mesh}
    for p in mesh.positions {
        if !(abs(p.x)<=max(f32) && abs(p.y)<=max(f32) && abs(p.z)<=max(f32)) {return {},.Invalid_Mesh}
    }
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(allocator))
    scratch:=context.temp_allocator
    max_hulls:=desc.max_hulls>0?desc.max_hulls:DECOMPOSE_DEFAULT_HULLS
    max_vertices:=max(desc.max_hull_vertices>0?desc.max_hull_vertices:DECOMPOSE_DEFAULT_HULL_VERTICES,4)
    planes:=desc.planes_per_axis>0?desc.planes_per_axis:DECOMPOSE_DEFAULT_PLANES
    share:=desc.concavity>0?desc.concavity:DECOMPOSE_DEFAULT_CONCAVITY

    // One vertex per point, so that islands and cuts see the surface whole.
    source:Mesh_Buffer
    mesh_buffer_init(&source,scratch)
    mesh_weld({positions=mesh.positions,indices=mesh.indices},0,&source)
    tolerance:=max(desc.tolerance,tolerance_noise(positions_max_abs(source.positions[:])))
    whole_hull:=points_hull_volume(source.positions[:],{tolerance=tolerance})
    if !(whole_hull>0) {return {},.No_Volume}
    threshold:=share*whole_hull

    parts:=make([dynamic]Part,0,max_hulls,scratch)
    // The islands of the mesh, the largest first; when there are more than
    // hulls allowed the smallest share the last part.
    {
        triangles:=len(source.indices)/3
        labels:=make([]u32,triangles,scratch)
        islands:=mesh_components(source.positions[:],source.indices[:],labels)
        Island :: struct {label:u32,volume:f32}
        order:=make([]Island,islands,scratch)
        for &island,i in order {island.label=u32(i)}
        if islands>1 {
            lo:=make([]Vec3,islands,scratch)
            hi:=make([]Vec3,islands,scratch)
            seen:=make([]bool,islands,scratch)
            for t in 0..<triangles {
                l:=labels[t]
                for k in 0..<3 {
                    p:=source.positions[source.indices[t*3+k]]
                    if !seen[l] {lo[l],hi[l],seen[l]=p,p,true}
                    for axis in 0..<3 {lo[l][axis],hi[l][axis]=min(lo[l][axis],p[axis]),max(hi[l][axis],p[axis])}
                }
            }
            for &island,i in order {
                size:=hi[i]-lo[i]
                island.volume=size.x*size.y*size.z
            }
            slice.stable_sort_by(order,proc(a,b:Island) -> bool {return a.volume>b.volume})
        }
        part_of:=make([]int,islands,scratch)
        for island,rank in order {part_of[island.label]=min(rank,max_hulls-1)}
        count:=min(islands,max_hulls)
        remap:=make([]u32,len(source.positions),scratch)
        for index in 0..<count {
            part:Part
            mesh_buffer_init(&part.mesh,scratch)
            for &r in remap {r=NONE}
            for t in 0..<triangles {
                if part_of[labels[t]]!=index {continue}
                for k in 0..<3 {
                    v:=source.indices[t*3+k]
                    if remap[v]==NONE {
                        remap[v]=u32(len(part.mesh.positions))
                        append(&part.mesh.positions,source.positions[v])
                    }
                    append(&part.mesh.indices,remap[v])
                }
            }
            part.concavity=part_concavity(part.mesh.positions[:],part.mesh.indices[:],tolerance)
            append(&parts,part)
        }
    }

    slicer:Slicer
    slicer_init(&slicer,scratch)
    front,back,best_front,best_back:Mesh_Buffer
    mesh_buffer_init(&front,scratch);mesh_buffer_init(&back,scratch)
    for len(parts)<max_hulls {
        chosen:=-1
        for part,i in parts {
            if part.whole || !(part.concavity>threshold) {continue}
            if chosen<0 || part.concavity>parts[chosen].concavity {chosen=i}
        }
        if chosen<0 {break}
        part:=&parts[chosen]
        view:=mesh_buffer_view(&part.mesh)
        lo,hi:=mesh_bounds(view.positions)
        found:=false
        best,best_front_concavity,best_back_concavity:=part.concavity,f32(0),f32(0)
        best_plane:Plane
        for axis in 0..<3 {
            for step in 1..=planes {
                normal:Vec3
                normal[axis]=1
                plane:=Plane{normal,lo[axis]+(hi[axis]-lo[axis])*f32(step)/f32(planes+1)}
                _,slice_error:=mesh_slice(&slicer,view,plane,&front,&back,{tolerance=tolerance})
                if slice_error==.Out_Of_Memory {return {},.Out_Of_Memory}
                if slice_error!=.None {continue}
                if len(front.indices)==0 || len(back.indices)==0 {continue}
                front_concavity:=part_concavity(front.positions[:],front.indices[:],tolerance)
                back_concavity:=part_concavity(back.positions[:],back.indices[:],tolerance)
                if !(front_concavity+back_concavity<best) {continue}
                found,best,best_plane=true,front_concavity+back_concavity,plane
                best_front_concavity,best_back_concavity=front_concavity,back_concavity
            }
        }
        if !found {
            part.whole=true
            continue
        }
        mesh_buffer_init(&best_front,scratch);mesh_buffer_init(&best_back,scratch)
        if _,slice_error:=mesh_slice(&slicer,view,best_plane,&best_front,&best_back,{tolerance=tolerance});slice_error!=.None {return {},.Out_Of_Memory}
        part^={mesh=best_front,concavity=best_front_concavity}
        append(&parts,Part{mesh=best_back,concavity=best_back_concavity})
    }

    hulls,no_hulls:=make([dynamic]Hull,0,len(parts),allocator)
    if no_hulls!=nil {return {},.Out_Of_Memory}
    left:=f32(0)
    for &part in parts {
        hull,hull_error:=hull_build(part.mesh.positions[:],{max_vertices=max_vertices,tolerance=tolerance},allocator)
        if hull_error==.Out_Of_Memory {
            for &built in hulls {hull_destroy(&built)}
            delete(hulls)
            return {},.Out_Of_Memory
        }
        if hull_error!=.None {continue}
        if hull_is_flat(hull) {
            hull_destroy(&hull)
            continue
        }
        append(&hulls,hull)
        result.volume+=hull_mass_properties(hull).volume
        left+=part.concavity
    }
    if len(hulls)==0 {
        delete(hulls)
        return {},.No_Volume
    }
    result.hulls=hulls[:]
    result.mesh_volume=abs(mesh_volume(source.positions[:],source.indices[:]))
    result.concavity=left/whole_hull
    result.allocator=allocator
    return
}
