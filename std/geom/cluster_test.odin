package geom

import "core:math"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

// A closed torus welded by position, its outer half of submesh 1 with
// vertices of its own on the outline between the halves, and a uv per
// vertex: attributes are the normal and the uv.
@(private="file")
Two_Part_Torus :: struct {
    positions:[dynamic]Vec3,
    indices:[dynamic]u32,
    attributes:[dynamic]f32,
    ranges:[2]Cluster_Range,
}

@(private="file")
two_part_torus :: proc(out:^Two_Part_Torus,segments,sides:int) {
    raw:Mesh_Buffer
    mesh_buffer_init(&raw,context.temp_allocator)
    torus_build(&raw,1,0.35,segments,sides)
    welded:Mesh_Buffer
    mesh_buffer_init(&welded,context.temp_allocator)
    mesh_weld({positions=raw.positions[:],indices=raw.indices[:]},0,&welded)
    out.positions=make([dynamic]Vec3,context.temp_allocator)
    out.indices=make([dynamic]u32,context.temp_allocator)
    out.attributes=make([dynamic]f32,context.temp_allocator)
    // The vertex of each welded one in each part.
    of:=make([][2]u32,len(welded.positions),context.temp_allocator)
    for &o in of {o={NONE,NONE}}
    for part in 0..<2 {
        out.ranges[part]={u32(len(out.indices)),0,u32(part)}
        for t:=0;t<len(welded.indices);t+=3 {
            c:=(welded.positions[welded.indices[t]]+welded.positions[welded.indices[t+1]]+welded.positions[welded.indices[t+2]])/3
            outer:=c.x*c.x+c.z*c.z>1
            if outer!=(part==1) {continue}
            for index in welded.indices[t:t+3] {
                if of[index][part]==NONE {
                    of[index][part]=u32(len(out.positions))
                    p:=welded.positions[index]
                    append(&out.positions,p)
                    ring:=Vec3{p.x,0,p.z}*(1/math.sqrt(p.x*p.x+p.z*p.z))
                    n:=p-ring
                    n*=1/math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)
                    append(&out.attributes,n.x,n.y,n.z,p.x*0.25+f32(part),p.z*0.25)
                }
                append(&out.indices,of[index][part])
            }
        }
        out.ranges[part].index_count=u32(len(out.indices))-out.ranges[part].first_index
    }
}

// The edges by position used an odd number of times: a surface without
// cracks has none. A root may fold over itself, using an edge four times.
@(private="file")
open_edges :: proc(positions:[]Vec3,indices:[]u32) -> int {
    weld:=make([]u32,len(positions),context.temp_allocator)
    positions_weld(positions,0,weld)
    uses:=make(map[[2]u32]int,context.temp_allocator)
    for t:=0;t<len(indices);t+=3 {
        for k in 0..<3 {
            a,b:=weld[indices[t+k]],weld[indices[t+(k+1)%3]]
            uses[{min(a,b),max(a,b)}]+=1
        }
    }
    open:=0
    for _,n in uses {if n%2!=0 {open+=1}}
    return open
}

@(private="file")
projected :: proc(lod:Cluster_Lod,camera:Vec3) -> f32 {
    d:=lod.center-camera
    distance:=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)-lod.radius
    return lod.error/max(distance,0.01)
}

// The mesh indices of the clusters the cut at threshold from camera draws.
@(private="file")
cut :: proc(dag:^Cluster_Dag,camera:Vec3,threshold:f32) -> [dynamic]u32 {
    indices:=make([dynamic]u32,context.temp_allocator)
    for c in dag.clusters {
        if projected(c.own,camera)<=threshold && projected(c.parent,camera)>threshold {
            for k in 0..<c.triangle_count*3 {append(&indices,dag.vertices[c.first_vertex+u32(dag.triangles[c.first_triangle*3+k])])}
        }
    }
    return indices
}

@(test)
meshlets_hold_every_triangle_once_within_their_limits :: proc(t:^testing.T) {
    torus:Two_Part_Torus
    two_part_torus(&torus,96,48)
    meshlets:=make([]Meshlet,meshlets_bound(len(torus.indices),64,20),context.temp_allocator)
    vertices:=make([]u32,len(torus.indices),context.temp_allocator)
    triangles:=make([]u8,len(torus.indices),context.temp_allocator)
    count,failed:=meshlets_build(meshlets,vertices,triangles,torus.indices[:],torus.positions[:],64,20,64,0.25,2)
    testing.expect_value(t,failed,Meshlet_Error.None)
    seen:=make(map[[3]u32]int,context.temp_allocator)
    for m in meshlets[:count] {
        testing.expect(t,m.vertex_count<=64 && m.triangle_count<=64 && m.triangle_count>0)
        for k in 0..<m.triangle_count {
            local:=triangles[m.triangle_offset+k*3:][:3]
            testing.expect(t,u32(local[0])<m.vertex_count && u32(local[1])<m.vertex_count && u32(local[2])<m.vertex_count)
            seen[{vertices[m.vertex_offset+u32(local[0])],vertices[m.vertex_offset+u32(local[1])],vertices[m.vertex_offset+u32(local[2])]}]+=1
        }
    }
    for i:=0;i<len(torus.indices);i+=3 {
        key:=[3]u32{torus.indices[i],torus.indices[i+1],torus.indices[i+2]}
        if seen[key]!=1 {testing.expectf(t,false,"triangle %d is in %d clusters",i/3,seen[key]);return}
    }
    again:=make([]Meshlet,len(meshlets),context.temp_allocator)
    again_count,_:=meshlets_build(again,vertices,triangles,torus.indices[:],torus.positions[:],64,20,64,0.25,2)
    testing.expect(t,again_count==count && bytes_equal(again[:count],meshlets[:count]))
    // Limits out of range and short outputs are refused.
    _,failed=meshlets_build(meshlets,vertices,triangles,torus.indices[:],torus.positions[:],257,20,64)
    testing.expect_value(t,failed,Meshlet_Error.Invalid_Settings)
    _,failed=meshlets_build(meshlets[:1],vertices,triangles,torus.indices[:],torus.positions[:],64,20,64)
    testing.expect_value(t,failed,Meshlet_Error.Invalid_Settings)
    _,failed=meshlets_build(meshlets,vertices,triangles,{0,1,99999},torus.positions[:],64,20,64)
    testing.expect_value(t,failed,Meshlet_Error.Invalid_Mesh)
}

@(test)
cluster_bounds_hold_their_vertices_and_the_cone_culls_only_back_faces :: proc(t:^testing.T) {
    torus:Two_Part_Torus
    two_part_torus(&torus,64,32)
    meshlets:=make([]Meshlet,meshlets_bound(len(torus.indices),CLUSTER_MAX_VERTICES,CLUSTER_MIN_TRIANGLES),context.temp_allocator)
    vertices:=make([]u32,len(torus.indices),context.temp_allocator)
    triangles:=make([]u8,len(torus.indices),context.temp_allocator)
    count,_:=meshlets_build(meshlets,vertices,triangles,torus.indices[:],torus.positions[:],CLUSTER_MAX_VERTICES,CLUSTER_MIN_TRIANGLES,CLUSTER_MAX_TRIANGLES,0.5)
    rng:=base.rng_make(3)
    culled:=0
    for m in meshlets[:count] {
        indices:=make([]u32,m.triangle_count*3,context.temp_allocator)
        for k in 0..<len(indices) {indices[k]=vertices[m.vertex_offset+u32(triangles[m.triangle_offset+u32(k)])]}
        b:=cluster_bounds(indices,torus.positions[:])
        for index in indices {
            d:=torus.positions[index]-b.center
            if math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)>b.radius*(1+1e-5) {testing.expect(t,false,"a vertex is outside the sphere of its cluster");return}
        }
        for _ in 0..<32 {
            camera:=mm.random_in_sphere(&rng)*4
            d:=b.cone_apex-camera
            l:=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
            if l==0 || (d.x*b.cone_axis.x+d.y*b.cone_axis.y+d.z*b.cone_axis.z)/l<b.cone_cutoff {continue}
            culled+=1
            for i:=0;i<len(indices);i+=3 {
                p0,p1,p2:=torus.positions[indices[i]],torus.positions[indices[i+1]],torus.positions[indices[i+2]]
                n:=Vec3{(p1-p0).y*(p2-p0).z-(p1-p0).z*(p2-p0).y,(p1-p0).z*(p2-p0).x-(p1-p0).x*(p2-p0).z,(p1-p0).x*(p2-p0).y-(p1-p0).y*(p2-p0).x}
                v:=p0-camera
                if n.x*v.x+n.y*v.y+n.z*v.z<-1e-6 {testing.expect(t,false,"the cone culls a cluster with a front face");return}
            }
        }
    }
    testing.expect(t,culled>0,"some cameras see clusters from behind")
    center,radius:=spheres_bound({{0,0,0},{4,0,0},{0,3,0}},{1,0.5,2})
    for s in ([3][2]Vec3{{{0,0,0},{1,0,0}},{{4,0,0},{0.5,0,0}},{{0,3,0},{2,0,0}}}) {
        d:=s[0]-center
        testing.expect(t,math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)+s[1].x<=radius*(1+1e-5),"the sphere holds every sphere")
    }
    local_vertices:[8]u32
    local_triangles:[6]u8
    testing.expect_value(t,meshlet_local_indices(local_vertices[:],local_triangles[:],{7,9,7,9,3,5}),4)
    testing.expect(t,local_vertices[local_triangles[4]]==3 && local_vertices[local_triangles[2]]==7)
}

@(test)
partition_makes_groups_of_about_the_target_and_joins_near_pieces :: proc(t:^testing.T) {
    // Small cubes in a grid that touch nothing: only places join them.
    positions:=make([dynamic]Vec3,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    counts:=make([dynamic]u32,context.temp_allocator)
    cube:Mesh_Buffer
    mesh_buffer_init(&cube,context.temp_allocator)
    cube_build(&cube,{0.2,0.2,0.2})
    for x in 0..<10 {for z in 0..<10 {
        first:=u32(len(positions))
        for p in cube.positions {append(&positions,p+Vec3{f32(x),0,f32(z)})}
        for index in cube.indices {append(&indices,first+index)}
        append(&counts,u32(len(cube.indices)))
    }}
    groups:=make([]u32,len(counts),context.temp_allocator)
    count,failed:=clusters_partition(groups,indices[:],counts[:],positions[:],8)
    testing.expect_value(t,failed,Partition_Error.None)
    sizes:=make([]int,count,context.temp_allocator)
    for g in groups {sizes[g]+=1}
    for s in sizes {testing.expect(t,s>=1 && s<=8+8/3)}
    testing.expectf(t,count<=len(counts)/4,"%d groups of %d pieces",count,len(counts))
    // Each group is a patch of neighbors, not pieces from across the grid.
    for g in 0..<count {
        lo,hi:=Vec3{max(f32),max(f32),max(f32)},Vec3{-max(f32),-max(f32),-max(f32)}
        for group,c in groups {
            if int(group)!=g {continue}
            p:=positions[c*len(cube.positions)]
            lo,hi={min(lo.x,p.x),0,min(lo.z,p.z)},{max(hi.x,p.x),0,max(hi.z,p.z)}
        }
        testing.expectf(t,hi.x-lo.x<=4 && hi.z-lo.z<=4,"group %d spans %v",g,hi-lo)
    }
    again:=make([]u32,len(counts),context.temp_allocator)
    clusters_partition(again,indices[:],counts[:],positions[:],8)
    testing.expect(t,bytes_equal(again,groups))
    _,failed=clusters_partition(groups,indices[:],counts[:2],positions[:],8)
    testing.expect_value(t,failed,Partition_Error.Invalid_Clusters)
}

// The checks a DAG passes whatever the mesh: limits, submeshes, errors that
// grow to the roots, group borders kept, and cuts without cracks.
@(private)
dag_check :: proc(t:^testing.T,dag:^Cluster_Dag,positions:[]Vec3,indices:[]u32,ranges:[]Cluster_Range,closed:bool,loc:=#caller_location) {
    submesh_of:=make(map[u32]u32,context.temp_allocator)
    for r in ranges {for index in indices[r.first_index:][:r.index_count] {submesh_of[index]=r.submesh}}
    triangles_of_level0:=0
    for c in dag.clusters {
        if c.triangle_count>CLUSTER_MAX_TRIANGLES || c.vertex_count>CLUSTER_MAX_VERTICES || c.triangle_count==0 {testing.expectf(t,false,"a cluster of %d triangles and %d vertices",c.triangle_count,c.vertex_count,loc=loc);return}
        for v in dag.vertices[c.first_vertex:][:c.vertex_count] {
            if submesh_of[v]!=c.submesh {testing.expect(t,false,"a cluster crosses submeshes",loc=loc);return}
        }
        if c.level==0 {triangles_of_level0+=int(c.triangle_count)}
        // The parent is reached later, by a sphere around this one.
        d:=c.parent.center-c.own.center
        if !(c.own.error<=c.parent.error) || math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)+c.own.radius>c.parent.radius*1.0001+1e-6 {
            testing.expectf(t,false,"cluster of level %d: own %v, parent %v",c.level,c.own,c.parent,loc=loc)
            return
        }
    }
    testing.expect_value(t,triangles_of_level0,len(indices)/3,loc=loc)
    // Levels in order, the clusters of a group contiguous, and the generator
    // of a cluster a group of the level before whose parent is its own.
    group_parent:=make(map[u32]Cluster_Lod,context.temp_allocator)
    group_level:=make(map[u32]u32,context.temp_allocator)
    for c,at in dag.clusters {
        if at>0 {
            previous:=dag.clusters[at-1]
            if c.level<previous.level || c.group!=previous.group && c.group in group_parent {testing.expectf(t,false,"cluster %d is out of the order of levels and groups",at,loc=loc);return}
        }
        group_parent[c.group]=c.parent
        group_level[c.group]=c.level
        if c.level==0 {
            if c.generator!=NONE {testing.expect(t,false,"a cluster of level 0 has a generator",loc=loc);return}
        } else if parent,known:=group_parent[c.generator];!known || group_level[c.generator]+1!=c.level || parent!=c.own {
            testing.expectf(t,false,"cluster %d of level %d names a generator that did not make it",at,c.level,loc=loc)
            return
        }
    }
    // Every group keeps its border: what it was simplified into has the open
    // edges it had. Groups whose clusters have one parent are taken together,
    // since what they were simplified into is found by that parent.
    done:=make(map[Cluster_Lod]bool,context.temp_allocator)
    for g in dag.clusters {
        if g.parent.error==max(f32) || g.parent in done {continue}
        done[g.parent]=true
        before,after:=make([dynamic]u32,context.temp_allocator),make([dynamic]u32,context.temp_allocator)
        for c in dag.clusters {
            if c.level==g.level && c.parent==g.parent {
                for k in 0..<c.triangle_count*3 {append(&before,dag.vertices[c.first_vertex+u32(dag.triangles[c.first_triangle*3+k])])}
            }
            if c.level==g.level+1 && c.own==g.parent {
                for k in 0..<c.triangle_count*3 {append(&after,dag.vertices[c.first_vertex+u32(dag.triangles[c.first_triangle*3+k])])}
            }
        }
        if !edges_open_equal(positions,before[:],after[:]) {testing.expectf(t,false,"group %d at level %d moved its border",g.group,g.level,loc=loc);return}
    }
    // Cuts from cameras near and far, at thresholds fine and coarse.
    rng:=base.rng_make(11)
    for _ in 0..<24 {
        camera:=mm.random_in_sphere(&rng)*f32(1+rng_int(&rng,40))
        threshold:=f32(rng_int(&rng,6))*0.02
        drawn:=cut(dag,camera,threshold)
        if closed {
            if open:=open_edges(positions,drawn[:]);open!=0 {testing.expectf(t,false,"a cut from %v at %f has %d open edges",camera,threshold,open,loc=loc);return}
        } else if !edges_open_equal(positions,indices,drawn[:],ends_only=true) {
            testing.expectf(t,false,"a cut from %v at %f opens an edge inside the surface",camera,threshold,loc=loc)
            return
        }
    }
}

@(private="file")
rng_int :: proc(r:^base.Rng,below:int) -> int {return int(base.rng_u32(r)%u32(below))}

// Whether two triangle lists have the same open edges by position; with
// ends_only, whether every open edge of b joins places on open edges of a.
@(private)
edges_open_equal :: proc(positions:[]Vec3,a,b:[]u32,ends_only:=false) -> bool {
    weld:=make([]u32,len(positions),context.temp_allocator)
    positions_weld(positions,0,weld)
    open :: proc(weld,indices:[]u32) -> map[[2]u32]int {
        uses:=make(map[[2]u32]int,context.temp_allocator)
        for t:=0;t<len(indices);t+=3 {
            for k in 0..<3 {
                p,q:=weld[indices[t+k]],weld[indices[t+(k+1)%3]]
                if p!=q {uses[{min(p,q),max(p,q)}]+=1}
            }
        }
        result:=make(map[[2]u32]int,context.temp_allocator)
        for edge,n in uses {if n==1 {result[edge]=1}}
        return result
    }
    oa,ob:=open(weld,a),open(weld,b)
    if ends_only {
        ends:=make(map[u32]bool,context.temp_allocator)
        for edge in oa {ends[edge[0]]=true;ends[edge[1]]=true}
        for edge in ob {if !ends[edge[0]] || !ends[edge[1]] {return false}}
        return true
    }
    if len(oa)!=len(ob) {return false}
    for edge in oa {if edge not_in ob {return false}}
    return true
}

@(test)
cluster_dag_of_a_closed_mesh_cuts_without_cracks_and_is_deterministic :: proc(t:^testing.T) {
    torus:Two_Part_Torus
    two_part_torus(&torus,128,64)
    weights:=[]f32{0.5,0.5,0.5,1,1}
    source:=Cluster_Source{positions=torus.positions[:],indices=torus.indices[:],ranges=torus.ranges[:],attributes=torus.attributes[:],attribute_weights=weights}
    dag:Cluster_Dag
    defer cluster_dag_destroy(&dag)
    failed:=cluster_dag_build(&dag,source)
    testing.expect_value(t,failed,Cluster_Error.None)
    testing.expectf(t,dag.levels>=4,"%d levels",dag.levels)
    roots:=0
    root_triangles:=0
    for c in dag.clusters {
        if c.parent.error==max(f32) {
            roots+=1
            root_triangles+=int(c.triangle_count)
        }
    }
    testing.expectf(t,root_triangles<len(torus.indices)/3/16,"the roots have %d triangles of %d",root_triangles,len(torus.indices)/3)
    dag_check(t,&dag,torus.positions[:],torus.indices[:],torus.ranges[:],true)
    again:Cluster_Dag
    defer cluster_dag_destroy(&again)
    cluster_dag_build(&again,source)
    testing.expect(t,bytes_equal(again.clusters[:],dag.clusters[:]) && bytes_equal(again.vertices[:],dag.vertices[:]) && bytes_equal(again.triangles[:],dag.triangles[:]))
    // Locked vertices stop the groups around them, whose borders stay next to every level above.
    lock:=make([]Simplify_Vertex,len(torus.positions),context.temp_allocator)
    for p,v in torus.positions {if p.x>0.3 {lock[v]={.Lock}}}
    locked:=source
    locked.vertex_lock=lock
    testing.expect_value(t,cluster_dag_build(&again,locked),Cluster_Error.None)
    stuck:=false
    for c in again.clusters {stuck||=c.parent.error==max(f32) && c.level+1<u32(again.levels)}
    testing.expect(t,stuck,"some groups stop below the top level")
    dag_check(t,&again,torus.positions[:],torus.indices[:],torus.ranges[:],true)
    // A vertex of two submeshes is refused.
    shared:=torus.ranges
    shared[1].first_index-=3
    shared[1].index_count+=3
    testing.expect_value(t,cluster_dag_build(&again,{positions=torus.positions[:],indices=torus.indices[:],ranges=shared[:]}),Cluster_Error.Invalid_Mesh)
}

@(test)
cluster_levels_cut_one_whole_level :: proc(t:^testing.T) {
    ball:Mesh_Buffer
    mesh_buffer_init(&ball,context.temp_allocator)
    welded(&ball,proc(out:^Mesh_Buffer) {icosphere_build(out,1,5)})
    // Three levels in one index buffer, each from level 0.
    indices:=make([dynamic]u32,context.temp_allocator)
    ranges:=make([dynamic]Cluster_Range,context.temp_allocator)
    levels:=make([dynamic]Cluster_Level,context.temp_allocator)
    destination:=make([]u32,len(ball.indices),context.temp_allocator)
    target:=len(ball.indices)
    for k in 0..<3 {
        result,_:=simplify(destination,ball.indices[:],ball.positions[:],target,max(f32),{.Error_Absolute})
        append(&levels,Cluster_Level{u32(len(ranges)),1,k==0?0:result.position_error})
        append(&ranges,Cluster_Range{u32(len(indices)),u32(result.index_count),0})
        append(&indices,..destination[:result.index_count])
        target/=4
    }
    dag:Cluster_Dag
    defer cluster_dag_destroy(&dag)
    testing.expect_value(t,cluster_levels_build(&dag,ball.positions[:],indices[:],ranges[:],levels[:]),Cluster_Error.None)
    testing.expect(t,dag.levels==3 && dag.groups==3)
    per_level:[3]int
    for c in dag.clusters {per_level[c.level]+=1}
    rng:=base.rng_make(5)
    picked:[3]bool
    for _ in 0..<64 {
        camera:=mm.random_in_sphere(&rng)*f32(2+rng_int(&rng,60))
        threshold:=f32(rng_int(&rng,10))*0.002
        drawn:[3]int
        for c in dag.clusters {
            if projected(c.own,camera)<=threshold && projected(c.parent,camera)>threshold {drawn[c.level]+=1}
        }
        whole:=0
        for n,k in drawn {
            if n==per_level[k] {whole+=1;picked[k]=true} else if n!=0 {testing.expect(t,false,"a cut draws part of a level");return}
        }
        testing.expect_value(t,whole,1)
    }
    testing.expect(t,picked[0] && picked[2],"near the first level, far the last")
}
