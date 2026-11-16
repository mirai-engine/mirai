package rig

import "core:math/linalg"
import "core:strings"
import mm "mirai:std/math"

// The weights of the vertices to the fitted joints, after the skinning
// solvers of Mesh2Motion (MIT, github.com/Mesh2Motion/mesh2motion-app,
// src/lib/solvers): each vertex goes whole to the bone whose middle is
// nearest, extremities give back what lies behind their first joint, arms
// that hang give the chest back, and the boundaries between bones are
// blended by the adjacency of the mesh, wider on the torso and only toward
// the child on a limb. Unlike that solver, the pelvis of a humanoid takes no
// vertex below the crotch, where they belong to the legs.

@(private)
Category :: enum u8 {Other,Torso,Limb,Extremity,Root}

@(private)
EXTREMITY_WORDS :: [?]string{"hand","foot","feet","toe","ball","thumb","index","middle","ring","pinky","finger","teeth","eye","tongue","wing","feather","leaf","ear","horn"}
@(private)
LIMB_WORDS :: [?]string{"arm","upperarm","lowerarm","forearm","elbow","wrist","nose","shoulder","clavicle","ankle","fin","head","chin","jaw","mouth","thigh","calf","shin","knee","leg","upleg","lowleg","neck","humerus"}
@(private)
TORSO_WORDS :: [?]string{"spine","chest","hips","pelvis","torso","abdomen","body","tail","stomach","collar","scapula","ribcage"}

@(private)
category_of :: proc(name:string,parent:i32) -> Category {
    name:=strings.to_lower(name,context.temp_allocator)
    words:=EXTREMITY_WORDS
    for w in words {if strings.contains(name,w) {return .Extremity}}
    limbs:=LIMB_WORDS
    for w in limbs {if strings.contains(name,w) {return .Limb}}
    torso:=TORSO_WORDS
    for w in torso {if strings.contains(name,w) {return .Torso}}
    return .Root if parent<0 else .Other
}

// Two influences of a vertex: the bone it belongs to and the one it blends with.
@(private)
Influence :: struct {bone:[2]i32,weight:[2]f32}

// Arms that hang more than this below the horizontal give the chest back.
ARM_PLANE_ANGLE :: 0.35

// The skeleton the vertices are weighted to: its bones by row, parents
// before children, and where each joint is in the mesh.
Bones :: struct {
    names:[]string,
    parents:[]i32,
    joints:[]mm.Vec3,
}

// What only a humanoid's weights know of its body.
Humanoid_Body :: struct {
    crotch,center:f32, // the height of the crotch and the x of the centre line
    arms_down:f32,     // radians the arms hang below the horizontal
    pelvis:int,        // the row of the pelvis
}

@(private)
Weights :: struct {
    bones:Bones,
    positions:[]mm.Vec3,  // of every mesh one after another
    offsets:[]int,        // of each mesh in positions
    adjacency_first:[]int,// rows of adjacency by vertex, CSR
    adjacency:[]int,
    shared:[]int,         // the next vertex at the same position, a ring
    influences:[]Influence,
    categories:[]Category,
    parents:[]i32,
    first_child:[]i32,
}

// Weights the vertices of meshes to bones, by bone row.
weigh :: proc(meshes:[]Mesh,bones:Bones,body:Maybe(Humanoid_Body)=nil,allocator:=context.allocator) -> [][]Influence {
    w:Weights
    w.bones=bones
    nb:=len(bones.names)
    count:=0
    w.offsets=make([]int,len(meshes)+1,context.temp_allocator)
    for mesh,i in meshes {count+=len(mesh.positions);w.offsets[i+1]=count}
    w.positions=make([]mm.Vec3,count,context.temp_allocator)
    for mesh,i in meshes {copy(w.positions[w.offsets[i]:],mesh.positions)}
    w.parents=bones.parents
    w.first_child=make([]i32,nb,context.temp_allocator)
    w.categories=make([]Category,nb,context.temp_allocator)
    for &c in w.first_child {c=-1}
    for parent,i in bones.parents {
        if parent>=0 && w.first_child[parent]<0 {w.first_child[parent]=i32(i)}
    }
    for name,i in bones.names {w.categories[i]=category_of(name,bones.parents[i])}
    weights_adjacency(&w,meshes)
    weights_shared(&w)
    w.influences=make([]Influence,count,context.temp_allocator)
    human,is_human:=body.?
    weights_nearest(&w,human.pelvis if is_human else -1,human.crotch)
    weights_extremities(&w)
    if is_human && human.arms_down>ARM_PLANE_ANGLE {weights_arm_plane(&w,human.center)}
    weights_smooth(&w)
    out:=make([][]Influence,len(meshes),allocator)
    for _,i in meshes {
        out[i]=make([]Influence,w.offsets[i+1]-w.offsets[i],allocator)
        for &influence,k in out[i] {
            influence=w.influences[w.offsets[i]+k]
            total:=influence.weight[0]+influence.weight[1]
            if total>0 {influence.weight/=total}
        }
    }
    return out
}

@(private)
skipped :: proc(w:^Weights,bone:int) -> bool {
    name:=strings.to_lower(w.bones.names[bone],context.temp_allocator)
    return w.categories[bone]==.Root || w.first_child[bone]<0 && (strings.contains(name,"leaf") || strings.contains(name,"tip"))
}

@(private)
middle_of :: proc(w:^Weights,bone:int) -> mm.Vec3 {
    child:=w.first_child[bone]
    joints:=w.bones.joints
    return joints[bone] if child<0 else (joints[bone]+joints[child])/2
}

@(private)
weights_adjacency :: proc(w:^Weights,meshes:[]Mesh) {
    degree:=make([]int,len(w.positions)+1,context.temp_allocator)
    for mesh,m in meshes {
        for i:=0;i+2<len(mesh.indices);i+=3 {
            for k in 0..<3 {degree[w.offsets[m]+int(mesh.indices[i+k])]+=2}
        }
    }
    w.adjacency_first=make([]int,len(w.positions)+1,context.temp_allocator)
    for d,i in degree[:len(w.positions)] {w.adjacency_first[i+1]=w.adjacency_first[i]+d}
    w.adjacency=make([]int,w.adjacency_first[len(w.positions)],context.temp_allocator)
    fill:=make([]int,len(w.positions),context.temp_allocator)
    for mesh,m in meshes {
        for i:=0;i+2<len(mesh.indices);i+=3 {
            for k in 0..<3 {
                v:=w.offsets[m]+int(mesh.indices[i+k])
                for j in 1..<3 {
                    w.adjacency[w.adjacency_first[v]+fill[v]]=w.offsets[m]+int(mesh.indices[i+(k+j)%3])
                    fill[v]+=1
                }
            }
        }
    }
}

// Vertices split at a seam of the uvs or the normals are one point of the
// surface: they get the same weights, as Mesh2Motion keys them by position.
@(private)
weights_shared :: proc(w:^Weights) {
    w.shared=make([]int,len(w.positions),context.temp_allocator)
    first:=make(map[[3]i64]int,len(w.positions),context.temp_allocator)
    for p,i in w.positions {
        key:=[3]i64{i64(p.x*1e6),i64(p.y*1e6),i64(p.z*1e6)}
        if at,found:=first[key];found {
            w.shared[i]=w.shared[at]
            w.shared[at]=i
        } else {
            first[key]=i
            w.shared[i]=i
        }
    }
}

@(private)
// pelvis, when not negative, takes nothing below crotch.
weights_nearest :: proc(w:^Weights,pelvis:int,crotch:f32) {
    nb:=len(w.bones.names)
    middles:=make([]mm.Vec3,nb,context.temp_allocator)
    usable:=make([]bool,nb,context.temp_allocator)
    for b in 0..<nb {middles[b],usable[b]=middle_of(w,b),!skipped(w,b)}
    for p,i in w.positions {
        best:=max(f32)
        nearest:=0
        for b in 0..<nb {
            if !usable[b] || b==pelvis && p.y<crotch {continue}
            d:=linalg.length2(middles[b]-p)
            if d<best {best,nearest=d,b}
        }
        w.influences[i]={bone={i32(nearest),0},weight={1,0}}
    }
}

@(private)
weights_extremities :: proc(w:^Weights) {
    joints:=w.bones.joints
    for p,i in w.positions {
        bone:=int(w.influences[i].bone[0])
        parent:=w.parents[bone]
        if w.categories[bone]!=.Extremity || parent<0 || skipped(w,int(parent)) {continue}
        child:=w.first_child[bone]
        direction:=joints[child]-joints[bone] if child>=0 else joints[bone]-joints[parent]
        if linalg.dot(p-joints[bone],direction)<0 {w.influences[i].bone[0]=parent}
    }
}

@(private)
weights_arm_plane :: proc(w:^Weights,center:f32) {
    nb:=len(w.bones.names)
    arm:=make([]bool,nb,context.temp_allocator)
    plane:f32
    for name,i in w.bones.names {
        parent:=w.parents[i]
        arm[i]=strings.contains(name,"upperarm") || parent>=0 && arm[parent]
        if strings.contains(name,"upperarm") {plane=max(plane,abs(w.bones.joints[i].x-center))}
    }
    if plane<=0 {return}
    middles:=make([]mm.Vec3,nb,context.temp_allocator)
    for b in 0..<nb {middles[b]=middle_of(w,b)}
    for p,i in w.positions {
        if abs(p.x-center)>=plane || !arm[w.influences[i].bone[0]] {continue}
        best:=max(f32)
        for b in 0..<nb {
            if arm[b] || skipped(w,b) {continue}
            if d:=linalg.length2(middles[b]-p);d<best {best=d;w.influences[i].bone[0]=i32(b)}
        }
    }
}

@(private)
Smoothing :: enum u8 {Standard,Torso,Limb,Extremity}

@(private)
Boundary :: struct {a,b:int,bone_a,bone_b:i32,kind:Smoothing}

@(private)
weights_smooth :: proc(w:^Weights) {
    rigid :: proc(w:^Weights,v:int) -> bool {return w.influences[v].weight[0]==1}
    pairs:=make([dynamic]Boundary,context.temp_allocator)
    seen:=make(map[[2]int]bool,context.temp_allocator)
    for i in 0..<len(w.positions) {
        if !rigid(w,i) {continue}
        a:=w.influences[i].bone[0]
        for j in w.adjacency[w.adjacency_first[i]:w.adjacency_first[i+1]] {
            b:=w.influences[j].bone[0]
            if a==b || !rigid(w,j) {continue}
            key:=[2]int{min(i,j),max(i,j)}
            if key in seen {continue}
            seen[key]=true
            ca,cb:=w.categories[a],w.categories[b]
            kind:Smoothing
            switch {
            case (ca==.Torso || cb==.Torso) && ca!=.Extremity && cb!=.Extremity: kind=.Torso
            case ca==.Limb || cb==.Limb: kind=.Limb
            case ca==.Extremity && cb==.Extremity: kind=.Extremity
            }
            append(&pairs,Boundary{i,j,a,b,kind})
        }
    }
    set :: proc(w:^Weights,v:int,primary,secondary:i32,amount:f32) {
        at:=v
        for {
            w.influences[at]={bone={primary,secondary},weight={1-amount,amount}}
            at=w.shared[at]
            if at==v {break}
        }
    }
    // Torso: 50/50 on the boundary, then 75/25 and 90/10 one and two rings out.
    RINGS :: [3]f32{0.5,0.25,0.10}
    rings:=RINGS
    processed:=make(map[int]bool,context.temp_allocator)
    current:=make([dynamic]int,context.temp_allocator)
    for pair in pairs {
        if pair.kind!=.Torso {continue}
        set(w,pair.a,pair.bone_a,pair.bone_b,rings[0])
        set(w,pair.b,pair.bone_b,pair.bone_a,rings[0])
        for v in ([2]int{pair.a,pair.b}) {
            if v in processed {continue}
            processed[v]=true
            append(&current,v)
        }
    }
    for ring in 1..<len(rings) {
        next:=make([dynamic]int,context.temp_allocator)
        for v in current {
            primary:=w.influences[v].bone[0]
            other:=w.influences[v].bone[1]
            if other==primary || other==0 {continue}
            for n in w.adjacency[w.adjacency_first[v]:w.adjacency_first[v+1]] {
                if n in processed || w.influences[n].bone[0]!=primary || !rigid(w,n) {continue}
                set(w,n,primary,other,rings[ring])
                processed[n]=true
                append(&next,n)
            }
        }
        current=next
    }
    // Limb: only the child's side blends, so a bent elbow leaves the biceps.
    for pair in pairs {
        if pair.kind!=.Limb {continue}
        switch {
        case w.parents[pair.bone_b]==pair.bone_a: set(w,pair.b,pair.bone_b,pair.bone_a,0.5)
        case w.parents[pair.bone_a]==pair.bone_b: set(w,pair.a,pair.bone_a,pair.bone_b,0.5)
        case:
            set(w,pair.a,pair.bone_a,pair.bone_b,0.5)
            set(w,pair.b,pair.bone_b,pair.bone_a,0.5)
        }
    }
    for pair in pairs {
        if pair.kind!=.Standard {continue}
        set(w,pair.a,pair.bone_a,pair.bone_b,0.5)
        set(w,pair.b,pair.bone_b,pair.bone_a,0.5)
    }
    // Extremity boundaries stay rigid: a blend smears a finger.
}

// The row of a bone of HUMANOID by its name; -1 when it has none.
bone_index :: proc(name:string) -> int {
    for bone,i in HUMANOID {if bone.name==name {return i}}
    return -1
}
