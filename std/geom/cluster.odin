package geom

import "base:runtime"
import "core:math"

// Clusters of a triangle mesh and their bounds: a port of the meshlet
// builder of meshoptimizer 1.3 (meshopt_buildMeshletsFlex in
// src/clusterizer.cpp and the bounds of src/meshletutils.cpp, MIT, Arseny
// Kapoulkine), with the same arithmetic and order.
//
// A cluster grows from a seed by the adjacent triangle that adds the fewest
// vertices, preferring those that would be left dangling, then the nearest
// to its center (and, with a cone weight, to its normal). When no adjacent
// triangle is left a kd-tree of centroids gives the nearest one; with a
// split factor, one farther than that many expected radii starts a new
// cluster once the current has min_triangles. A full cluster continues from
// the seed of fewest live neighbors nearest a corner of the mesh, which
// keeps the clusters flowing across the surface.
//
// Based on: Wihlidal, Optimizing the graphics pipeline with compute (2016);
// Ritter, An efficient bounding sphere (1990); Larsson, Fast and tight
// fitting bounding spheres (2008).

// A cluster as meshlets_build writes it: its vertices are
// meshlet_vertices[vertex_offset:][:vertex_count], vertices of the mesh, and
// its triangles meshlet_triangles[triangle_offset:][:triangle_count*3],
// indices into those.
Meshlet :: struct {vertex_offset,triangle_offset,vertex_count,triangle_count:u32}

MESHLET_MAX_VERTICES  :: 256 // local indices are bytes
MESHLET_MAX_TRIANGLES :: 512

Meshlet_Error :: enum u8 {None,Invalid_Mesh,Invalid_Settings,Out_Of_Memory}

// The bounds of a cluster: a sphere around its vertices and the cone of its
// normals. A camera at c sees no front face of it when
// dot(normalize(cone_apex-c),cone_axis)>=cone_cutoff; a cutoff of 1 never
// culls (a cone of a hemisphere or more, or no triangle with area).
Cluster_Bounds :: struct {
    center:Vec3,
    radius:f32,
    cone_apex:Vec3,
    cone_axis:Vec3,
    cone_cutoff:f32, // the sine of the half-angle of the cone of normals
}

@(private="file") MESHLET_MAX_SEEDS :: 256
@(private="file") MESHLET_ADD_SEEDS :: 4
@(private="file") MESHLET_MAX_TREE_DEPTH :: 50

// The most clusters meshlets_build writes for index_count indices with
// min_triangles: the size of meshlets.
meshlets_bound :: proc "contextless" (index_count,max_vertices,min_triangles:int) -> int {
    if index_count<=0 || max_vertices<3 || min_triangles<1 {return 0}
    // The worst case is a stream without shared vertices, which stresses both limits; a cluster may leave 2 vertices unused.
    max_vertices_conservative:=max_vertices-2
    by_vertices:=(index_count+max_vertices_conservative-1)/max_vertices_conservative
    by_triangles:=(index_count/3+min_triangles-1)/min_triangles
    return max(by_vertices,by_triangles)
}

@(private="file")
Triangle_Adjacency :: struct {counts,offsets,data:[]u32}

@(private="file")
Cone :: struct {px,py,pz,nx,ny,nz:f32}

@(private="file")
meshlet_score :: #force_inline proc "contextless" (distance,spread,cone_weight,expected_radius:f32) -> f32 {
    cone:=1-spread*cone_weight
    cone_clamped:=cone<1e-3?f32(1e-3):cone
    return (1+distance/expected_radius*(1-cone_weight))*cone_clamped
}

@(private="file")
meshlet_cone :: proc "contextless" (acc:Cone,triangle_count:u32) -> Cone {
    result:=acc
    center_scale:=triangle_count==0?f32(0):1/f32(triangle_count)
    result.px*=center_scale
    result.py*=center_scale
    result.pz*=center_scale
    axis_length:=result.nx*result.nx+result.ny*result.ny+result.nz*result.nz
    axis_scale:=axis_length==0?f32(0):1/math.sqrt(axis_length)
    result.nx*=axis_scale
    result.ny*=axis_scale
    result.nz*=axis_scale
    return result
}

@(private="file")
meshlet_append :: proc "contextless" (meshlet:^Meshlet,a,b,c:u32,used:[]i16,meshlets:[]Meshlet,meshlet_vertices:[]u32,meshlet_triangles:[]u8,meshlet_offset:int,max_vertices,max_triangles:int,split:bool) -> bool #no_bounds_check {
    av,bv,cv:=&used[a],&used[b],&used[c]
    result:=false
    used_extra:=int(av^<0)+int(bv^<0)+int(cv^<0)
    if int(meshlet.vertex_count)+used_extra>max_vertices || int(meshlet.triangle_count)>=max_triangles || split {
        meshlets[meshlet_offset]=meshlet^
        for j in 0..<meshlet.vertex_count {used[meshlet_vertices[meshlet.vertex_offset+j]]=-1}
        meshlet.vertex_offset+=meshlet.vertex_count
        meshlet.triangle_offset+=meshlet.triangle_count*3
        meshlet.vertex_count=0
        meshlet.triangle_count=0
        result=true
    }
    if av^<0 {
        av^=i16(meshlet.vertex_count)
        meshlet_vertices[meshlet.vertex_offset+meshlet.vertex_count]=a
        meshlet.vertex_count+=1
    }
    if bv^<0 {
        bv^=i16(meshlet.vertex_count)
        meshlet_vertices[meshlet.vertex_offset+meshlet.vertex_count]=b
        meshlet.vertex_count+=1
    }
    if cv^<0 {
        cv^=i16(meshlet.vertex_count)
        meshlet_vertices[meshlet.vertex_offset+meshlet.vertex_count]=c
        meshlet.vertex_count+=1
    }
    at:=meshlet.triangle_offset+meshlet.triangle_count*3
    meshlet_triangles[at]=u8(av^)
    meshlet_triangles[at+1]=u8(bv^)
    meshlet_triangles[at+2]=u8(cv^)
    meshlet.triangle_count+=1
    return result
}

@(private="file")
neighbor_triangle :: proc "contextless" (meshlet:Meshlet,cone:Cone,meshlet_vertices:[]u32,indices:[]u32,adjacency:^Triangle_Adjacency,triangles:[]Cone,live_triangles:[]u32,used:[]i16,expected_radius,cone_weight:f32) -> u32 #no_bounds_check {
    best_triangle:=NONE
    best_priority:=5
    best_score:=max(f32)
    for i in 0..<meshlet.vertex_count {
        index:=meshlet_vertices[meshlet.vertex_offset+i]
        neighbors:=adjacency.data[adjacency.offsets[index]:][:adjacency.counts[index]]
        for triangle in neighbors {
            a,b,c:=indices[triangle*3],indices[triangle*3+1],indices[triangle*3+2]
            extra:=int(used[a]<0)+int(used[b]<0)+int(used[c]<0)
            priority:int
            if extra==0 {
                // Adds no vertex.
                priority=0
            } else if live_triangles[a]==1 || live_triangles[b]==1 || live_triangles[c]==1 {
                // Would be left dangling, and cost more in a cluster of its own.
                priority=1
            } else if int(live_triangles[a]==2)+int(live_triangles[b]==2)+int(live_triangles[c]==2)>=2 {
                // Leaves another dangling, which keeps the flow.
                priority=1+extra
            } else {
                priority=2+extra
            }
            if priority>best_priority {continue}
            tri:=triangles[triangle]
            dx,dy,dz:=tri.px-cone.px,tri.py-cone.py,tri.pz-cone.pz
            distance:=math.sqrt(dx*dx+dy*dy+dz*dz)
            spread:=tri.nx*cone.nx+tri.ny*cone.ny+tri.nz*cone.nz
            score:=meshlet_score(distance,spread,cone_weight,expected_radius)
            if priority<best_priority || score<best_score {
                best_triangle=triangle
                best_priority=priority
                best_score=score
            }
        }
    }
    return best_triangle
}

@(private="file")
seed_triangles_append :: proc "contextless" (seeds:[]u32,meshlet:Meshlet,meshlet_vertices:[]u32,indices:[]u32,adjacency:^Triangle_Adjacency,triangles:[]Cone,live_triangles:[]u32,corner:Vec3) -> int #no_bounds_check {
    best_seeds,best_live:[MESHLET_ADD_SEEDS]u32
    best_score:[MESHLET_ADD_SEEDS]f32
    for i in 0..<MESHLET_ADD_SEEDS {
        best_seeds[i]=NONE
        best_live[i]=NONE
        best_score[i]=max(f32)
    }
    for i in 0..<meshlet.vertex_count {
        index:=meshlet_vertices[meshlet.vertex_offset+i]
        best_neighbor:=NONE
        best_neighbor_live:=NONE
        // The neighbor with the fewest live triangles.
        for triangle in adjacency.data[adjacency.offsets[index]:][:adjacency.counts[index]] {
            a,b,c:=indices[triangle*3],indices[triangle*3+1],indices[triangle*3+2]
            live:=live_triangles[a]+live_triangles[b]+live_triangles[c]
            if live<best_neighbor_live {
                best_neighbor=triangle
                best_neighbor_live=live
            }
        }
        if best_neighbor==NONE {continue}
        dx,dy,dz:=triangles[best_neighbor].px-corner.x,triangles[best_neighbor].py-corner.y,triangles[best_neighbor].pz-corner.z
        best_neighbor_score:=math.sqrt(dx*dx+dy*dy+dz*dz)
        // The list is unsorted and the replacement approximate; ties replace, which keeps fewer duplicates.
        for j in 0..<MESHLET_ADD_SEEDS {
            if best_neighbor_live<best_live[j] || (best_neighbor_live==best_live[j] && best_neighbor_score<=best_score[j]) {
                best_seeds[j]=best_neighbor
                best_live[j]=best_neighbor_live
                best_score[j]=best_neighbor_score
                break
            }
        }
    }
    seed_count:=0
    for seed in best_seeds {
        if seed!=NONE {
            seeds[seed_count]=seed
            seed_count+=1
        }
    }
    return seed_count
}

@(private="file")
seed_triangles_prune :: proc "contextless" (seeds:[]u32,emitted:[]u8) -> int #no_bounds_check {
    result:=0
    for index in seeds {
        seeds[result]=index
        result+=int(emitted[index]==0)
    }
    return result
}

@(private="file")
seed_triangle_select :: proc "contextless" (seeds:[]u32,indices:[]u32,triangles:[]Cone,live_triangles:[]u32,corner:Vec3) -> u32 #no_bounds_check {
    best_seed:=NONE
    best_live:=NONE
    best_score:=max(f32)
    for index in seeds {
        a,b,c:=indices[index*3],indices[index*3+1],indices[index*3+2]
        live:=live_triangles[a]+live_triangles[b]+live_triangles[c]
        dx,dy,dz:=triangles[index].px-corner.x,triangles[index].py-corner.y,triangles[index].pz-corner.z
        score:=math.sqrt(dx*dx+dy*dy+dz*dz)
        if live<best_live || (live==best_live && score<best_score) {
            best_seed=index
            best_live=live
            best_score=score
        }
    }
    return best_seed
}

// A leaf holds `children` points starting with its own (axis 3); a branch
// has its left subtree right after it and its right one `children` further.
@(private="file")
Kd_Node :: struct {value:u32,axis:u32,children:u32} // value: the index of a leaf point, or the bits of the split of a branch

@(private="file")
kd_point :: #force_inline proc "contextless" (triangles:[]Cone,index:u32) -> Vec3 #no_bounds_check {
    t:=triangles[index]
    return {t.px,t.py,t.pz}
}

@(private="file")
kdtree_partition :: proc "contextless" (indices:[]u32,triangles:[]Cone,axis:int,pivot:f32) -> int #no_bounds_check {
    m:=0
    // [0,m) is below the pivot and [m,i) is not.
    for i in 0..<len(indices) {
        v:=kd_point(triangles,indices[i])[axis]
        indices[m],indices[i]=indices[i],indices[m]
        m+=int(v<pivot)
    }
    return m
}

@(private="file")
kdtree_build_leaf :: proc "contextless" (offset:int,nodes:[]Kd_Node,indices:[]u32) -> int #no_bounds_check {
    nodes[offset]={indices[0],3,u32(len(indices))}
    // The other points follow the leaf.
    for i in 1..<len(indices) {nodes[offset+i]={indices[i],3,max(u32)>>2}}
    return offset+len(indices)
}

@(private="file")
kdtree_build :: proc "contextless" (offset:int,nodes:[]Kd_Node,triangles:[]Cone,indices:[]u32,leaf_size,depth:int) -> int #no_bounds_check {
    count:=len(indices)
    if count<=leaf_size {return kdtree_build_leaf(offset,nodes,indices)}
    mean,vars:[3]f32
    runc,runs:=f32(1),f32(1)
    // Welford's algorithm over the points of the subtree.
    for i in 0..<count {
        point:=kd_point(triangles,indices[i])
        for k in 0..<3 {
            delta:=point[k]-mean[k]
            mean[k]+=delta*runs
            vars[k]+=delta*(point[k]-mean[k])
        }
        runc+=1
        runs=1/runc
    }
    // Split across the axis of largest variance.
    axis:=(vars[0]>=vars[1] && vars[0]>=vars[2])?0:(vars[1]>=vars[2]?1:2)
    split:=mean[axis]
    middle:=kdtree_partition(indices,triangles,axis,split)
    // A degenerate split, or one too deep, makes a leaf.
    if middle<=leaf_size/2 || middle>=count-leaf_size/2 || depth>=MESHLET_MAX_TREE_DEPTH {return kdtree_build_leaf(offset,nodes,indices)}
    next_offset:=kdtree_build(offset+1,nodes,triangles,indices[:middle],leaf_size,depth+1)
    nodes[offset]={transmute(u32)split,u32(axis),u32(next_offset-offset-1)}
    return kdtree_build(next_offset,nodes,triangles,indices[middle:],leaf_size,depth+1)
}

@(private="file")
kdtree_nearest :: proc "contextless" (nodes:[]Kd_Node,root:u32,triangles:[]Cone,emitted:[]u8,position:Vec3,result:^u32,limit:^f32) #no_bounds_check {
    node:=nodes[root]
    if node.children==0 {return}
    if node.axis==3 {
        inactive:=true
        for i in 0..<node.children {
            index:=nodes[root+i].value
            if emitted[index]!=0 {continue}
            inactive=false
            point:=kd_point(triangles,index)
            dx,dy,dz:=point.x-position.x,point.y-position.y,point.z-position.z
            distance:=math.sqrt(dx*dx+dy*dy+dz*dz)
            if distance<limit^ {
                result^=index
                limit^=distance
            }
        }
        // A leaf with nothing left to emit is skipped from now on.
        if inactive {nodes[root].children=0}
    } else {
        // The side the position is on first.
        delta:=position[node.axis]-transmute(f32)node.value
        first:=delta<=0?u32(0):node.children
        second:=first~node.children
        // A branch whose sides are both empty is skipped from now on.
        if nodes[root+1+first].children|nodes[root+1+second].children==0 {nodes[root].children=0}
        kdtree_nearest(nodes,root+1+first,triangles,emitted,position,result,limit)
        if abs(delta)<=limit^ {kdtree_nearest(nodes,root+1+second,triangles,emitted,position,result,limit)}
    }
}

// Writes the clusters of a triangle list: each has at most max_vertices
// vertices and max_triangles triangles, and with a split factor above 0 one
// with min_triangles or more ends where the next triangle is farther than
// split_factor expected radii. cone_weight (0 to 1) trades size for tighter
// cones of normals. meshlets needs meshlets_bound(len(indices),max_vertices,
// min_triangles) rows; meshlet_vertices and meshlet_triangles as many as
// indices. Scratch memory comes from context.temp_allocator.
meshlets_build :: proc(meshlets:[]Meshlet,meshlet_vertices:[]u32,meshlet_triangles:[]u8,indices:[]u32,positions:[]Vec3,max_vertices,min_triangles,max_triangles:int,cone_weight:f32=0,split_factor:f32=0) -> (count:int,error:Meshlet_Error) #no_bounds_check {
    if max_vertices<3 || max_vertices>MESHLET_MAX_VERTICES || min_triangles<1 || min_triangles>max_triangles || max_triangles>MESHLET_MAX_TRIANGLES || !(cone_weight>=0 && cone_weight<=1) || !(split_factor>=0) || split_factor-split_factor!=0 {return 0,.Invalid_Settings}
    if len(indices)%3!=0 || len(positions)>=int(NONE) || len(indices)>=1<<31 {return 0,.Invalid_Mesh}
    for index in indices {
        if int(index)>=len(positions) || !finite3(positions[index]) {return 0,.Invalid_Mesh}
    }
    if len(meshlets)<meshlets_bound(len(indices),max_vertices,min_triangles) || len(meshlet_vertices)<len(indices) || len(meshlet_triangles)<len(indices) {return 0,.Invalid_Settings}
    if len(indices)==0 {return 0,.None}

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    scratch:=context.temp_allocator
    vertex_count:=len(positions)
    face_count:=len(indices)/3
    adjacency:Triangle_Adjacency
    failed:[8]runtime.Allocator_Error
    adjacency.counts,failed[0]=make([]u32,vertex_count,scratch)
    adjacency.offsets,failed[1]=make([]u32,vertex_count,scratch)
    adjacency.data,failed[2]=make([]u32,len(indices),scratch)
    emitted,triangles,kdindices,nodes,used:=[]u8{},[]Cone{},[]u32{},[]Kd_Node{},[]i16{}
    emitted,failed[3]=make([]u8,face_count,scratch)
    triangles,failed[4]=make([]Cone,face_count,scratch)
    kdindices,failed[5]=make([]u32,face_count,scratch)
    nodes,failed[6]=make([]Kd_Node,face_count*2,scratch)
    used,failed[7]=make([]i16,vertex_count,scratch)
    for f in failed {if f!=nil {return 0,.Out_Of_Memory}}

    // The triangles of each vertex; counts is also how many of them are not emitted yet.
    for index in indices {adjacency.counts[index]+=1}
    offset:u32
    for i in 0..<vertex_count {
        adjacency.offsets[i]=offset
        offset+=adjacency.counts[i]
    }
    for i in 0..<face_count {
        for k in 0..<3 {
            v:=indices[i*3+k]
            adjacency.data[adjacency.offsets[v]]=u32(i)
            adjacency.offsets[v]+=1
        }
    }
    for i in 0..<vertex_count {adjacency.offsets[i]-=adjacency.counts[i]}
    live_triangles:=adjacency.counts

    // The centroid and normal of each triangle, for scoring.
    mesh_area:f32
    for i in 0..<face_count {
        p0,p1,p2:=positions[indices[i*3]],positions[indices[i*3+1]],positions[indices[i*3+2]]
        p10:=Vec3{p1.x-p0.x,p1.y-p0.y,p1.z-p0.z}
        p20:=Vec3{p2.x-p0.x,p2.y-p0.y,p2.z-p0.z}
        normalx:=p10.y*p20.z-p10.z*p20.y
        normaly:=p10.z*p20.x-p10.x*p20.z
        normalz:=p10.x*p20.y-p10.y*p20.x
        area:=math.sqrt(normalx*normalx+normaly*normaly+normalz*normalz)
        invarea:=area==0?f32(0):1/area
        triangles[i]={(p0.x+p1.x+p2.x)/3,(p0.y+p1.y+p2.y)/3,(p0.z+p1.z+p2.z)/3,normalx*invarea,normaly*invarea,normalz*invarea}
        mesh_area+=area
    }
    // A cluster as a square patch: its expected radius is the root of its expected area.
    triangle_area_avg:=mesh_area/f32(face_count)*0.5
    expected_radius:=math.sqrt(triangle_area_avg*f32(max_triangles))*0.5

    for &k,i in kdindices {k=u32(i)}
    kdtree_build(0,nodes,triangles,kdindices,8,0)

    // The corner of the mesh where the flow of clusters starts.
    corner:=Vec3{max(f32),max(f32),max(f32)}
    for tri in triangles {
        corner.x=corner.x>tri.px?tri.px:corner.x
        corner.y=corner.y>tri.py?tri.py:corner.y
        corner.z=corner.z>tri.pz?tri.pz:corner.z
    }
    if vertex_count<=len(indices) {
        for &u in used {u=-1}
    } else {
        for index in indices {used[index]=-1}
    }
    initial_seed:=NONE
    initial_score:=max(f32)
    for tri,i in triangles {
        dx,dy,dz:=tri.px-corner.x,tri.py-corner.y,tri.pz-corner.z
        score:=math.sqrt(dx*dx+dy*dy+dz*dz)
        if initial_seed==NONE || score<initial_score {
            initial_seed=u32(i)
            initial_score=score
        }
    }

    seeds:[MESHLET_MAX_SEEDS]u32
    seed_count:=0
    meshlet:Meshlet
    meshlet_offset:=0
    cone_acc:Cone
    for {
        cone:=meshlet_cone(cone_acc,meshlet.triangle_count)
        best_triangle:u32
        if meshlet_offset==0 && meshlet.triangle_count==0 {
            best_triangle=initial_seed
        } else {
            best_triangle=neighbor_triangle(meshlet,cone,meshlet_vertices,indices,&adjacency,triangles,live_triangles,used,expected_radius,cone_weight)
        }
        split:=false
        // Without an adjacent triangle, the nearest one wherever it is.
        if best_triangle==NONE {
            index:=NONE
            distance:=max(f32)
            kdtree_nearest(nodes,0,triangles,emitted,{cone.px,cone.py,cone.pz},&index,&distance)
            best_triangle=index
            split=int(meshlet.triangle_count)>=min_triangles && split_factor>0 && distance>expected_radius*split_factor
        }
        if best_triangle==NONE {break}
        best_extra:=int(used[indices[best_triangle*3]]<0)+int(used[indices[best_triangle*3+1]]<0)+int(used[indices[best_triangle*3+2]]<0)
        // A triangle that does not fit restarts from the seeds, to keep the flow.
        if split || int(meshlet.vertex_count)+best_extra>max_vertices || int(meshlet.triangle_count)>=max_triangles {
            seed_count=seed_triangles_prune(seeds[:seed_count],emitted)
            seed_count=seed_count+MESHLET_ADD_SEEDS<=MESHLET_MAX_SEEDS?seed_count:MESHLET_MAX_SEEDS-MESHLET_ADD_SEEDS
            seed_count+=seed_triangles_append(seeds[seed_count:],meshlet,meshlet_vertices,indices,&adjacency,triangles,live_triangles,corner)
            best_seed:=seed_triangle_select(seeds[:seed_count],indices,triangles,live_triangles,corner)
            // A mesh in pieces may have no seed.
            best_triangle=best_seed!=NONE?best_seed:best_triangle
        }
        a,b,c:=indices[best_triangle*3],indices[best_triangle*3+1],indices[best_triangle*3+2]
        if meshlet_append(&meshlet,a,b,c,used,meshlets,meshlet_vertices,meshlet_triangles,meshlet_offset,max_vertices,max_triangles,split) {
            meshlet_offset+=1
            cone_acc={}
        }
        // The triangle leaves the lists of its vertices, which updates their live counts.
        for k in 0..<3 {
            index:=indices[best_triangle*3+u32(k)]
            neighbors:=adjacency.data[adjacency.offsets[index]:][:adjacency.counts[index]]
            for &tri in neighbors {
                if tri==best_triangle {
                    tri=neighbors[len(neighbors)-1]
                    adjacency.counts[index]-=1
                    break
                }
            }
        }
        t:=triangles[best_triangle]
        cone_acc.px+=t.px
        cone_acc.py+=t.py
        cone_acc.pz+=t.pz
        cone_acc.nx+=t.nx
        cone_acc.ny+=t.ny
        cone_acc.nz+=t.nz
        emitted[best_triangle]=1
    }
    if meshlet.triangle_count>0 {
        meshlets[meshlet_offset]=meshlet
        meshlet_offset+=1
    }
    return meshlet_offset,.None
}

// Ritter's sphere from the extremes along up to 7 axes, grown until every
// point (with its radius) fits. It measures in f64: the square of a distance
// past 2^64 is past the largest f32.
@(private="file")
bounding_sphere :: proc "contextless" (points:[]Vec3,radii:[]f32,axis_count:int,order:[]u32=nil) -> (center:Vec3,radius:f32) #no_bounds_check {
    Vec3d :: [3]f64
    AXES :: [7]Vec3d{
        {1,0,0},{0,1,0},{0,0,1},
        {0.57735026,0.57735026,0.57735026},{-0.57735026,0.57735026,0.57735026},
        {0.57735026,-0.57735026,0.57735026},{0.57735026,0.57735026,-0.57735026},
    }
    axes:=AXES
    count:=len(order)>0?len(order):len(points)
    if count==0 {return}
    radius_of :: #force_inline proc "contextless" (radii:[]f32,v:u32) -> f64 #no_bounds_check {return len(radii)>0?f64(radii[v]):0}
    point_of :: #force_inline proc "contextless" (points:[]Vec3,v:u32) -> Vec3d #no_bounds_check {p:=points[v];return {f64(p.x),f64(p.y),f64(p.z)}}
    distance :: #force_inline proc "contextless" (a,b:Vec3d) -> f64 {d:=b-a;return math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)}
    pmin,pmax:[7]u32
    tmin,tmax:[7]f64
    for axis in 0..<axis_count {
        tmin[axis]=max(f64)
        tmax[axis]=-max(f64)
    }
    for i in 0..<count {
        v:=len(order)>0?order[i]:u32(i)
        p:=point_of(points,v)
        r:=radius_of(radii,v)
        for axis in 0..<axis_count {
            ax:=axes[axis]
            tp:=ax[0]*p[0]+ax[1]*p[1]+ax[2]*p[2]
            tpmin,tpmax:=tp-r,tp+r
            pmin[axis]=tpmin<tmin[axis]?v:pmin[axis]
            pmax[axis]=tpmax>tmax[axis]?v:pmax[axis]
            tmin[axis]=tpmin<tmin[axis]?tpmin:tmin[axis]
            tmax[axis]=tpmax>tmax[axis]?tpmax:tmax[axis]
        }
    }
    // The pair of points farthest apart.
    paxis:=0
    paxisdr:f64
    for axis in 0..<axis_count {
        dr:=distance(point_of(points,pmin[axis]),point_of(points,pmax[axis]))+radius_of(radii,pmin[axis])+radius_of(radii,pmax[axis])
        if dr>paxisdr {
            paxisdr=dr
            paxis=axis
        }
    }
    // Their segment is the first diameter.
    p1,p2:=point_of(points,pmin[paxis]),point_of(points,pmax[paxis])
    r1,r2:=radius_of(radii,pmin[paxis]),radius_of(radii,pmax[paxis])
    paxisd:=distance(p1,p2)
    paxisk:=paxisd>0?(paxisd+r2-r1)/(2*paxisd):0
    c:=p1+(p2-p1)*paxisk
    rad:=paxisdr/2
    for i in 0..<count {
        v:=len(order)>0?order[i]:u32(i)
        p:=point_of(points,v)
        r:=radius_of(radii,v)
        d:=distance(c,p)
        if d+r>rad {
            k:=d>0?(d+r-rad)/(2*d):0
            c+=k*(p-c)
            rad=(rad+d+r)/2
        }
    }
    return {f32(c.x),f32(c.y),f32(c.z)},f32(rad)
}

// The sphere around spheres (radii empty: around points). All zero for none.
spheres_bound :: proc "contextless" (centers:[]Vec3,radii:[]f32=nil) -> (center:Vec3,radius:f32) {
    if len(radii)!=0 && len(radii)!=len(centers) {return}
    return bounding_sphere(centers,radii,7)
}

// The bounds of a cluster of up to MESHLET_MAX_TRIANGLES triangles, by the
// indices of its vertices in positions. Triangles without area do not count;
// with none, everything is zero. Indices out of range give zero bounds.
cluster_bounds :: proc "contextless" (indices:[]u32,positions:[]Vec3) -> (bounds:Cluster_Bounds) #no_bounds_check {
    if len(indices)%3!=0 || len(indices)/3>MESHLET_MAX_TRIANGLES {return}
    for index in indices {
        if int(index)>=len(positions) {return}
    }
    // The vertices, without those a direct-mapped cache of their low bits has just seen.
    cache:[512]u32
    for &c in cache {c=NONE}
    corners:[MESHLET_MAX_TRIANGLES*3+1]u32
    corner_count:=0
    for v in indices {
        c:=&cache[v&(len(cache)-1)]
        corners[corner_count]=v
        corner_count+=int(c^!=v)
        c^=v
    }
    // The plane of each triangle: its normal and, in w, its offset.
    normals:[MESHLET_MAX_TRIANGLES]Vec4
    normal_points:[MESHLET_MAX_TRIANGLES]Vec3
    triangles:=0
    for i:=0;i<len(indices);i+=3 {
        p0,p1,p2:=positions[indices[i]],positions[indices[i+1]],positions[indices[i+2]]
        p10:=Vec3{p1[0]-p0[0],p1[1]-p0[1],p1[2]-p0[2]}
        p20:=Vec3{p2[0]-p0[0],p2[1]-p0[1],p2[2]-p0[2]}
        normalx:=p10[1]*p20[2]-p10[2]*p20[1]
        normaly:=p10[2]*p20[0]-p10[0]*p20[2]
        normalz:=p10[0]*p20[1]-p10[1]*p20[0]
        area:=math.sqrt(normalx*normalx+normaly*normaly+normalz*normalz)
        if area==0 {continue}
        normalx/=area
        normaly/=area
        normalz/=area
        normals[triangles]={normalx,normaly,normalz,-(normalx*p0[0]+normaly*p0[1]+normalz*p0[2])}
        normal_points[triangles]={normalx,normaly,normalz}
        triangles+=1
    }
    if triangles==0 {return}
    center,radius:=bounding_sphere(positions,nil,7,corners[:corner_count])
    // The sphere around the normals, as points, gives the axis of the cone.
    axis,_:=bounding_sphere(normal_points[:triangles],nil,3)
    axislength:=math.sqrt(axis[0]*axis[0]+axis[1]*axis[1]+axis[2]*axis[2])
    invaxislength:=axislength==0?f32(0):1/axislength
    axis*=invaxislength
    // mindp is the cosine of the half-angle of the cone of normals.
    mindp:=f32(1)
    for i in 0..<triangles {
        dp:=normals[i][0]*axis[0]+normals[i][1]*axis[1]+normals[i][2]*axis[2]
        mindp=dp<mindp?dp:mindp
    }
    bounds.center=center
    bounds.radius=radius
    // A cone of about 168 degrees or more is of no use.
    if mindp<=0.1 {
        bounds.cone_cutoff=1
        return
    }
    // The point of center-t*axis behind every triangle.
    maxt:f32
    for i in 0..<triangles {
        dc:=center[0]*normals[i][0]+center[1]*normals[i][1]+center[2]*normals[i][2]+normals[i][3]
        dn:=axis[0]*normals[i][0]+axis[1]*normals[i][1]+axis[2]*normals[i][2]
        t:=dc/dn
        maxt=t>maxt?t:maxt
    }
    bounds.cone_apex={center[0]-axis[0]*maxt,center[1]-axis[1]*maxt,center[2]-axis[2]*maxt}
    bounds.cone_axis=axis
    // The cone of normals widened by 90 degrees on each side and inverted: sin of its half-angle.
    bounds.cone_cutoff=math.sqrt(1-mindp*mindp)
    return
}

// The vertices of a cluster given by mesh indices (at most
// MESHLET_MAX_VERTICES of them, in order of first use) and its triangles as
// local indices: vertices[triangles[i]]==indices[i]. Returns how many
// vertices it wrote, or -1 for more than vertices or triangles hold.
meshlet_local_indices :: proc "contextless" (vertices:[]u32,triangles:[]u8,indices:[]u32) -> int #no_bounds_check {
    if len(triangles)<len(indices) {return -1}
    unique:=0
    // A direct-mapped cache of the low bits of the indices.
    cache:[1024]i16
    for &c in cache {c=-1}
    for v,i in indices {
        key:=v&(len(cache)-1)
        c:=cache[key]
        if c>=0 && vertices[c]==v {
            triangles[i]=u8(c)
            continue
        }
        if c<0 {
            if unique>=min(len(vertices),MESHLET_MAX_VERTICES) {return -1}
            cache[key]=i16(unique)
            triangles[i]=u8(unique)
            vertices[unique]=v
            unique+=1
            continue
        }
        pos:=-1
        for j in 0..<unique {
            if vertices[j]==v {
                pos=j
                break
            }
        }
        if pos<0 {
            if unique>=min(len(vertices),MESHLET_MAX_VERTICES) {return -1}
            pos=unique
            vertices[unique]=v
            unique+=1
        }
        cache[key]=i16(pos)
        triangles[i]=u8(pos)
    }
    return unique
}
