package rig

import "core:math"
import "core:math/linalg"
import "core:slice"
import mm "mirai:std/math"
import "mirai:std/base"

// Where the joints of an animal template are in a mesh: the template's own
// surface (the samples of its model, weighted to its bones) is deformed by
// its skin until it covers the mesh, and the joints go where the deformation
// takes them. Each joint turns, stretches the bone that ends at it and
// thickens what it carries; the two sides share those, mirrored, and the
// joints on the centre line only bend up and down. Between rounds the pairs
// of nearest points are found again (ICP); in a round, Levenberg-Marquardt
// over the fixed pairs, with a soft L1 loss so a horn the template has not
// pulls little.
//
// The deformation starts from the template stretched over the mesh's box,
// or, when it covers the mesh better, with the rows of legs (blobs of a low
// section along z) moved onto those of the mesh.

Animal :: enum u8 {Fox,Horse,Bird,Dragon,Kaiju,Shark,Snake,Spider}

Bone :: struct {
    name:string,
    parent:i32,           // row of the parent; parents before children
    translation:[3]f32,
    rotation:[4]f32,      // x, y, z, w
}

// A point of the template's surface and its weights to the bones; the layout
// of the files gen_rig_templates.py writes.
Sample :: struct #packed {
    position:[3]f32,
    bones:[4]u8,
    weights:[4]u8, // sum to 255
}

Template :: struct {
    root:string, // the node above the bones, and the first of their paths
    bones:[]Bone,
    samples:[]Sample,
}

Registration :: struct {
    joints:[]mm.Vec3, // by bone: where it is in the mesh
    coverage:f32,     // the mean distance between the deformed template and the mesh, in sizes of the mesh
}

// Points of the mesh the template is deformed onto.
REGISTER_POINTS :: 800
@(private="file")
ROUNDS :: 12
@(private="file")
STEPS :: 6
@(private="file")
LOSS_SCALE :: 0.035 // where a pair starts to count less, in sizes
@(private="file")
STEP :: 1e-4        // of the finite differences
@(private="file")
CONVERGED :: 1e-4   // a step that lowers the cost less than this fraction ends the round

@(private="file")
Vec :: [3]f64
@(private="file")
Mat :: matrix[3,3]f64
@(private="file")
IDENTITY :: Mat{1,0,0, 0,1,0, 0,0,1}

@(private="file")
Model :: struct {
    parents:[]i32,
    rest,points:[]Vec,      // joints and samples of the template, after the start
    bones:[][4]u8,
    weights:[][4]f64,
    mirror:[]int,           // the joint on the other side; itself on the centre line
    center:[]bool,          // bends only about x
    slot:[]int,             // first parameter of the joint, or of its mirror
    dir:[]Vec,              // where the joint's points stretch with a bone
    along:[]int,            // the joint whose length stretches them; -1: its thickness
    count:int,              // parameters: translation, log scale, then by joint
    // Per point: the parameters that move it (CSR), and where each has its derivative.
    moved_first:[]int,
    moved:[]int,
}

// What a round of the solver works in, made once for all rounds.
@(private="file")
Solver :: struct {
    points:[]Vec,
    jac:[]Vec,          // d point / d parameter, in sizes, by entry of Model.moved
    by_first,by:[]int,  // by parameter, the entries of the points it moves (CSR)
    point_at:[]int,     // the point of an entry
    H,A:[]f64,          // the normal equations and their damped copy, n×n
    grad,step,trial,shifted:[]f64,
}

@(private="file")
solver_make :: proc(m:^Model) -> (s:Solver) {
    n:=m.count
    np:=len(m.points)
    s.points=make([]Vec,np,context.temp_allocator)
    s.jac=make([]Vec,len(m.moved),context.temp_allocator)
    s.by_first=make([]int,n+1,context.temp_allocator)
    for p in m.moved {s.by_first[p+1]+=1}
    for k in 0..<n {s.by_first[k+1]+=s.by_first[k]}
    s.by=make([]int,len(m.moved),context.temp_allocator)
    s.point_at=make([]int,len(m.moved),context.temp_allocator)
    fill:=make([]int,n,context.temp_allocator)
    for i in 0..<np {
        for e in m.moved_first[i]..<m.moved_first[i+1] {
            p:=m.moved[e]
            s.by[s.by_first[p]+fill[p]]=e
            fill[p]+=1
            s.point_at[e]=i
        }
    }
    s.H=make([]f64,n*n,context.temp_allocator)
    s.A=make([]f64,n*n,context.temp_allocator)
    s.grad=make([]f64,n,context.temp_allocator)
    s.step=make([]f64,n,context.temp_allocator)
    s.trial=make([]f64,n,context.temp_allocator)
    s.shifted=make([]f64,n,context.temp_allocator)
    return
}

@(private="file")
Pose :: struct {
    joints:[]Vec,
    linear:[]Mat,
    offset:[]Vec,
    turn:[]Mat,
}

register :: proc(template:Template,meshes:[]Mesh,allocator:=context.allocator) -> (out:Registration,ok:bool) {
    target,sampled:=surface_sample(meshes,REGISTER_POINTS)
    if !sampled {return}
    lo,hi:=bounds(target)
    size:=max(hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)
    if !(size>0) {return}
    nb:=len(template.bones)
    rest:=make([]Vec,nb,context.temp_allocator)
    turns:=make([]mm.Quat,nb,context.temp_allocator)
    for bone,i in template.bones {
        q:=quaternion(x=bone.rotation[0],y=bone.rotation[1],z=bone.rotation[2],w=bone.rotation[3])
        if bone.parent<0 {
            rest[i],turns[i]=vec(bone.translation),q
        } else {
            rest[i]=rest[bone.parent]+vec(mm.quat_rotate(turns[bone.parent],bone.translation))
            turns[i]=turns[bone.parent]*q
        }
    }
    samples:=make([]Vec,len(template.samples),context.temp_allocator)
    for s,i in template.samples {samples[i]=vec(s.position)}
    // The start: the box, or the rows of legs when they cover the mesh better.
    tlo,thi:=bounds(samples)
    box:=Warp{from_lo=tlo,from_hi=thi,to_lo=lo,to_hi=hi}
    rows:=box
    rows_count:=warp_rows(&rows,samples,target)
    start:=box
    if rows_count>0 && coverage(rows,samples,target)<coverage(box,samples,target) {start=rows}
    m:=model_make(template,rest,samples,start,max(thi.x-tlo.x,thi.y-tlo.y,thi.z-tlo.z))
    x:=make([]f64,m.count,context.temp_allocator)
    pose:=pose_make(nb)
    points:=make([]Vec,len(samples),context.temp_allocator)
    goal:=make([]Vec,len(samples),context.temp_allocator)
    weight:=make([]f64,len(samples),context.temp_allocator)
    solver:=solver_make(&m)
    for round in 0..<ROUNDS {
        strength:=REG_LOOSE if round>=ROUNDS/2 else REG_TIGHT
        model_points(&m,x,&pose,points)
        pairs(points,target,goal,weight)
        solve(&m,&solver,x,goal,weight,strength,size,&pose)
    }
    model_points(&m,x,&pose,points)
    out.joints=make([]mm.Vec3,nb,allocator)
    for j,i in pose.joints {out.joints[i]=mm.Vec3{f32(j.x),f32(j.y),f32(j.z)}}
    total:f64
    for p in points {total+=math.sqrt(nearest(target,p))}
    for p in target {total+=math.sqrt(nearest(points,p))}
    out.coverage=f32(total/f64(len(points)+len(target))/size)
    return out,true
}

@(private="file")
vec :: #force_inline proc "contextless" (v:[3]f32) -> Vec {return {f64(v.x),f64(v.y),f64(v.z)}}

@(private="file")
bounds :: proc(points:[]Vec) -> (lo,hi:Vec) {
    lo,hi=max(f64),min(f64)
    for p in points {lo,hi=linalg.min(lo,p),linalg.max(hi,p)}
    return
}

@(private="file")
nearest :: proc(points:[]Vec,p:Vec) -> (best:f64) {
    best=max(f64)
    for q in points {best=min(best,linalg.length2(q-p))}
    return
}

@(private="file")
nearest_index :: proc(points:[]Vec,p:Vec) -> (at:int) {
    best:=max(f64)
    for q,i in points {
        if d:=linalg.length2(q-p);d<best {best,at=d,i}
    }
    return
}

// Points of the surface spread by area, the same for the same meshes.
@(private="file")
surface_sample :: proc(meshes:[]Mesh,count:int) -> (points:[]Vec,ok:bool) {
    areas:=make([dynamic]f64,context.temp_allocator)
    corners:=make([dynamic][3]Vec,context.temp_allocator)
    total:f64
    for mesh in meshes {
        for i:=0;i+2<len(mesh.indices);i+=3 {
            a,b,c:=vec(mesh.positions[mesh.indices[i]]),vec(mesh.positions[mesh.indices[i+1]]),vec(mesh.positions[mesh.indices[i+2]])
            area:=linalg.length(linalg.cross(b-a,c-a))/2
            if !(area>0) || math.is_inf(area) {continue}
            total+=area
            append(&areas,total)
            append(&corners,[3]Vec{a,b,c})
        }
    }
    if len(areas)==0 {return}
    points=make([]Vec,count,context.temp_allocator)
    state:=u64(0x9e3779b97f4a7c15)
    for &p in points {
        at,_:=slice.binary_search(areas[:],random(&state)*total)
        at=min(at,len(areas)-1)
        u,v:=random(&state),random(&state)
        if u+v>1 {u,v=1-u,1-v}
        t:=corners[at]
        p=t[0]+(t[1]-t[0])*u+(t[2]-t[0])*v
    }
    return points,true
}

// In [0,1).
@(private="file")
random :: proc "contextless" (state:^u64) -> f64 {return f64(base.splitmix_next(state)>>11)/f64(u64(1)<<53)}

// Template space to mesh space: the box's, and z through matched rows of legs.
@(private="file")
Warp :: struct {
    from_lo,from_hi,to_lo,to_hi:Vec,
    knots:[8][2]f64, // z in fractions of the box, template's and mesh's
    count:int,
}

@(private="file")
warp :: proc(w:Warp,p:Vec) -> (q:Vec) {
    for k in 0..<3 {
        span:=w.from_hi[k]-w.from_lo[k]
        u:=(p[k]-w.from_lo[k])/span if span>0 else 0.5
        if k==2 && w.count>0 {u=warp_knots(w,u)}
        q[k]=w.to_lo[k]+u*(w.to_hi[k]-w.to_lo[k])
    }
    return
}

@(private="file")
warp_knots :: proc(w:Warp,u:f64) -> f64 {
    xs:[10]f64
    ys:[10]f64
    xs[0],ys[0]=0,0
    for k in 0..<w.count {xs[k+1],ys[k+1]=w.knots[k][0],w.knots[k][1]}
    n:=w.count+2
    xs[n-1],ys[n-1]=1,1
    segment:=0
    for segment<n-2 && u>xs[segment+1] {segment+=1}
    t:=(u-xs[segment])/(xs[segment+1]-xs[segment])
    return ys[segment]+t*(ys[segment+1]-ys[segment])
}

// The z of the rows of legs (or fins): blobs of a low section, merged across
// the midline, in fractions of the box along z; at most 8.
@(private="file")
leg_rows :: proc(points:[]Vec) -> (rows:[8]f64,count:int) {
    BAND :: 0.12
    CELL :: 0.025
    GRID :: 48
    lo,hi:=bounds(points)
    height,size:=hi.y-lo.y,max(hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)
    if !(height>0) || !(hi.z>lo.z) {return}
    low:=make([dynamic]Vec,context.temp_allocator)
    for p in points {if p.y<lo.y+BAND*height {append(&low,p)}}
    cell:=CELL*size
    cell_of :: proc(p,lo:Vec,cell:f64) -> [2]int {return {clamp(int((p.x-lo.x)/cell),0,GRID-1),clamp(int((p.z-lo.z)/cell),0,GRID-1)}}
    filled:[GRID][GRID]bool
    for p in low {c:=cell_of(p,lo,cell);filled[c.x][c.y]=true}
    // A cell joins its neighbours' blob (one dilation) by flood fill.
    label:[GRID][GRID]int
    blobs:=0
    stack:=make([dynamic][2]int,context.temp_allocator)
    near :: proc(filled:^[GRID][GRID]bool,c:[2]int) -> bool {
        for dx in -1..=1 {
            for dz in -1..=1 {
                x,z:=c.x+dx,c.y+dz
                if x>=0 && z>=0 && x<GRID && z<GRID && filled[x][z] {return true}
            }
        }
        return false
    }
    for x in 0..<GRID {
        for z in 0..<GRID {
            if label[x][z]!=0 || !near(&filled,{x,z}) {continue}
            blobs+=1
            label[x][z]=blobs
            append(&stack,[2]int{x,z})
            for len(stack)>0 {
                c:=pop(&stack)
                for dx in -1..=1 {
                    for dz in -1..=1 {
                        n:=[2]int{c.x+dx,c.y+dz}
                        if n.x<0 || n.y<0 || n.x>=GRID || n.y>=GRID || label[n.x][n.y]!=0 || !near(&filled,n) {continue}
                        label[n.x][n.y]=blobs
                        append(&stack,n)
                    }
                }
            }
        }
    }
    sums:=make([]f64,blobs+1,context.temp_allocator)
    counts:=make([]int,blobs+1,context.temp_allocator)
    for p in low {
        c:=cell_of(p,lo,cell)
        b:=label[c.x][c.y]
        sums[b]+=p.z
        counts[b]+=1
    }
    zs:=make([dynamic]f64,context.temp_allocator)
    for b in 1..=blobs {
        if f64(counts[b])>=0.02*f64(len(low)) {append(&zs,sums[b]/f64(counts[b]))}
    }
    slice.sort(zs[:])
    group_sum,group_count:f64
    for z,i in zs {
        if i>0 && z-zs[i-1]>=0.1*size {
            if count<len(rows) {rows[count]=(group_sum/group_count-lo.z)/(hi.z-lo.z);count+=1}
            group_sum,group_count=0,0
        }
        group_sum+=z
        group_count+=1
    }
    if group_count>0 && count<len(rows) {rows[count]=(group_sum/group_count-lo.z)/(hi.z-lo.z);count+=1}
    return
}

// Matches the rows of the template to the mesh's: in order when both have as
// many, else each of the mesh's to the template's nearest within a tenth.
@(private="file")
warp_rows :: proc(w:^Warp,template,target:[]Vec) -> int {
    a,na:=leg_rows(template)
    b,nb:=leg_rows(target)
    w.count=0
    if na==0 || nb==0 {return 0}
    if na==nb {
        for k in 0..<na {w.knots[k]={a[k],b[k]}}
        w.count=na
    } else {
        for k in 0..<nb {
            best:=0
            for j in 1..<na {if abs(a[j]-b[k])<abs(a[best]-b[k]) {best=j}}
            if abs(a[best]-b[k])<0.1 && w.count<len(w.knots) {w.knots[w.count]={a[best],b[k]};w.count+=1}
        }
    }
    for k in 0..<w.count {
        if k>0 && (w.knots[k][0]<=w.knots[k-1][0] || w.knots[k][1]<=w.knots[k-1][1]) {w.count=0;break}
        if w.knots[k][0]<=0 || w.knots[k][0]>=1 || w.knots[k][1]<=0 || w.knots[k][1]>=1 {w.count=0;break}
    }
    return w.count
}

@(private="file")
coverage :: proc(w:Warp,template,target:[]Vec) -> f64 {
    moved:=make([]Vec,len(template),context.temp_allocator)
    for p,i in template {moved[i]=warp(w,p)}
    total:f64
    for p in moved {total+=math.sqrt(nearest(target,p))}
    for p in target {total+=math.sqrt(nearest(moved,p))}
    return total
}

// template_size is the template's, which its joints are measured in for the mirror pairs.
@(private="file")
model_make :: proc(template:Template,rest,samples:[]Vec,start:Warp,template_size:f64) -> (m:Model) {
    nb:=len(template.bones)
    m.parents=make([]i32,nb,context.temp_allocator)
    m.rest=make([]Vec,nb,context.temp_allocator)
    for bone,i in template.bones {m.parents[i]=bone.parent;m.rest[i]=warp(start,rest[i])}
    m.points=make([]Vec,len(samples),context.temp_allocator)
    m.bones=make([][4]u8,len(samples),context.temp_allocator)
    m.weights=make([][4]f64,len(samples),context.temp_allocator)
    for s,i in template.samples {
        m.points[i]=warp(start,samples[i])
        m.bones[i]=s.bones
        total:=f64(s.weights[0])+f64(s.weights[1])+f64(s.weights[2])+f64(s.weights[3])
        for k in 0..<4 {m.weights[i][k]=f64(s.weights[k])/total if total>0 else (1 if k==0 else 0)}
        for k in 0..<4 {if int(s.bones[k])>=nb {m.weights[i][k]=0}}
    }
    // Mirror pairs and the centre line, by where the joints are.
    eps:=0.01*template_size
    m.mirror=make([]int,nb,context.temp_allocator)
    m.center=make([]bool,nb,context.temp_allocator)
    for i in 0..<nb {
        m.mirror[i]=i
        flipped:=Vec{-rest[i].x,rest[i].y,rest[i].z}
        best:=max(f64)
        for j in 0..<nb {
            if d:=linalg.length(rest[j]-flipped);d<best {best,m.mirror[i]=d,j}
        }
        if best>=eps {m.mirror[i]=i}
        m.center[i]=m.mirror[i]==i && abs(rest[i].x)<eps
    }
    for i in 0..<nb {if m.mirror[m.mirror[i]]!=i {m.mirror[i]=i}}
    m.slot=make([]int,nb,context.temp_allocator)
    m.count=6
    for i in 0..<nb {
        if m.mirror[i]<i {m.slot[i]=m.slot[m.mirror[i]];continue}
        m.slot[i]=m.count
        m.count+=(1 if m.center[i] else 3)+2
    }
    m.dir=make([]Vec,nb,context.temp_allocator)
    m.along=make([]int,nb,context.temp_allocator)
    children:=make([]int,nb,context.temp_allocator)
    only:=make([]int,nb,context.temp_allocator)
    for parent,i in m.parents {
        if parent>=0 {children[parent]+=1;only[parent]=i}
    }
    for i in 0..<nb {
        d:Vec
        m.along[i]=-1
        switch {
        case children[i]==1: d,m.along[i]=m.rest[only[i]]-m.rest[i],only[i]
        case children[i]==0 && m.parents[i]>=0: d,m.along[i]=m.rest[i]-m.rest[m.parents[i]],i
        }
        if l:=linalg.length(d);l>1e-9 {m.dir[i]=d/l} else {m.along[i]=-1}
    }
    // What moves a point: the global parameters and those of its joints' ancestors.
    m.moved_first=make([]int,len(samples)+1,context.temp_allocator)
    moved:=make([dynamic]int,context.temp_allocator)
    seen:=make([]int,m.count,context.temp_allocator)
    for &s in seen {s=-1}
    for i in 0..<len(samples) {
        m.moved_first[i]=len(moved)
        for k in 0..<6 {append(&moved,k);seen[k]=i}
        for k in 0..<4 {
            if m.weights[i][k]<=0 {continue}
            for j:=int(m.bones[i][k]);j>=0;j=int(m.parents[j]) {
                first:=m.slot[j]
                n:=(1 if m.center[j] else 3)+2
                for p in first..<first+n {
                    if seen[p]==i {continue}
                    seen[p]=i
                    append(&moved,p)
                }
                // The joint's own length moves its points; so does the length of the one they stretch with.
                if a:=m.along[j];a>=0 {
                    p:=m.slot[a]+(1 if m.center[a] else 3)
                    if seen[p]!=i {seen[p]=i;append(&moved,p)}
                }
            }
        }
    }
    m.moved_first[len(samples)]=len(moved)
    m.moved=moved[:]
    return
}

@(private="file")
pose_make :: proc(nb:int) -> Pose {
    return {
        joints=make([]Vec,nb,context.temp_allocator),
        linear=make([]Mat,nb,context.temp_allocator),
        offset=make([]Vec,nb,context.temp_allocator),
        turn=make([]Mat,nb,context.temp_allocator),
    }
}

@(private="file")
rodrigues :: proc(r:Vec) -> Mat {
    angle:=linalg.length(r)
    if angle<1e-12 {return IDENTITY}
    k:=r/angle
    K:=Mat{0,-k.z,k.y, k.z,0,-k.x, -k.y,k.x,0}
    return IDENTITY+math.sin(angle)*K+(1-math.cos(angle))*(K*K)
}

// A joint's rotation, length and thickness, from its slot or its mirror's.
@(private="file")
joint_parameters :: proc(m:^Model,x:[]f64,i:int) -> (r:Vec,length,thickness:f64) {
    s:=m.slot[i]
    n:=1 if m.center[i] else 3
    if n==1 {r={x[s],0,0}} else {r={x[s],x[s+1],x[s+2]}}
    if m.mirror[i]<i {r={r.x,-r.y,-r.z}}
    return r,x[s+n],x[s+n+1]
}

@(private="file")
model_pose :: proc(m:^Model,x:[]f64,pose:^Pose) {
    g:=Vec{math.exp(x[3]),math.exp(x[4]),math.exp(x[5])}
    t:=Vec{x[0],x[1],x[2]}
    scale:=Mat{g.x,0,0, 0,g.y,0, 0,0,g.z}
    for parent,i in m.parents {
        r,length,_:=joint_parameters(m,x,i)
        local:=rodrigues(r)
        if parent<0 {
            pose.turn[i]=local
            pose.joints[i]=t+m.rest[i]*g
        } else {
            pose.turn[i]=pose.turn[parent]*local
            pose.joints[i]=pose.joints[parent]+pose.turn[parent]*(math.exp(length)*(m.rest[i]-m.rest[parent])*g)
        }
    }
    for i in 0..<len(m.parents) {
        _,_,thickness:=joint_parameters(m,x,i)
        d:=m.dir[i]*g
        if l:=linalg.length(d);l>0 {d/=l}
        across:=math.exp(thickness)
        stretch:=across
        if a:=m.along[i];a>=0 {_,stretch,_=joint_parameters(m,x,a);stretch=math.exp(stretch)}
        dd:=linalg.outer_product(d,d)
        D:=across*(IDENTITY-dd)+stretch*dd
        pose.linear[i]=pose.turn[i]*D*scale
        pose.offset[i]=pose.joints[i]-pose.linear[i]*m.rest[i]
    }
}

@(private="file")
point_of :: #force_inline proc(m:^Model,pose:^Pose,i:int) -> (p:Vec) {
    for k in 0..<4 {
        w:=m.weights[i][k]
        if w<=0 {continue}
        b:=m.bones[i][k]
        p+=w*(pose.linear[b]*m.points[i]+pose.offset[b])
    }
    return
}

@(private="file")
model_points :: proc(m:^Model,x:[]f64,pose:^Pose,out:[]Vec) {
    model_pose(m,x,pose)
    for &p,i in out {p=point_of(m,pose,i)}
}

// The pairs of a round folded into one goal per template point: its nearest
// point of the mesh, and the mean of the mesh's points it is nearest to,
// weighted by how many they are.
@(private="file")
pairs :: proc(points,target:[]Vec,goal:[]Vec,weight:[]f64) {
    sums:=make([]Vec,len(points),context.temp_allocator)
    counts:=make([]int,len(points),context.temp_allocator)
    for p in target {
        at:=nearest_index(points,p)
        sums[at]+=p
        counts[at]+=1
    }
    share:=f64(len(points))/f64(len(target))
    for p,i in points {
        c:=target[nearest_index(target,p)]
        w:=1+share*f64(counts[i])
        goal[i]=(c+share*sums[i])/w
        weight[i]=w
    }
}

@(private="file")
REG_TIGHT :: [4]f64{0.3,0.3,0.3,0.6}
@(private="file")
REG_LOOSE :: [4]f64{0.15,0.15,0.15,0.3}

// The regularization as rows of at most two parameters: each parameter of a
// joint toward zero, and the length and thickness of a joint toward its parent's.
@(private="file")
Reg_Row :: struct {at:[2]int,coef:[2]f64}

@(private="file")
reg_rows :: proc(m:^Model,strength:[4]f64,scale:f64) -> []Reg_Row {
    rows:=make([dynamic]Reg_Row,context.temp_allocator)
    for i in 0..<len(m.parents) {
        if m.mirror[i]<i {continue}
        s:=m.slot[i]
        n:=1 if m.center[i] else 3
        for k in 0..<n {append(&rows,Reg_Row{{s+k,-1},{strength[0]*scale,0}})}
        append(&rows,Reg_Row{{s+n,-1},{strength[1]*scale,0}})
        append(&rows,Reg_Row{{s+n+1,-1},{strength[2]*scale,0}})
    }
    for parent,i in m.parents {
        if parent<0 {continue}
        a,b:=i,int(parent)
        na,nb:=1 if m.center[a] else 3,1 if m.center[b] else 3
        for k in 0..<2 {
            pa,pb:=m.slot[a]+na+k,m.slot[b]+nb+k
            if pa==pb {continue}
            append(&rows,Reg_Row{{pa,pb},{strength[3]*scale,-strength[3]*scale}})
        }
    }
    return rows[:]
}

@(private="file")
reg_value :: #force_inline proc(row:Reg_Row,x:[]f64) -> f64 {
    v:=row.coef[0]*x[row.at[0]]
    if row.at[1]>=0 {v+=row.coef[1]*x[row.at[1]]}
    return v
}

// Soft L1 over the distance of a point to its goal: its cost and the weight
// of its square in the step (iteratively reweighted).
@(private="file")
loss :: #force_inline proc(d2:f64) -> (cost,slope:f64) {
    z:=d2/(LOSS_SCALE*LOSS_SCALE)
    root:=math.sqrt(1+z)
    return 2*(root-1)*LOSS_SCALE*LOSS_SCALE,1/root
}

@(private="file")
solve_cost :: proc(m:^Model,x:[]f64,goal:[]Vec,weight:[]f64,rows:[]Reg_Row,size:f64,pose:^Pose,points:[]Vec) -> (total:f64) {
    model_points(m,x,pose,points)
    for p,i in points {
        c,_:=loss(linalg.length2(p-goal[i])/(size*size))
        total+=weight[i]*c
    }
    for row in rows {v:=reg_value(row,x);total+=v*v}
    return
}

@(private="file")
solve :: proc(m:^Model,s:^Solver,x:[]f64,goal:[]Vec,weight:[]f64,strength:[4]f64,size:f64,pose:^Pose) {
    n:=m.count
    np:=len(m.points)
    rows:=reg_rows(m,strength,math.sqrt(f64(np))*0.05)
    points,jac,by_first,by,point_at:=s.points,s.jac,s.by_first,s.by,s.point_at
    H,A,grad,step,trial,shifted:=s.H,s.A,s.grad,s.step,s.trial,s.shifted
    lambda:=1e-3
    cost:=solve_cost(m,x,goal,weight,rows,size,pose,points)
    for _ in 0..<STEPS {
        model_points(m,x,pose,points)
        copy(shifted,x)
        for k in 0..<n {
            shifted[k]=x[k]+STEP
            model_pose(m,shifted,pose)
            for e in by[by_first[k]:by_first[k+1]] {
                i:=point_at[e]
                jac[e]=(point_of(m,pose,i)-points[i])/(STEP*size)
            }
            shifted[k]=x[k]
        }
        slice.fill(H,0)
        slice.fill(grad,0)
        for i in 0..<np {
            r:=(points[i]-goal[i])/size
            _,slope:=loss(linalg.length2(r))
            w:=weight[i]*slope
            first,last:=m.moved_first[i],m.moved_first[i+1]
            for e in first..<last {
                a:=m.moved[e]
                ja:=jac[e]
                grad[a]+=w*linalg.dot(ja,r)
                for f in e..<last {
                    v:=w*linalg.dot(ja,jac[f])
                    b:=m.moved[f]
                    H[a*n+b]+=v
                    if a!=b {H[b*n+a]+=v}
                }
            }
        }
        for row in rows {
            v:=reg_value(row,x)
            for s in 0..<2 {
                a:=row.at[s]
                if a<0 {continue}
                grad[a]+=row.coef[s]*v
                for t in 0..<2 {
                    b:=row.at[t]
                    if b>=0 {H[a*n+b]+=row.coef[s]*row.coef[t]}
                }
            }
        }
        improved:=false
        for _ in 0..<8 {
            copy(A,H)
            for k in 0..<n {A[k*n+k]+=lambda*max(H[k*n+k],1e-9)}
            for k in 0..<n {step[k]=-grad[k]}
            if !cholesky_solve(A,step,n) {lambda*=10;continue}
            for k in 0..<n {trial[k]=x[k]+step[k]}
            if next:=solve_cost(m,trial,goal,weight,rows,size,pose,points);next<cost {
                copy(x,trial)
                improved=cost-next>CONVERGED*cost
                cost=next
                lambda=max(lambda/3,1e-7)
                break
            }
            lambda*=10
        }
        if !improved {break}
    }
}

// Solves A·x=b in place for a symmetric positive definite A (n×n, row major).
@(private="file")
cholesky_solve :: proc(A:[]f64,b:[]f64,n:int) -> bool {
    for j in 0..<n {
        d:=A[j*n+j]
        for k in 0..<j {d-=A[j*n+k]*A[j*n+k]}
        if !(d>0) {return false}
        d=math.sqrt(d)
        A[j*n+j]=d
        for i in j+1..<n {
            s:=A[i*n+j]
            for k in 0..<j {s-=A[i*n+k]*A[j*n+k]}
            A[i*n+j]=s/d
        }
    }
    for i in 0..<n {
        s:=b[i]
        for k in 0..<i {s-=A[i*n+k]*b[k]}
        b[i]=s/A[i*n+i]
    }
    for i:=n-1;i>=0;i-=1 {
        s:=b[i]
        for k in i+1..<n {s-=A[k*n+i]*b[k]}
        b[i]=s/A[i*n+i]
    }
    return true
}
