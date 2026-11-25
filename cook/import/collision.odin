package importer

import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:std/geom"
import mm "mirai:std/math"

// The colliders a source authors for a mesh, in the space of the mesh:
// stored in its asset as they are authored. An import makes none of its own.
Mesh_Collision :: struct {
    colliders:[]asset.Collider,
    points:   [][3]f32,
    indices:  []u32, // of a Mesh collider, relative to its first point
}

// How a source authors a collider.
Source_Shape :: enum u8 {
    Box,       // size: half extents
    Sphere,    // size.x: radius
    Capsule,   // size.x: radius; size.y: half the distance between the centers of its caps, along Y
    Points,    // the convex hull of points
    Hull,      // the convex hull of each piece of mesh that shares no position with the others
    Decompose, // convex pieces that a decomposition of mesh gives (a source that asks for one)
    Mesh,      // the triangles of mesh
    Box_Fit,     // the box mesh is, or its Hull when it is not one
    Sphere_Fit,  // the sphere mesh is, or its Hull when it is not one
    Capsule_Fit, // the capsule around mesh
}

// A collider a format reads: a shape in the space of node `placed` (within
// it at center and rotation), for the mesh of node `target`; -1 finds it
// (collider_target). only: the node it is placed at is collision only, and
// is no node of the model, nor is a mesh only it shows.
Source_Collider :: struct {
    placed,target:int,
    shape:Source_Shape,
    center:[3]f32,
    rotation:mm.Quat,
    size:[3]f32,
    points:[][3]f32, // of Points, in the temp allocator
    mesh:int,        // row of meshes: the geometry of Hull, Decompose, Mesh and the fits, in the space of placed
    only:bool,
}

// The tolerance of a fit: of the size of what is fitted.
@(private="file") FIT_TOLERANCE :: f32(1e-3)
// How far the box of a sphere may be from a cube, and its vertices from its radius.
@(private="file") SPHERE_TOLERANCE :: f32(0.05)

// The colliders the names of nodes author, as tools export them for game
// engines, added to those the format read:
//
//   UCX_<mesh>[_n]  the convex hull of each piece of its geometry
//   UBX_<mesh>[_n]  the box it is
//   USP_<mesh>[_n]  the sphere it is
//   UCP_<mesh>[_n]  the capsule around it
//   <name>-colonly  its triangles, and <name>-convcolonly their hulls, for the nearest mesh
//   <name>-col      the mesh collides with its triangles, and with -convcol their hulls
//
// A prefix is followed by the name of the mesh it collides for, without case;
// a suffix may also follow an underscore or a dollar sign. Then every collider is placed in
// the space of the mesh it collides for, and the nodes that are collision only
// and the meshes only they show leave the model.
colliders_resolve :: proc(r:^Reader) -> bool {
    drawn:=make([]bool,len(r.nodes),context.temp_allocator)
    for node,i in r.nodes {drawn[i]=node.mesh>=0 && len(r.meshes[node.mesh].skin)==0}
    for &collider in r.colliders {
        if collider.only && collider.placed>=0 && collider.placed<len(drawn) {drawn[collider.placed]=false}
    }
    for &node,i in r.nodes {
        if node.mesh<0 || len(r.meshes[node.mesh].skin)>0 {continue}
        name:=node.name
        upper:=strings.to_upper(name,context.temp_allocator)
        prefixes:=[4]string{"UCX_","UBX_","USP_","UCP_"}
        shapes:=[4]Source_Shape{.Hull,.Box_Fit,.Sphere_Fit,.Capsule_Fit}
        found:=false
        for prefix,k in prefixes {
            if !strings.has_prefix(upper,prefix) {continue}
            append(&r.colliders,Source_Collider{placed=i,target=collider_named(r,drawn,name[len(prefix):]),shape=shapes[k],rotation=1,mesh=node.mesh,only=true})
            if r.colliders[len(r.colliders)-1].target<0 {
                warn(r,"%s collides for no mesh of the model: name it after the node of its mesh (%s<mesh>)",name,prefix)
                pop(&r.colliders)
                break
            }
            drawn[i]=false
            found=true
            break
        }
        if found {continue}
        suffixes:=[4]string{"CONVCOLONLY","COLONLY","CONVCOL","COL"}
        for suffix,k in suffixes {
            if len(upper)<=len(suffix)+1 || !strings.has_suffix(upper,suffix) {continue}
            separator:=upper[len(upper)-len(suffix)-1]
            if separator!='-' && separator!='_' && separator!='$' {continue}
            only:=k<2
            shape:=Source_Shape.Hull if k%2==0 else .Mesh
            append(&r.colliders,Source_Collider{placed=i,target=-1 if only else i,shape=shape,rotation=1,mesh=node.mesh,only=only})
            node.name=own(r,name[:len(name)-len(suffix)-1])
            if only {drawn[i]=false}
            break
        }
    }
    if len(r.colliders)==0 {return true}
    world:=make([]mm.Mat4,len(r.nodes),context.temp_allocator)
    for node,i in r.nodes {
        world[i]=mm.transform_matrix(node.transform)
        if node.parent>=0 && node.parent<i {world[i]=world[node.parent]*world[i]}
    }
    Gathered :: struct {colliders:[dynamic]asset.Collider,points:[dynamic][3]f32,indices:[dynamic]u32,triangles:[dynamic]u32,surface:[dynamic][3]f32}
    gathered:=make(map[int]^Gathered,context.temp_allocator)
    removed:=make([]bool,len(r.nodes),context.temp_allocator)
    collision_meshes:=make(map[int]bool,context.temp_allocator)
    for &collider in r.colliders {
        if collider.placed<0 || collider.placed>=len(r.nodes) {continue}
        if collider.only {
            removed[collider.placed]=r.nodes[collider.placed].light==nil
            if collider.mesh>=0 {collision_meshes[collider.mesh]=true}
            if r.nodes[collider.placed].mesh>=0 {collision_meshes[r.nodes[collider.placed].mesh]=true}
        }
        target:=collider.target if collider.target>=0 else collider_target(r,drawn,collider.placed)
        if target<0 || r.nodes[target].mesh<0 {
            warn(r,"the collider of %s collides for no mesh of the model: put it under the node of its mesh",r.nodes[collider.placed].name)
            continue
        }
        inverse,invertible:=mm_inverse(world[target])
        if !invertible {continue}
        to_mesh:=inverse*world[collider.placed]*mm.transform_matrix({collider.center,collider.rotation,{1,1,1}})
        mesh_row:=r.nodes[target].mesh
        held:=gathered[mesh_row]
        if held==nil {
            held=new(Gathered,context.temp_allocator)
            held^={make([dynamic]asset.Collider,context.temp_allocator),make([dynamic][3]f32,context.temp_allocator),make([dynamic]u32,context.temp_allocator),make([dynamic]u32,context.temp_allocator),make([dynamic][3]f32,context.temp_allocator)}
            gathered[mesh_row]=held
        }
        collider_place(r,&collider,to_mesh,&held.colliders,&held.points,&held.triangles,&held.surface)
    }
    for mesh_row,held in gathered {
        mesh:=&r.meshes[mesh_row]
        colliders:=make([dynamic]asset.Collider,r.out)
        points:=make([dynamic][3]f32,r.out)
        indices:=make([dynamic]u32,r.out)
        append(&colliders,..mesh.collision.colliders)
        append(&points,..mesh.collision.points)
        append(&indices,..mesh.collision.indices)
        // The hulls count their points from the start of those they bring.
        first:=u32(len(points))
        for collider in held.colliders {
            moved:=collider
            if moved.kind==.Hull {moved.first_point+=first}
            append(&colliders,moved)
        }
        append(&points,..held.points[:])
        if len(held.triangles)>0 {
            // The triangles of a mesh collide as one collision mesh: the one a collider takes.
            append(&colliders,asset.Collider{kind=.Mesh,rotation=1,first_point=u32(len(points)),point_count=u32(len(held.surface)),first_index=u32(len(indices)),index_count=u32(len(held.triangles))})
            append(&points,..held.surface[:])
            append(&indices,..held.triangles[:])
        }
        mesh.collision={colliders[:],points[:],indices[:]}
    }
    nodes_remove(r,removed,collision_meshes)
    return true
}

// The node of the drawn mesh a name names: the whole name, then without what
// follows its last underscore or dot (UCX_Crate_01, Crate.001). With one
// drawn mesh in the model, that one whatever the name. -1 for none.
@(private="file")
collider_named :: proc(r:^Reader,drawn:[]bool,name:string) -> int {
    candidates:[3]string
    candidates[0]=name
    if at:=strings.last_index_byte(name,'_');at>0 {candidates[1]=name[:at]}
    if at:=strings.last_index_byte(name,'.');at>0 {candidates[2]=name[:at]}
    for candidate in candidates {
        if candidate=="" {continue}
        for node,i in r.nodes {
            if drawn[i] && (strings.equal_fold(node.name,candidate) || strings.equal_fold(r.meshes[node.mesh].name,candidate)) {return i}
        }
    }
    only:=-1
    for shown,i in drawn {
        if !shown {continue}
        if only>=0 {return -1}
        only=i
    }
    return only
}

// The drawn mesh a collider without a named one collides for: that of its
// node, or the only one below it (a body whose colliders and meshes are its
// children), else of the nearest ancestor that shows one or holds exactly
// one below it, else the only drawn mesh of the model. -1 for none.
@(private="file")
collider_target :: proc(r:^Reader,drawn:[]bool,placed:int) -> int {
    if drawn[placed] {return placed}
    below :: proc(r:^Reader,drawn:[]bool,top:int) -> int {
        found:=-1
        for node,i in r.nodes {
            if !drawn[i] {continue}
            for at:=i;at>=0;at=r.nodes[at].parent {
                if at!=top {continue}
                if found>=0 {return -2}
                found=i
                break
            }
        }
        return found
    }
    if one:=below(r,drawn,placed);one!=-1 {return one if one>=0 else -1}
    for at:=r.nodes[placed].parent;at>=0;at=r.nodes[at].parent {
        if drawn[at] {return at}
        if one:=below(r,drawn,at);one!=-1 {return one if one>=0 else -1}
    }
    one,count:=-1,0
    for shown,i in drawn {
        if shown {count+=1;one=i}
    }
    return one if count==1 else -1
}

@(private="file")
mm_inverse :: proc(m:mm.Mat4) -> (inverse:mm.Mat4,ok:bool) {
    if abs(linalg.determinant(m))<1e-12 {return}
    return linalg.inverse(m),true
}

@(private="file")
point_moved :: #force_inline proc(m:mm.Mat4,p:[3]f32) -> [3]f32 {
    q:=m*[4]f32{p.x,p.y,p.z,1}
    return q.xyz
}

// A collider as rows of the mesh it collides for, through to_mesh: from
// the space it is authored in to that of the mesh. Hulls go to colliders and
// points; triangles to triangles and surface, which become one collision mesh.
@(private="file")
collider_place :: proc(r:^Reader,c:^Source_Collider,to_mesh:mm.Mat4,colliders:^[dynamic]asset.Collider,points:^[dynamic][3]f32,triangles:^[dynamic]u32,surface:^[dynamic][3]f32) {
    hull :: proc(r:^Reader,source:[][3]f32,to_mesh:mm.Mat4,colliders:^[dynamic]asset.Collider,points:^[dynamic][3]f32) {
        moved:=make([]geom.Vec3,len(source),context.temp_allocator)
        for p,i in source {moved[i]=point_moved(to_mesh,p)}
        built,error:=geom.hull_build(moved,{},context.temp_allocator)
        if error!=.None || len(built.vertices)<3 {return}
        append(colliders,asset.Collider{kind=.Hull,rotation=1,first_point=u32(len(points)),point_count=u32(len(built.vertices))})
        append(points,..built.vertices)
    }
    primitive :: proc(kind:asset.Collider_Kind,center:[3]f32,rotation:mm.Quat,size:[3]f32,to_mesh:mm.Mat4,colliders:^[dynamic]asset.Collider) {
        m:=to_mesh*mm.transform_matrix({center,rotation,{1,1,1}})
        axes:[3][3]f32
        scale:[3]f32
        for k in 0..<3 {
            axes[k]=m[k].xyz
            scale[k]=linalg.length(axes[k])
            if scale[k]<1e-12 {return}
        }
        x:=axes[0]/scale[0]
        y:=axes[1]-linalg.dot(axes[1],x)*x
        y=y/max(linalg.length(y),1e-12)
        z:=linalg.cross(x,y)
        turn:=linalg.quaternion_from_matrix3_f32(matrix[3,3]f32{x.x,y.x,z.x,x.y,y.y,z.y,x.z,y.z,z.z})
        moved:=asset.Collider{kind=kind,center=m[3].xyz,rotation=turn}
        switch kind {
        case .Box:     moved.size=size*scale
        case .Sphere:  moved.size={size.x*max(scale.x,scale.y,scale.z),0,0}
        case .Capsule: moved.size={size.x*max(scale.x,scale.z),size.y*scale.y,0}
        case .Hull,.Mesh: return
        }
        append(colliders,moved)
    }
    geometry :: proc(r:^Reader,row:int) -> (positions:[]geom.Vec3,indices:[]u32) {
        if row<0 || row>=len(r.meshes) {return}
        mesh:=&r.meshes[row]
        positions=make([]geom.Vec3,len(mesh.vertices),context.temp_allocator)
        for vertex,i in mesh.vertices {positions[i]=vertex.position}
        return positions,mesh.indices
    }
    switch c.shape {
    case .Box:     primitive(.Box,0,1,c.size,to_mesh,colliders)
    case .Sphere:  primitive(.Sphere,0,1,c.size,to_mesh,colliders)
    case .Capsule: primitive(.Capsule,0,1,c.size,to_mesh,colliders)
    case .Points:  hull(r,c.points,to_mesh,colliders,points)
    case .Hull:
        positions,indices:=geometry(r,c.mesh)
        for piece in pieces_of(positions,indices) {hull(r,piece,to_mesh,colliders,points)}
    case .Decompose:
        positions,indices:=geometry(r,c.mesh)
        if len(indices)<3 {return}
        parts,failed:=geom.mesh_decompose({positions=positions,indices=indices},{},context.temp_allocator)
        if failed!=.None {
            hull(r,positions,to_mesh,colliders,points)
            return
        }
        for part in parts.hulls {hull(r,part.vertices,to_mesh,colliders,points)}
    case .Mesh:
        positions,indices:=geometry(r,c.mesh)
        first:=u32(len(surface))
        for p in positions {append(surface,point_moved(to_mesh,p))}
        mirrored:=linalg.determinant(to_mesh)<0
        for t in 0..<len(indices)/3 {
            a,b,d:=indices[t*3],indices[t*3+1],indices[t*3+2]
            if mirrored {b,d=d,b}
            append(triangles,first+a,first+b,first+d)
        }
    case .Box_Fit:
        positions,indices:=geometry(r,c.mesh)
        if center,turn,half,fits:=box_fit(positions,indices);fits {
            primitive(.Box,center,turn,half,to_mesh,colliders)
        } else {
            warn(r,"%s is not a box: it collides as its convex hull",r.nodes[c.placed].name)
            hull(r,positions,to_mesh,colliders,points)
        }
    case .Sphere_Fit:
        positions,_:=geometry(r,c.mesh)
        if center,radius,fits:=sphere_fit(positions);fits {
            primitive(.Sphere,center,1,{radius,0,0},to_mesh,colliders)
        } else {
            warn(r,"%s is not a sphere: it collides as its convex hull",r.nodes[c.placed].name)
            hull(r,positions,to_mesh,colliders,points)
        }
    case .Capsule_Fit:
        positions,_:=geometry(r,c.mesh)
        if center,turn,radius,half,fits:=capsule_fit(positions);fits {
            primitive(.Capsule,center,turn,{radius,half,0},to_mesh,colliders)
        } else {
            hull(r,positions,to_mesh,colliders,points)
        }
    }
}

// The points of each piece of a surface that shares no position with the
// others: one convex hull each.
@(private="file")
pieces_of :: proc(positions:[]geom.Vec3,indices:[]u32) -> [][][3]f32 {
    if len(positions)==0 {return nil}
    weld:=make([]u32,len(positions),context.temp_allocator)
    geom.positions_weld(positions,0,weld)
    root:=make([]u32,len(positions),context.temp_allocator)
    for &at,i in root {at=u32(i)}
    find :: proc(root:[]u32,i:u32) -> u32 {
        i:=i
        for root[i]!=i {root[i]=root[root[i]];i=root[i]}
        return i
    }
    for t in 0..<len(indices)/3 {
        a:=find(root,weld[indices[t*3]])
        for k in 1..<3 {
            b:=find(root,weld[indices[t*3+k]])
            if a!=b {root[b]=a}
        }
    }
    used:=make([]bool,len(positions),context.temp_allocator)
    for index in indices {used[index]=true}
    group:=make(map[u32]int,context.temp_allocator)
    pieces:=make([dynamic][dynamic][3]f32,context.temp_allocator)
    for p,i in positions {
        if !used[i] {continue}
        top:=find(root,weld[i])
        at,known:=group[top]
        if !known {
            at=len(pieces)
            group[top]=at
            append(&pieces,make([dynamic][3]f32,context.temp_allocator))
        }
        append(&pieces[at],p)
    }
    out:=make([][][3]f32,len(pieces),context.temp_allocator)
    for piece,i in pieces {out[i]=piece[:]}
    return out
}

// The box a surface is: three directions of faces, each with two planes,
// square to each other. Its center is that of the box around its vertices.
@(private="file")
box_fit :: proc(positions:[]geom.Vec3,indices:[]u32) -> (center:[3]f32,turn:mm.Quat,half:[3]f32,ok:bool) {
    if len(indices)<3 || len(positions)==0 {return}
    low,high:=positions[0],positions[0]
    for p in positions {low,high=linalg.min(low,p),linalg.max(high,p)}
    reach:=max(linalg.length(high-low),1e-12)
    Plane :: struct {normal:[3]f32,distances:[2]f32,count:int}
    planes:[3]Plane
    count:=0
    for t in 0..<len(indices)/3 {
        a,b,c:=positions[indices[t*3]],positions[indices[t*3+1]],positions[indices[t*3+2]]
        n:=linalg.cross(b-a,c-a)
        length:=linalg.length(n)
        if length<1e-12*reach*reach {continue}
        n/=length
        known:=false
        for &plane in planes[:count] {
            if 1-abs(linalg.dot(n,plane.normal))>FIT_TOLERANCE {continue}
            distance:=linalg.dot(a,plane.normal)
            switch {
            case abs(distance-plane.distances[0])<=FIT_TOLERANCE*reach:
            case plane.count==1: plane.distances[1],plane.count=distance,2
            case abs(distance-plane.distances[1])>FIT_TOLERANCE*reach: return
            }
            known=true
            break
        }
        if known {continue}
        if count==3 {return}
        planes[count]={n,{linalg.dot(a,n),0},1}
        count+=1
    }
    if count!=3 {return}
    for plane in planes {if plane.count!=2 {return}}
    z:=linalg.cross(planes[0].normal,planes[1].normal)
    if 1-abs(linalg.dot(z,planes[2].normal))>FIT_TOLERANCE {return}
    x,y:=planes[0].normal,planes[1].normal
    turn=linalg.quaternion_from_matrix3_f32(matrix[3,3]f32{x.x,y.x,z.x,x.y,y.y,z.y,x.z,y.z,z.z})
    for k in 0..<3 {half[k]=abs(planes[k].distances[0]-planes[k].distances[1])*0.5}
    return (low+high)*0.5,turn,half,true
}

// The sphere a set of points is: a box around them that is nearly a cube,
// and every point nearly at its radius from its center (or at the center).
@(private="file")
sphere_fit :: proc(positions:[]geom.Vec3) -> (center:[3]f32,radius:f32,ok:bool) {
    if len(positions)==0 {return}
    low,high:=positions[0],positions[0]
    for p in positions {low,high=linalg.min(low,p),linalg.max(high,p)}
    size:=high-low
    longest,shortest:=max(size.x,size.y,size.z),min(size.x,size.y,size.z)
    if !(longest>0) || (longest-shortest)/longest>SPHERE_TOLERANCE {return}
    center,radius=(low+high)*0.5,longest*0.5
    nearest,farthest:=f32(math.F32_MAX),f32(0)
    for p in positions {
        d:=linalg.length(p-center)
        farthest=max(farthest,d)
        if d>radius*FIT_TOLERANCE {nearest=min(nearest,d)}
    }
    if (farthest-nearest)/radius>SPHERE_TOLERANCE {return}
    return center,radius,true
}

// The capsule around a set of points: along its two farthest points, as
// wide as the farthest point from that line.
@(private="file")
capsule_fit :: proc(positions:[]geom.Vec3) -> (center:[3]f32,turn:mm.Quat,radius,half:f32,ok:bool) {
    if len(positions)<3 {return}
    // The farthest points are vertices of the hull: fewer to pair.
    candidates:=positions
    if built,error:=geom.hull_build(positions,{},context.temp_allocator);error==.None {candidates=built.vertices}
    a,b:[3]f32
    widest:=f32(0)
    for p,i in candidates {
        for q in candidates[i+1:] {
            if d:=linalg.length2(p-q);d>widest {a,b,widest=p,q,d}
        }
    }
    if widest<1e-12 {return}
    axis:=linalg.normalize(b-a)
    for p in positions {
        along:=p-a
        radius=max(radius,linalg.length(along-linalg.dot(along,axis)*axis))
    }
    if radius<1e-6*math.sqrt(widest) {return}
    return (a+b)*0.5,mm.quat_between({0,1,0},axis),radius,max(math.sqrt(widest)*0.5-radius,0),true
}

// Takes out of the model the nodes that are removed and the meshes only
// they or colliders show among collision: their children go to their parent,
// where they were.
@(private="file")
nodes_remove :: proc(r:^Reader,removed:[]bool,collision:map[int]bool) {
    some:=false
    for gone in removed {some||=gone}
    if !some {return}
    row:=make([]int,len(r.nodes),context.temp_allocator)
    kept:=0
    for &node,i in r.nodes {
        parent:=node.parent
        transform:=node.transform
        for parent>=0 && removed[parent] {
            transform=mm.transform_compose(r.nodes[parent].transform,transform)
            parent=r.nodes[parent].parent
        }
        node.parent=parent
        node.transform=transform
        if removed[i] {row[i]=-1;continue}
        row[i]=kept
        kept+=1
    }
    // Every ancestor of a node that stays is resolved before it, as parents come first.
    at:=0
    for i in 0..<len(r.nodes) {
        if removed[i] {continue}
        node:=r.nodes[i]
        if node.parent>=0 {node.parent=row[node.parent]}
        r.nodes[at]=node
        at+=1
    }
    resize(&r.nodes,at)
    shown:=make([]bool,len(r.meshes),context.temp_allocator)
    for node in r.nodes {if node.mesh>=0 {shown[node.mesh]=true}}
    mesh_row:=make([]int,len(r.meshes),context.temp_allocator)
    kept=0
    for i in 0..<len(r.meshes) {
        if !shown[i] && collision[i] {mesh_row[i]=-1;continue}
        mesh_row[i]=kept
        r.meshes[kept]=r.meshes[i]
        kept+=1
    }
    resize(&r.meshes,kept)
    for &node in r.nodes {if node.mesh>=0 {node.mesh=mesh_row[node.mesh]}}
}
