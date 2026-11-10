package geom

import "base:runtime"
import "core:math"
import "core:slice"
import "mirai:std/base"

Boolean_Op :: enum u8 {Union,Subtract,Intersect}
Boolean_Error :: enum u8 {None,Invalid_Mesh,Invalid_Settings,Not_Closed,No_Volume,Capacity,Out_Of_Memory,Topology}
Boolean_Settings :: struct {
    tolerance:f32,
    max_fragments:int,
    max_vertices:int,
    max_depth:int,
}

@(private="file") Boolean_Vertex :: struct {p:DVec3,n:Vec3,uv:Vec2,color:Vec4}
@(private="file") Boolean_Polygon :: struct {first,count:int,plane:DPlane,material:u32}
@(private="file") Boolean_Reference :: struct {polygon,next:int}
@(private="file") Boolean_Node :: struct {plane:DPlane,front,back,first:int}
@(private="file") Boolean_Task :: struct {node,first,count,depth:int}
@(private="file") Boolean_Clip :: struct {node,polygon:int}
@(private="file") Boolean_Point :: struct {p:Vec3,id:u32}
@(private="file") Boolean_Edge :: struct {a,b,corner:u32}
@(private="file") Boolean_Cut :: struct {t:f64,point:u32}
@(private="file") Boolean_Triangle :: struct {a,b,c,index:u32,positive:bool}
@(private="file") Boolean_Weld_Slot :: struct {key:u64,head:u32,occupied:bool}
@(private="file") Boolean_Point_Node :: struct {lo,hi:Vec3,first,count,left,right:int}
@(private="file") Boolean_Work :: struct {
    vertices:[dynamic]Boolean_Vertex,
    polygons:[dynamic]Boolean_Polygon,
    references:[dynamic]Boolean_Reference,
    nodes:[3][dynamic]Boolean_Node, // A to classify, B, and the polygons of A as they came
    bounds:[3][2]Vec3,
    inverted:[3]bool,
    tasks:[dynamic]Boolean_Task,
    list:[dynamic]int,
    clips:[dynamic]Boolean_Clip,
    kept:[dynamic]int,
    split:[2][dynamic]Boolean_Vertex,
    points:[dynamic]Boolean_Point,
    unique:[dynamic]Vec3,
    point_nodes:[dynamic]Boolean_Point_Node,
    cuts:[dynamic]Boolean_Cut,
    boundary:[dynamic]Boolean_Vertex,
    settings:Boolean_Settings,
    epsilon:f64,
    error:Boolean_Error,
}

@(private="file") boolean_push :: proc(a:^[dynamic]$T,v:T) -> bool {_,err:=append(a,v);return err==nil}
@(private="file") boolean_append :: proc(a:^[dynamic]$T,v:[]T) -> bool {_,err:=append(a,..v);return err==nil}

@(private="file") boolean_init :: proc(w:^Boolean_Work,settings:Boolean_Settings) {
    a:=context.temp_allocator
    w.settings=settings
    w.vertices=make([dynamic]Boolean_Vertex,a)
    w.polygons=make([dynamic]Boolean_Polygon,a)
    w.references=make([dynamic]Boolean_Reference,a)
    for &nodes in w.nodes {nodes=make([dynamic]Boolean_Node,a)}
    w.tasks=make([dynamic]Boolean_Task,a)
    w.list=make([dynamic]int,a)
    w.clips=make([dynamic]Boolean_Clip,a)
    w.kept=make([dynamic]int,a)
    for &vertices in w.split {vertices=make([dynamic]Boolean_Vertex,a)}
    w.points=make([dynamic]Boolean_Point,a)
    w.unique=make([dynamic]Vec3,a)
    w.point_nodes=make([dynamic]Boolean_Point_Node,a)
    w.cuts=make([dynamic]Boolean_Cut,a)
    w.boundary=make([dynamic]Boolean_Vertex,a)
}

@(private="file") boolean_destroy :: proc(w:^Boolean_Work) {
    delete(w.vertices);delete(w.polygons);delete(w.references)
    for nodes in w.nodes {delete(nodes)}
    delete(w.tasks);delete(w.list);delete(w.clips);delete(w.kept)
    for vertices in w.split {delete(vertices)}
    delete(w.points);delete(w.unique);delete(w.point_nodes);delete(w.cuts);delete(w.boundary)
}

@(private="file") boolean_polygon :: proc(w:^Boolean_Work,vertices:[]Boolean_Vertex,plane:DPlane,material:u32) -> int {
    if len(vertices)<3 {return -1}
    if len(w.polygons)>=w.settings.max_fragments || len(vertices)>w.settings.max_vertices-len(w.vertices) {w.error=.Capacity;return -1}
    p:=Boolean_Polygon{len(w.vertices),len(vertices),plane,material}
    if !boolean_append(&w.vertices,vertices) || !boolean_push(&w.polygons,p) {w.error=.Out_Of_Memory;return -1}
    return len(w.polygons)-1
}

@(private="file") boolean_vertex_less :: proc "contextless" (a,b:DVec3) -> bool {
    return a.x<b.x || (a.x==b.x && (a.y<b.y || (a.y==b.y && a.z<b.z)))
}

@(private="file") boolean_lerp :: proc "contextless" (a,b:Boolean_Vertex,t:f64) -> Boolean_Vertex {
    v:=Boolean_Vertex{p=a.p+(b.p-a.p)*t}
    for i in 0..<3 {v.n[i]=f32(f64(a.n[i])+(f64(b.n[i])-f64(a.n[i]))*t)}
    for i in 0..<2 {v.uv[i]=f32(f64(a.uv[i])+(f64(b.uv[i])-f64(a.uv[i]))*t)}
    for i in 0..<4 {v.color[i]=f32(f64(a.color[i])+(f64(b.color[i])-f64(a.color[i]))*t)}
    return v
}

@(private="file") boolean_split :: proc(w:^Boolean_Work,id:int,plane:DPlane) -> (front,back:int,coplanar:bool) {
    p:=w.polygons[id]
    front,back=-1,-1
    has_front,has_back:=false,false
    for i in 0..<p.count {
        d:=ddot(plane.n,w.vertices[p.first+i].p)-plane.d
        has_front=has_front || d>w.epsilon
        has_back=has_back || d< -w.epsilon
    }
    if !has_front && !has_back {
        if ddot(plane.n,p.plane.n)>=0 {front=id} else {back=id}
        return front,back,true
    }
    if !has_back {return id,-1,false}
    if !has_front {return -1,id,false}
    for &v in w.split {clear(&v)}
    for i in 0..<p.count {
        a,b:=w.vertices[p.first+i],w.vertices[p.first+(i+1)%p.count]
        da,db:=ddot(plane.n,a.p)-plane.d,ddot(plane.n,b.p)-plane.d
        if da>= -w.epsilon && !boolean_push(&w.split[0],a) {w.error=.Out_Of_Memory;return}
        if da<= w.epsilon && !boolean_push(&w.split[1],a) {w.error=.Out_Of_Memory;return}
        if (da>w.epsilon && db< -w.epsilon) || (da< -w.epsilon && db>w.epsilon) {
            if boolean_vertex_less(b.p,a.p) {a,b=b,a;da,db=db,da}
            v:=boolean_lerp(a,b,clamp(da/(da-db),0,1))
            for &side in w.split {if !boolean_push(&side,v) {w.error=.Out_Of_Memory;return}}
        }
    }
    front=boolean_polygon(w,w.split[0][:],p.plane,p.material)
    if w.error!=.None {return}
    back=boolean_polygon(w,w.split[1][:],p.plane,p.material)
    return
}

@(private="file") boolean_reference :: proc(w:^Boolean_Work,node:^Boolean_Node,polygon:int) {
    if len(w.references)>=w.settings.max_fragments*4 {w.error=.Capacity;return}
    if !boolean_push(&w.references,{polygon,node.first}) {w.error=.Out_Of_Memory;return}
    node.first=len(w.references)-1
}

@(private="file") boolean_node :: proc(w:^Boolean_Work,tree:int,plane:DPlane) -> int {
    if len(w.nodes[tree])>=w.settings.max_fragments {w.error=.Capacity;return -1}
    if !boolean_push(&w.nodes[tree],{plane,-1,-1,-1}) {w.error=.Out_Of_Memory;return -1}
    return len(w.nodes[tree])-1
}

@(private="file") boolean_build :: proc(w:^Boolean_Work,tree:int,ids:[]int) {
    if len(ids)==0 {return}
    clear(&w.list);clear(&w.tasks)
    if !boolean_append(&w.list,ids) {w.error=.Out_Of_Memory;return}
    root:=0
    if len(w.nodes[tree])==0 {root=boolean_node(w,tree,w.polygons[ids[0]].plane)}
    if w.error!=.None {return}
    if !boolean_push(&w.tasks,{root,0,len(ids),0}) {w.error=.Out_Of_Memory;return}
    for len(w.tasks)>0 && w.error==.None {
        task:=pop(&w.tasks)
        if task.depth>w.settings.max_depth {w.error=.Capacity;return}
        // A single partition buffer stores front first and back second.
        front_first:=len(w.list)
        clear(&w.kept)
        for i in task.first..<task.first+task.count {
            front,back,coplanar:=boolean_split(w,w.list[i],w.nodes[tree][task.node].plane)
            if w.error!=.None {return}
            if coplanar {
                boolean_reference(w,&w.nodes[tree][task.node],front if front>=0 else back)
                if w.error!=.None {return}
            } else {
                if front>=0 && !boolean_push(&w.list,front) {w.error=.Out_Of_Memory;return}
                if back>=0 && !boolean_push(&w.kept,back) {w.error=.Out_Of_Memory;return}
            }
        }
        front_count:=len(w.list)-front_first
        back_first:=len(w.list)
        if !boolean_append(&w.list,w.kept[:]) {w.error=.Out_Of_Memory;return}
        counts:=[2]int{front_count,len(w.kept)}
        firsts:=[2]int{front_first,back_first}
        for side in 0..<2 {
            if counts[side]==0 {continue}
            child:=w.nodes[tree][task.node].front if side==0 else w.nodes[tree][task.node].back
            if child<0 {
                child=boolean_node(w,tree,w.polygons[w.list[firsts[side]]].plane)
                if w.error!=.None {return}
                if side==0 {w.nodes[tree][task.node].front=child} else {w.nodes[tree][task.node].back=child}
            }
            if !boolean_push(&w.tasks,{child,firsts[side],counts[side],task.depth+1}) {w.error=.Out_Of_Memory;return}
        }
        if len(w.list)>w.settings.max_fragments*8 {w.error=.Capacity;return}
    }
}

// Planes alone for a tree that only classifies: its polygons are shared with
// the one that keeps them.
@(private="file") boolean_invert :: proc(w:^Boolean_Work,tree:int,planes:=false) {
    w.inverted[tree]=!w.inverted[tree]
    for &node in w.nodes[tree] {
        node.plane={-node.plane.n,-node.plane.d}
        node.front,node.back=node.back,node.front
        if planes {continue}
        for ref:=node.first;ref>=0;ref=w.references[ref].next {
            p:=&w.polygons[w.references[ref].polygon]
            p.plane={-p.plane.n,-p.plane.d}
            vertices:=w.vertices[p.first:p.first+p.count]
            for &v in vertices {v.n= -v.n}
            for i in 0..<len(vertices)/2 {vertices[i],vertices[len(vertices)-1-i]=vertices[len(vertices)-1-i],vertices[i]}
        }
    }
}

@(private="file") boolean_clip_to :: proc(w:^Boolean_Work,tree,clip_tree:int) {
    if len(w.nodes[clip_tree])==0 {return}
    for ni in 0..<len(w.nodes[tree]) {
        clear(&w.clips);clear(&w.kept)
        for ref:=w.nodes[tree][ni].first;ref>=0;ref=w.references[ref].next {
            id:=w.references[ref].polygon
            p:=w.polygons[id]
            low,high:=w.vertices[p.first].p,w.vertices[p.first].p
            for i in 1..<p.count {
                v:=w.vertices[p.first+i].p
                for axis in 0..<3 {low[axis]=min(low[axis],v[axis]);high[axis]=max(high[axis],v[axis])}
            }
            disjoint:=false
            for axis in 0..<3 {disjoint=disjoint || high[axis]<f64(w.bounds[clip_tree][0][axis])-w.epsilon || low[axis]>f64(w.bounds[clip_tree][1][axis])+w.epsilon}
            if disjoint {
                if !w.inverted[clip_tree] && !boolean_push(&w.kept,id) {w.error=.Out_Of_Memory;return}
                continue
            }
            if !boolean_push(&w.clips,{0,id}) {w.error=.Out_Of_Memory;return}
        }
        for len(w.clips)>0 {
            task:=pop(&w.clips)
            node:=w.nodes[clip_tree][task.node]
            front,back,_:=boolean_split(w,task.polygon,node.plane)
            if w.error!=.None {return}
            if front>=0 {
                if node.front<0 {
                    if !boolean_push(&w.kept,front) {w.error=.Out_Of_Memory;return}
                } else if !boolean_push(&w.clips,{node.front,front}) {w.error=.Out_Of_Memory;return}
            }
            if back>=0 && node.back>=0 && !boolean_push(&w.clips,{node.back,back}) {w.error=.Out_Of_Memory;return}
        }
        w.nodes[tree][ni].first= -1
        for id in w.kept {boolean_reference(w,&w.nodes[tree][ni],id);if w.error!=.None {return}}
    }
}

@(private="file") boolean_import :: proc(w:^Boolean_Work,mesh:Mesh,ids:^[dynamic]int) {
    for t:=0;t<len(mesh.indices);t+=3 {
        vertices:[3]Boolean_Vertex
        for k in 0..<3 {
            index:=mesh.indices[t+k]
            vertices[k].p=dvec(mesh.positions[index])
            vertices[k].n=mesh.normals[index] if len(mesh.normals)>0 else Vec3{}
            vertices[k].uv=mesh.uvs[index] if len(mesh.uvs)>0 else Vec2{}
            vertices[k].color=mesh.colors[index] if len(mesh.colors)>0 else Vec4{1,1,1,1}
        }
        n:=dnormalize(dcross(vertices[1].p-vertices[0].p,vertices[2].p-vertices[0].p))
        if len(mesh.normals)==0 {for &v in vertices {v.n=fvec(n)}}
        material:=mesh.materials[t/3] if len(mesh.materials)>0 else 0
        id:=boolean_polygon(w,vertices[:],{n,ddot(n,vertices[0].p)},material)
        if w.error!=.None {return}
        if !boolean_push(ids,id) {w.error=.Out_Of_Memory;return}
    }
}

@(private="file") boolean_find :: proc(parents:[]u32,index:u32) -> u32 {
    i:=index
    for parents[i]!=i {parents[i]=parents[parents[i]];i=parents[i]}
    return i
}

// Exact position topology, including disconnected vertex fans; does not hide
// allocator failure inside a hash table or a welding operation.
@(private="file") boolean_closed :: proc(mesh:Mesh) -> Boolean_Error {
    if !mesh_is_valid(mesh) {return .Invalid_Mesh}
    for p in mesh.positions {if !finite3(p) {return .Invalid_Mesh}}
    for p in mesh.normals {if !finite3(p) {return .Invalid_Mesh}}
    for p in mesh.uvs {if !finite2(p) {return .Invalid_Mesh}}
    for p in mesh.colors {for x in p {if x-x!=0 {return .Invalid_Mesh}}}
    if len(mesh.indices)==0 {return .None}
    if len(mesh.positions)>int(max(u32)) || len(mesh.indices)>int(max(u32)) {return .Capacity}
    points,pe:=make([]Boolean_Point,len(mesh.positions),context.temp_allocator)
    remap,re:=make([]u32,len(mesh.positions),context.temp_allocator)
    edges,ee:=make([]Boolean_Edge,len(mesh.indices),context.temp_allocator)
    parents,pae:=make([]u32,len(mesh.indices),context.temp_allocator)
    fans,fe:=make([]u32,len(mesh.positions),context.temp_allocator)
    defer delete(points,context.temp_allocator);defer delete(remap,context.temp_allocator);defer delete(edges,context.temp_allocator);defer delete(parents,context.temp_allocator);defer delete(fans,context.temp_allocator)
    if pe!=nil || re!=nil || ee!=nil || pae!=nil || fe!=nil {return .Out_Of_Memory}
    for p,i in mesh.positions {points[i]={p,u32(i)};fans[i]=NONE}
    slice.sort_by(points,proc(a,b:Boolean_Point) -> bool {return boolean_vertex_less(dvec(a.p),dvec(b.p)) || (a.p==b.p && a.id<b.id)})
    canonical:=u32(0)
    for p,i in points {
        if i==0 || p.p!=points[i-1].p {canonical=p.id}
        remap[p.id]=canonical
    }
    for i:=0;i<len(mesh.indices);i+=3 {
        a,b,c:=mesh.positions[mesh.indices[i]],mesh.positions[mesh.indices[i+1]],mesh.positions[mesh.indices[i+2]]
        cross:=dcross(dvec(b)-dvec(a),dvec(c)-dvec(a))
        if ddot(cross,cross)==0 {return .Invalid_Mesh}
        for k in 0..<3 {
            edges[i+k]={remap[mesh.indices[i+k]],remap[mesh.indices[i+(k+1)%3]],u32(i+k)}
            parents[i+k]=u32(i+k)
        }
    }
    slice.sort_by(edges,proc(a,b:Boolean_Edge) -> bool {
        al,ah:=min(a.a,a.b),max(a.a,a.b);bl,bh:=min(b.a,b.b),max(b.a,b.b)
        return al<bl || (al==bl && (ah<bh || (ah==bh && a.corner<b.corner)))
    })
    if len(edges)%2!=0 {return .Not_Closed}
    for i:=0;i<len(edges);i+=2 {
        a,b:=edges[i],edges[i+1]
        if a.a!=b.b || a.b!=b.a || a.a==a.b {return .Not_Closed}
        if i+2<len(edges) && min(edges[i+2].a,edges[i+2].b)==min(a.a,a.b) && max(edges[i+2].a,edges[i+2].b)==max(a.a,a.b) {return .Not_Closed}
        next_a:=a.corner-a.corner%3+(a.corner+1)%3
        next_b:=b.corner-b.corner%3+(b.corner+1)%3
        parents[boolean_find(parents,a.corner)]=boolean_find(parents,next_b)
        parents[boolean_find(parents,b.corner)]=boolean_find(parents,next_a)
    }
    for index,i in mesh.indices {
        vertex:=remap[index]
        root:=boolean_find(parents,u32(i))
        if fans[vertex]==NONE {fans[vertex]=root} else if fans[vertex]!=root {return .Not_Closed}
    }
    return .None
}

@(private="file") boolean_cancel_faces :: proc(out:^Mesh_Buffer) -> Boolean_Error {
    if len(out.indices)==0 {return .None}
    points,pe:=make([]Boolean_Point,len(out.positions),context.temp_allocator)
    remap,re:=make([]u32,len(out.positions),context.temp_allocator)
    triangles,te:=make([]Boolean_Triangle,len(out.indices)/3,context.temp_allocator)
    keep,ke:=make([]bool,len(triangles),context.temp_allocator)
    defer delete(points,context.temp_allocator);defer delete(remap,context.temp_allocator);defer delete(triangles,context.temp_allocator);defer delete(keep,context.temp_allocator)
    if pe!=nil || re!=nil || te!=nil || ke!=nil {return .Out_Of_Memory}
    for p,i in out.positions {points[i]={p,u32(i)}}
    slice.sort_by(points,proc(a,b:Boolean_Point)->bool{return boolean_vertex_less(dvec(a.p),dvec(b.p)) || (a.p==b.p && a.id<b.id)})
    canonical:=u32(0)
    for p,i in points {if i==0 || p.p!=points[i-1].p {canonical=p.id};remap[p.id]=canonical}
    for &triangle,i in triangles {
        a,b,c:=remap[out.indices[i*3]],remap[out.indices[i*3+1]],remap[out.indices[i*3+2]]
        positive:=true
        if a>b {a,b=b,a;positive=!positive}
        if b>c {b,c=c,b;positive=!positive}
        if a>b {a,b=b,a;positive=!positive}
        triangle={a,b,c,u32(i),positive}
    }
    slice.sort_by(triangles,proc(a,b:Boolean_Triangle)->bool{return a.a<b.a || (a.a==b.a && (a.b<b.b || (a.b==b.b && (a.c<b.c || (a.c==b.c && a.index<b.index)))))})
    for first:=0;first<len(triangles); {
        last,balance:=first,0
        a:=triangles[first]
        for last<len(triangles) {
            b:=triangles[last]
            if a.a!=b.a || a.b!=b.b || a.c!=b.c {break}
            balance+=1 if b.positive else -1
            last+=1
        }
        if balance!=0 {for tri in triangles[first:last] {if tri.positive==(balance>0) {keep[tri.index]=true;break}}}
        first=last
    }
    count:=0
    for present,i in keep {
        if !present {continue}
        for k in 0..<3 {
            dst,src:=count*3+k,int(out.indices[i*3+k])
            out.positions[dst]=out.positions[src];out.normals[dst]=out.normals[src]
            if len(out.uvs)>0 {out.uvs[dst]=out.uvs[src]}
            if len(out.colors)>0 {out.colors[dst]=out.colors[src]}
            out.indices[dst]=u32(dst)
        }
        if len(out.materials)>0 {out.materials[count]=out.materials[i]}
        count+=1
    }
    base.truncate(&out.positions,count*3);base.truncate(&out.normals,count*3);base.truncate(&out.indices,count*3)
    if len(out.uvs)>0 {base.truncate(&out.uvs,count*3)}
    if len(out.colors)>0 {base.truncate(&out.colors,count*3)}
    if len(out.materials)>0 {base.truncate(&out.materials,count)}
    return .None
}

@(private="file") boolean_points_build :: proc(w:^Boolean_Work,first,count:int) -> int {
    lo,hi:=w.points[first].p,w.points[first].p
    for p in w.points[first:first+count] {
        for axis in 0..<3 {lo[axis]=min(lo[axis],p.p[axis]);hi[axis]=max(hi[axis],p.p[axis])}
    }
    id:=len(w.point_nodes)
    if !boolean_push(&w.point_nodes,{lo,hi,first,count,-1,-1}) {w.error=.Out_Of_Memory;return -1}
    if count<=8 {return id}
    d:=hi-lo
    axis:=0;if d.y>d.x {axis=1};if d.z>d[axis] {axis=2}
    switch axis {
    case 0: slice.sort_by(w.points[first:first+count],proc(a,b:Boolean_Point)->bool{return a.p.x<b.p.x || (a.p.x==b.p.x && a.id<b.id)})
    case 1: slice.sort_by(w.points[first:first+count],proc(a,b:Boolean_Point)->bool{return a.p.y<b.p.y || (a.p.y==b.p.y && a.id<b.id)})
    case 2: slice.sort_by(w.points[first:first+count],proc(a,b:Boolean_Point)->bool{return a.p.z<b.p.z || (a.p.z==b.p.z && a.id<b.id)})
    }
    half:=count/2
    left:=boolean_points_build(w,first,half)
    if w.error!=.None {return -1}
    right:=boolean_points_build(w,first+half,count-half)
    if w.error!=.None {return -1}
    w.point_nodes[id].left=left;w.point_nodes[id].right=right
    return id
}

@(private="file") boolean_edge_points :: proc(w:^Boolean_Work,a,b:DVec3) {
    clear(&w.cuts)
    delta:=b-a
    length2:=ddot(delta,delta)
    if length2==0 || len(w.point_nodes)==0 {return}
    lo,hi:DVec3
    for axis in 0..<3 {lo[axis]=min(a[axis],b[axis])-w.epsilon;hi[axis]=max(a[axis],b[axis])+w.epsilon}
    stack:[64]int
    n:=1;stack[0]=0
    for n>0 {
        n-=1;node:=w.point_nodes[stack[n]]
        if f64(node.hi.x)<lo.x || f64(node.lo.x)>hi.x || f64(node.hi.y)<lo.y || f64(node.lo.y)>hi.y || f64(node.hi.z)<lo.z || f64(node.lo.z)>hi.z {continue}
        if node.left>=0 {
            if n+2>len(stack) {w.error=.Capacity;return}
            stack[n]=node.left;stack[n+1]=node.right;n+=2
            continue
        }
        for point in w.points[node.first:node.first+node.count] {
            p:=dvec(point.p)
            t:=ddot(p-a,delta)/length2
            if t<=0 || t>=1 {continue}
            distance:=p-(a+delta*t)
            if ddot(distance,distance)>w.epsilon*w.epsilon {continue}
            if ddot(p-a,p-a)<=w.epsilon*w.epsilon || ddot(p-b,p-b)<=w.epsilon*w.epsilon {continue}
            if !boolean_push(&w.cuts,{t,point.id}) {w.error=.Out_Of_Memory;return}
        }
    }
    slice.sort_by(w.cuts[:],proc(a,b:Boolean_Cut)->bool{return a.t<b.t || (a.t==b.t && a.point<b.point)})
}

@(private="file") boolean_emit :: proc(w:^Boolean_Work,ids:[]int,out:^Mesh_Buffer,has_uvs,has_colors,has_materials:bool) {
    clear(&w.points);clear(&w.unique);clear(&w.point_nodes)
    for id in ids {
        p:=w.polygons[id]
        for i in p.first..<p.first+p.count {
            if !boolean_push(&w.points,{fvec(w.vertices[i].p),u32(i)}) {w.error=.Out_Of_Memory;return}
        }
    }
    if len(w.points)==0 {return}
    slice.sort_by(w.points[:],proc(a,b:Boolean_Point)->bool{return boolean_vertex_less(dvec(a.p),dvec(b.p)) || (a.p==b.p && a.id<b.id)})
    slots:=64
    for slots<len(w.points)*2 {slots*=2}
    grid,ge:=make([]Boolean_Weld_Slot,slots,context.temp_allocator)
    next,ne:=make([]u32,len(w.points),context.temp_allocator)
    defer delete(grid,context.temp_allocator);defer delete(next,context.temp_allocator)
    if ge!=nil || ne!=nil {w.error=.Out_Of_Memory;return}
    cell_key :: proc "contextless" (cell:[3]i64) -> u64 {return base.hash_u64(base.hash_u64(base.hash_u64(u64(cell.x))~u64(cell.y))~u64(cell.z))}
    cell_of :: proc "contextless" (p:Vec3,epsilon:f64) -> [3]i64 {
        result:[3]i64
        for i in 0..<3 {result[i]=i64(clamp(math.floor(f64(p[i])/epsilon),-4e18,4e18))}
        return result
    }
    entry :: proc "contextless" (grid:[]Boolean_Weld_Slot,key:u64) -> ^Boolean_Weld_Slot {
        index:=int(key&u64(len(grid)-1))
        for grid[index].occupied && grid[index].key!=key {index=(index+1)&(len(grid)-1)}
        return &grid[index]
    }
    // A representative never moves, so welding does not accumulate drift.
    for point in w.points {
        found:=NONE
        cell:[3]i64
        key:u64
        if w.epsilon>0 {
            cell=cell_of(point.p,w.epsilon);key=cell_key(cell)
            for z in i64(-1)..=1 {for y in i64(-1)..=1 {for x in i64(-1)..=1 {
                slot:=entry(grid,cell_key(cell+[3]i64{x,y,z}))
                if !slot.occupied {continue}
                for i:=slot.head;i!=NONE;i=next[i] {
                    if i>=found {continue}
                    d:=dvec(point.p)-dvec(w.unique[i])
                    if ddot(d,d)<=w.epsilon*w.epsilon {found=i}
                }
            }}}
        } else {
            key=position_hash(point.p)
            slot:=entry(grid,key)
            if slot.occupied {for i:=slot.head;i!=NONE;i=next[i] {if w.unique[i]==point.p {found=min(found,i)}}}
        }
        if found==NONE {
            found=u32(len(w.unique))
            if !boolean_push(&w.unique,point.p) {w.error=.Out_Of_Memory;return}
            slot:=entry(grid,key)
            next[found]=slot.head if slot.occupied else NONE
            slot^={key,found,true}
        }
        w.vertices[point.id].p=dvec(w.unique[found])
    }
    clear(&w.points)
    for p,i in w.unique {if !boolean_push(&w.points,{p,u32(i)}) {w.error=.Out_Of_Memory;return}}
    boolean_points_build(w,0,len(w.points))
    if w.error!=.None {return}
    for id in ids {
        p:=w.polygons[id]
        clear(&w.boundary)
        for i in 0..<p.count {
            a,b:=w.vertices[p.first+i],w.vertices[p.first+(i+1)%p.count]
            if a.p==b.p {continue}
            if !boolean_push(&w.boundary,a) {w.error=.Out_Of_Memory;return}
            boolean_edge_points(w,a.p,b.p)
            if w.error!=.None {return}
            for cut in w.cuts {
                v:=boolean_lerp(a,b,cut.t);v.p=dvec(w.unique[cut.point])
                if !boolean_push(&w.boundary,v) {w.error=.Out_Of_Memory;return}
            }
        }
        if len(w.boundary)<3 {continue}
        area:DVec3
        a:=w.boundary[0].p
        for i in 1..<len(w.boundary)-1 {area+=dcross(w.boundary[i].p-a,w.boundary[i+1].p-a)}
        if ddot(area,area)==0 {continue}
        center:Boolean_Vertex
        if len(w.boundary)>3 {
            normal:DVec3;uv:DVec2;color:[4]f64
            for v in w.boundary {
                center.p+=v.p;normal+=dvec(v.n)
                for k in 0..<2 {uv[k]+=f64(v.uv[k])}
                for k in 0..<4 {color[k]+=f64(v.color[k])}
            }
            divisor:=f64(len(w.boundary))
            center.p/=divisor;center.n=fvec(normal/divisor)
            for k in 0..<2 {center.uv[k]=f32(uv[k]/divisor)}
            for k in 0..<4 {center.color[k]=f32(color[k]/divisor)}
        }
        triangles:=1 if len(w.boundary)==3 else len(w.boundary)
        if triangles>(w.settings.max_vertices-len(out.positions))/3 {w.error=.Capacity;return}
        size:=len(out.positions)+triangles*3
        if reserve(&out.positions,size)!=nil || reserve(&out.normals,size)!=nil || reserve(&out.indices,size)!=nil || (has_uvs && reserve(&out.uvs,size)!=nil) || (has_colors && reserve(&out.colors,size)!=nil) || (has_materials && reserve(&out.materials,size/3)!=nil) {w.error=.Out_Of_Memory;return}
        for i in 0..<triangles {
            vertices:=[3]Boolean_Vertex{w.boundary[0],w.boundary[1],w.boundary[2]}
            if len(w.boundary)>3 {vertices={center,w.boundary[i],w.boundary[(i+1)%len(w.boundary)]}}
            positions:=[3]Vec3{fvec(vertices[0].p),fvec(vertices[1].p),fvec(vertices[2].p)}
            cross:=dcross(dvec(positions[1])-dvec(positions[0]),dvec(positions[2])-dvec(positions[0]))
            if ddot(cross,cross)==0 {continue}
            first:=u32(len(out.positions))
            for v,k in vertices {
                normal:=dnormalize(dvec(v.n));if normal==(DVec3{}) {normal=p.plane.n}
                append(&out.positions,positions[k]);append(&out.normals,fvec(normal))
                if has_uvs {append(&out.uvs,v.uv)}
                if has_colors {append(&out.colors,v.color)}
            }
            append(&out.indices,first,first+1,first+2)
            if has_materials {append(&out.materials,p.material)}
        }
    }
}

// Closed, outward triangle surfaces. Attribute seams remain separate; the
// position topology is repaired and checked before returning a result.
mesh_boolean :: proc(a,b:Mesh,op:Boolean_Op,out:^Mesh_Buffer,settings:Boolean_Settings={}) -> (error:Boolean_Error) {
    if out==nil {return .Invalid_Settings}
    mesh_buffer_clear(out)
    defer if error!=.None {mesh_buffer_clear(out)}
    if op!=.Union && op!=.Subtract && op!=.Intersect {return .Invalid_Settings}
    settings:=settings
    if settings.tolerance<0 || settings.tolerance-settings.tolerance!=0 || settings.max_fragments<0 || settings.max_vertices<0 || settings.max_depth<0 {return .Invalid_Settings}
    if settings.max_fragments==0 {settings.max_fragments=262144}
    if settings.max_vertices==0 {settings.max_vertices=4194304}
    if settings.max_depth==0 {settings.max_depth=4096}
    if settings.max_fragments>max(int)/16 || settings.max_vertices>int(max(u32)) || settings.max_depth>65536 {return .Invalid_Settings}
    if len(a.indices)/3+len(b.indices)/3>settings.max_fragments || len(a.indices)>settings.max_vertices || len(b.indices)>settings.max_vertices-len(a.indices) {return .Capacity}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.positions.allocator))
    for mesh in ([2]Mesh{a,b}) {
        e:=boolean_closed(mesh)
        if e!=.None {return e}
        if len(mesh.indices)>0 {
            low,high:=mesh_bounds(mesh.positions)
            origin:=(dvec(low)+dvec(high))*0.5
            volume:f64
            for i:=0;i<len(mesh.indices);i+=3 {
                a,b,c:=dvec(mesh.positions[mesh.indices[i]])-origin,dvec(mesh.positions[mesh.indices[i+1]])-origin,dvec(mesh.positions[mesh.indices[i+2]])-origin
                volume+=ddot(a,dcross(b,c))
            }
            if !(volume>0) {return .No_Volume}
        }
    }
    w:Boolean_Work
    boolean_init(&w,settings)
    defer boolean_destroy(&w)
    scale:=max(positions_max_abs(a.positions),positions_max_abs(b.positions))
    w.epsilon=max(f64(settings.tolerance),f64(tolerance_noise(scale)))
    ids:=[2][dynamic]int{make([dynamic]int,context.temp_allocator),make([dynamic]int,context.temp_allocator)}
    defer for list in ids {delete(list)}
    boolean_import(&w,a,&ids[0]);if w.error!=.None {return w.error}
    boolean_import(&w,b,&ids[1]);if w.error!=.None {return w.error}
    result:=make([dynamic]int,context.temp_allocator)
    defer delete(result)
    alo,ahi:=mesh_bounds(a.positions);blo,bhi:=mesh_bounds(b.positions)
    w.bounds={{alo,ahi},{blo,bhi},{alo,ahi}}
    disjoint:=f64(ahi.x)<f64(blo.x)-w.epsilon || f64(bhi.x)<f64(alo.x)-w.epsilon || f64(ahi.y)<f64(blo.y)-w.epsilon || f64(bhi.y)<f64(alo.y)-w.epsilon || f64(ahi.z)<f64(blo.z)-w.epsilon || f64(bhi.z)<f64(alo.z)-w.epsilon
    if len(ids[0])==0 || len(ids[1])==0 || disjoint {
        if op==.Union || op==.Subtract {if !boolean_append(&result,ids[0][:]) {return .Out_Of_Memory}}
        if op==.Union {if !boolean_append(&result,ids[1][:]) {return .Out_Of_Memory}}
    } else {
        // The tree of A only classifies what B keeps: the polygons of A are
        // cut by the planes of B alone, so the planes of a surface that is
        // not flat do not slice it where B is not.
        boolean_build(&w,0,ids[0][:]);if w.error!=.None {return w.error}
        boolean_build(&w,1,ids[1][:]);if w.error!=.None {return w.error}
        boolean_node(&w,2,{});if w.error!=.None {return w.error}
        for id in ids[0] {boolean_reference(&w,&w.nodes[2][0],id);if w.error!=.None {return w.error}}
        switch op {
        case .Union:
            boolean_clip_to(&w,2,1);if w.error!=.None {return w.error}
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
            boolean_invert(&w,1)
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
            boolean_invert(&w,1)
        case .Subtract:
            boolean_invert(&w,0,planes=true);boolean_invert(&w,2)
            boolean_clip_to(&w,2,1);if w.error!=.None {return w.error}
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
            boolean_invert(&w,1)
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
            boolean_invert(&w,1)
        case .Intersect:
            boolean_invert(&w,0,planes=true);boolean_invert(&w,2)
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
            boolean_invert(&w,1)
            boolean_clip_to(&w,2,1);if w.error!=.None {return w.error}
            boolean_clip_to(&w,1,0);if w.error!=.None {return w.error}
        }
        if op==.Subtract || op==.Intersect {boolean_invert(&w,2);boolean_invert(&w,1)}
        clear(&result)
        for tree in ([2]int{2,1}) {
            for node in w.nodes[tree] {for ref:=node.first;ref>=0;ref=w.references[ref].next {if !boolean_push(&result,w.references[ref].polygon) {return .Out_Of_Memory}}}
        }
    }
    boolean_emit(&w,result[:],out,len(a.uvs)>0 || len(b.uvs)>0,len(a.colors)>0 || len(b.colors)>0,len(a.materials)>0 || len(b.materials)>0)
    if w.error!=.None {return w.error}
    if e:=boolean_cancel_faces(out);e!=.None {return e}
    e:=boolean_closed(mesh_buffer_view(out))
    if e==.Out_Of_Memory {return e}
    if e!=.None {return .Topology}
    return .None
}
