package rig

import "core:math"
import "core:math/linalg"
import "core:slice"
import mm "mirai:std/math"

// Where the joints of the template are in a mesh that stands up along +Y and
// faces -Z, the space of the engine. The mesh is read by its horizontal
// sections: the floor and the top bound it, the crotch is the lowest height
// above the shins where a section crosses the centre line, and the neck is
// the narrowest section between the chest and the top. Each joint then has
// its rule (template.odin), and the two sides are made mirror images.

// A part of the character as the fit reads it, in the space of the model.
Mesh :: struct {
    positions:[][3]f32,
    indices:[]u32, // triangles
}

Landmark :: enum u8 {Crotch,Neck,Arm_L,Arm_R}

// What a person says of the mesh, in meters in the space of the model; 0: the fit finds it.
Hints :: struct {crotch,neck:f32}

Fit :: struct {
    joints:[]mm.Vec3, // by bone of HUMANOID: where it is in the mesh
    floor,crotch,neck,top:f32,
    center:f32,       // x of the centre line
    confidence:[Landmark]f32, // 1 when the mesh shows it, lower when the fit assumed it
    arms_down:f32,    // radians the arms hang below the horizontal
}

@(private)
Interval :: struct {x0,x1,z0,z1:f32}

@(private)
Arm :: struct {
    found:bool,
    center,axis:mm.Vec3,
    start,end:f32, // along the axis: the centre line and the farthest point
    points:[]mm.Vec3,
    along:[]f32,
}

@(private)
Reader :: struct {
    meshes:[]Mesh,
    floor,top,height,center,torso:f32,
    // Rows of triangles by their lowest corner, for the sections.
    triangles:[][3]mm.Vec3,
    lowest,highest:[]f32,
}

// Below, a section at the crotch splits in two legs; a crotch found lower
// than this is the hem of a skirt or a coat.
CROTCH_LOWEST :: 0.40
// Where the crotch is assumed when the mesh hides it, in heights.
CROTCH_ASSUMED :: 0.465
SLICES :: 128

@(private)
reader_init :: proc(r:^Reader,meshes:[]Mesh) -> bool {
    r.meshes=meshes
    lo:=mm.Vec3{max(f32),max(f32),max(f32)}
    hi:=-lo
    count:=0
    for mesh in meshes {
        for p in mesh.positions {lo=linalg.min(lo,p);hi=linalg.max(hi,p)}
        count+=len(mesh.indices)/3
    }
    if count==0 || !(hi.y>lo.y) {return false}
    r.floor,r.top,r.height,r.center=lo.y,hi.y,hi.y-lo.y,(lo.x+hi.x)/2
    r.triangles=make([][3]mm.Vec3,count,context.temp_allocator)
    r.lowest=make([]f32,count,context.temp_allocator)
    r.highest=make([]f32,count,context.temp_allocator)
    at:=0
    for mesh in meshes {
        for i:=0;i+2<len(mesh.indices);i+=3 {
            corners:[3]mm.Vec3
            for k in 0..<3 {corners[k]=mesh.positions[mesh.indices[i+k]]}
            r.triangles[at]=corners
            r.lowest[at]=min(corners[0].y,corners[1].y,corners[2].y)
            r.highest[at]=max(corners[0].y,corners[1].y,corners[2].y)
            at+=1
        }
    }
    return true
}

// The section of the mesh at height y: the intervals in x where it is solid,
// each with its extent in z, from the model's left to its right (-x first).
@(private)
section :: proc(r:^Reader,y:f32) -> []Interval {
    segments:=make([dynamic]Interval,context.temp_allocator)
    for corners,i in r.triangles {
        if r.lowest[i]>=y || r.highest[i]<=y {continue}
        points:[2][2]f32
        n:=0
        for k in 0..<3 {
            a,b:=corners[k],corners[(k+1)%3]
            if (a.y-y)*(b.y-y)>=0 || n==2 {continue}
            t:=(y-a.y)/(b.y-a.y)
            points[n]={a.x+t*(b.x-a.x),a.z+t*(b.z-a.z)}
            n+=1
        }
        if n<2 {continue}
        append(&segments,Interval{min(points[0].x,points[1].x),max(points[0].x,points[1].x),min(points[0].y,points[1].y),max(points[0].y,points[1].y)})
    }
    slice.sort_by(segments[:],proc(a,b:Interval) -> bool {return a.x0<b.x0})
    merged:=make([dynamic]Interval,context.temp_allocator)
    gap:=1e-4*r.height
    for s in segments {
        if len(merged)>0 && s.x0<=merged[len(merged)-1].x1+gap {
            last:=&merged[len(merged)-1]
            last.x1,last.z0,last.z1=max(last.x1,s.x1),min(last.z0,s.z0),max(last.z1,s.z1)
            continue
        }
        append(&merged,s)
    }
    return merged[:]
}

// The interval of a section that along names: the one on the centre line,
// or on a side the one nearest the centre (a leg, not a hand that hangs by it).
@(private)
section_interval :: proc(r:^Reader,y:f32,along:Along) -> (found:Interval,ok:bool) {
    intervals:=section(r,y)
    best:=max(f32)
    for v in intervals {
        middle:=(v.x0+v.x1)/2
        distance:=abs(middle-r.center)
        switch along {
        case .Center:
            if v.x0<=r.center && r.center<=v.x1 {return v,true}
        case .Left:
            if middle>=r.center {continue}
        case .Right:
            if middle<=r.center {continue}
        }
        if distance<best {best,found,ok=distance,v,true}
    }
    return
}

@(private)
slice_height :: #force_inline proc(r:^Reader,k:int) -> f32 {return r.floor+r.height*(f32(k)+0.5)/SLICES}

@(private)
anchors_find :: proc(r:^Reader,f:^Fit,hints:Hints) {
    f.floor,f.top,f.center=r.floor,r.top,r.center
    f.crotch=-1
    for k in 0..<SLICES {
        y:=slice_height(r,k)
        if y<r.floor+0.2*r.height {continue}
        if v,ok:=section_interval(r,y,.Center);ok && v.x0<=r.center && r.center<=v.x1 {f.crotch=y;break}
    }
    f.confidence[.Crotch]=1
    if f.crotch<r.floor+CROTCH_LOWEST*r.height {f.crotch,f.confidence[.Crotch]=r.floor+CROTCH_ASSUMED*r.height,0.3}
    if hints.crotch>0 {f.crotch,f.confidence[.Crotch]=hints.crotch,1}
    narrowest:=max(f32)
    f.neck=-1
    for k in 0..<SLICES {
        y:=slice_height(r,k)
        if y<f.crotch+0.5*(r.top-f.crotch) || y>r.top-0.04*r.height {continue}
        if v,ok:=section_interval(r,y,.Center);ok && v.x1-v.x0<narrowest {narrowest,f.neck=v.x1-v.x0,y}
    }
    f.confidence[.Neck]=1
    if hints.neck>0 {f.neck=hints.neck}
    if f.neck<0 {
        reference:=REFERENCE_ANCHORS
        f.neck=f.crotch+(reference[2]-reference[1])/(reference[3]-reference[1])*(r.top-f.crotch)
        f.confidence[.Neck]=0.3
    }
    widths:=make([dynamic]f32,context.temp_allocator)
    for k in 0..<SLICES {
        y:=slice_height(r,k)
        if y<=f.crotch || y>=f.crotch+0.35*(r.top-f.crotch) {continue}
        if v,ok:=section_interval(r,y,.Center);ok {append(&widths,v.x1-v.x0)}
    }
    slice.sort(widths[:])
    r.torso=widths[len(widths)/2] if len(widths)>0 else 0.15*r.height
}

// The points of an arm and their main axis, by power iteration from the side:
// those out of the torso above the waist, and below it, down to the knees,
// those far out, as a hand that hangs in an A-pose.
@(private)
arm_find :: proc(r:^Reader,f:^Fit,side:f32) -> (arm:Arm) {
    limit:=r.torso/2*1.15
    waist:=f.crotch+0.25*(f.neck-f.crotch)
    points:=make([dynamic]mm.Vec3,context.temp_allocator)
    for mesh in r.meshes {
        for p in mesh.positions {
            out:=side*(p.x-r.center)
            if out>limit && p.y>waist || out>2*limit && p.y>r.floor+0.3*r.height {append(&points,p)}
        }
    }
    if len(points)<8 {return}
    for p in points {arm.center+=p}
    arm.center/=f32(len(points))
    axis:=mm.Vec3{side,0,0}
    for _ in 0..<30 {
        sum:mm.Vec3
        for p in points {q:=p-arm.center;sum+=q*linalg.dot(q,axis)}
        if linalg.length(sum)<1e-12 {break}
        axis=linalg.normalize(sum)
    }
    if axis.x*side<0 {axis=-axis}
    // An arm that hangs straight down has no horizontal axis to measure along.
    if abs(axis.x)<0.2 {return}
    arm.axis,arm.points=axis,points[:]
    arm.along=make([]f32,len(points),context.temp_allocator)
    arm.end=-max(f32)
    for p,i in points {arm.along[i]=linalg.dot(p-arm.center,axis);arm.end=max(arm.end,arm.along[i])}
    arm.start=(r.center-arm.center.x)/axis.x
    arm.found=arm.end>arm.start
    return
}

// The centre of the arm at t along its axis: the mean of the points near it,
// kept at t.
@(private)
arm_point :: proc(r:^Reader,arm:Arm,t:f32) -> mm.Vec3 {
    sum:mm.Vec3
    n:=0
    for along,i in arm.along {
        if abs(along-t)<0.025*r.height {sum+=arm.points[i];n+=1}
    }
    if n==0 {return arm.center+arm.axis*t}
    c:=sum/f32(n)
    return c+arm.axis*(t-linalg.dot(c-arm.center,arm.axis))
}

// The height in the mesh of a height in anchor units.
@(private)
anchor_height :: proc(f:Fit,units:f32) -> f32 {
    anchors:=[4]f32{f.floor,f.crotch,f.neck,f.top}
    i:=clamp(int(units),0,2)
    return anchors[i]+(units-f32(i))*(anchors[i+1]-anchors[i])
}

// The fit of the template to meshes; false when they have no triangles or no height.
fit :: proc(meshes:[]Mesh,hints:Hints={},allocator:=context.allocator) -> (f:Fit,ok:bool) {
    r:Reader
    reader_init(&r,meshes) or_return
    anchors_find(&r,&f,hints)
    reference:=REFERENCE_ANCHORS
    scale:=r.height/(reference[3]-reference[0])
    arms:=[2]Arm{arm_find(&r,&f,-1),arm_find(&r,&f,1)}
    for side,i in ([2]Landmark{.Arm_L,.Arm_R}) {f.confidence[side]=1 if arms[i].found else 0}
    if arms[0].found && arms[1].found {
        left,right:=arms[0].end-arms[0].start,arms[1].end-arms[1].start
        if abs(left-right)>0.15*max(left,right) {f.confidence[.Arm_L],f.confidence[.Arm_R]=0.5,0.5}
        f.arms_down=(math.asin(clamp(-arms[0].axis.y,-1,1))+math.asin(clamp(-arms[1].axis.y,-1,1)))/2
    }
    f.joints=make([]mm.Vec3,len(HUMANOID),allocator)
    placed:=make([]bool,len(HUMANOID),context.temp_allocator)
    // By the reference, scaled to the mesh: what a rule falls back to.
    assumed :: proc(r:^Reader,bone:Template_Bone,scale:f32) -> mm.Vec3 {
        reference:=REFERENCE_ANCHORS
        return {r.center+bone.reference.x*scale,r.floor+(bone.reference.y-reference[0])*scale,bone.reference.z*scale}
    }
    for bone,i in HUMANOID {
        rule:=bone.rule
        switch rule.kind {
        case .Section:
            y:=anchor_height(f,rule.height)
            at:=r.floor+rule.fixed*r.height if rule.fixed>=0 else y
            // A leg is read just below the crotch, where the two legs part.
            if rule.along!=.Center {at=min(at,f.crotch-0.02*r.height)}
            v,found:=section_interval(&r,at,rule.along)
            if !found {f.joints[i]=assumed(&r,bone,scale);break}
            f.joints[i]={v.x0+rule.u*(v.x1-v.x0),y,v.z0+rule.w*(v.z1-v.z0)}
            if rule.along==.Center {f.joints[i].x=r.center}
        case .Arm:
            arm:=arms[0] if rule.along==.Left else arms[1]
            if !arm.found {f.joints[i]=assumed(&r,bone,scale);break}
            c:=arm_point(&r,arm,arm.start+rule.height*(arm.end-arm.start))
            f.joints[i]=c+rule.offset*r.height
        case .Follow:
            continue
        }
        placed[i]=true
    }
    // Follow rules name bones before or after them: anchors come first.
    for _ in 0..<2 {
        for bone,i in HUMANOID {
            rule:=bone.rule
            if placed[i] || rule.kind!=.Follow || !placed[rule.anchor] || rule.toward>=0 && !placed[rule.toward] {continue}
            anchor:=HUMANOID[rule.anchor]
            offset:=bone.reference-anchor.reference
            if rule.toward<0 {
                f.joints[i]=f.joints[rule.anchor]+offset*scale
            } else {
                was:=anchor.reference-HUMANOID[rule.toward].reference
                now:=f.joints[rule.anchor]-f.joints[rule.toward]
                turn:=mm.quat_between(linalg.normalize(was),linalg.normalize(now))
                f.joints[i]=f.joints[rule.anchor]+mm.quat_rotate(turn,offset)*(linalg.length(now)/linalg.length(was))
            }
            placed[i]=true
        }
    }
    for i in 0..<len(HUMANOID) {
        partner:=mirror_of(i)
        if partner<=i {continue}
        a,b:=f.joints[i],f.joints[partner]
        x:=((a.x-r.center)-(b.x-r.center))/2
        y,z:=(a.y+b.y)/2,(a.z+b.z)/2
        f.joints[i],f.joints[partner]={r.center+x,y,z},{r.center-x,y,z}
    }
    return f,true
}

// The bone of the other side: hand_l for hand_r; -1 for a bone of the centre.
mirror_of :: proc(bone:int) -> int {
    name:=HUMANOID[bone].name
    if len(name)<2 || name[len(name)-2]!='_' || (name[len(name)-1]!='l' && name[len(name)-1]!='r') {return -1}
    other:u8='r' if name[len(name)-1]=='l' else 'l'
    for candidate,i in HUMANOID {
        n:=candidate.name
        if i!=bone && len(n)==len(name) && n[:len(n)-1]==name[:len(name)-1] && n[len(n)-1]==other {return i}
    }
    return -1
}
