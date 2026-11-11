package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Foot :: enum u8 {Left,Right}

// A foot on the ground from a frame to another, both included. anchors are
// where its ankle and its toe stand over the ground, each from the frames it
// is down: its position minus what the ground moved since time 0 (see
// Clip_Metrics.travel). A foot without toe has the ankle twice.
Contact :: struct {foot:Foot,first,last:i32,anchors:[2]math.Vec3}
Metric_Stat :: struct {mean,max:f32}
// Frames past a limit and how far past the worst one went, in radians.
Limit_Stat :: struct {frames:i32,worst:f32}

Goal_Kind :: enum u8 {Reach,Look}
// What an IK or a look asks of a bone, in the space of the clip: to be at
// the target (Reach) or to point its local axis at it (Look).
Metric_Goal :: struct {kind:Goal_Kind,bone:i32,axis:math.Vec3,target:math.Vec3}
// A limit on the local rotation of a bone, as rotation_limit takes it.
Metric_Limit :: struct {bone:i32,reference:math.Quat,limit:Rotation_Limit}

// What a metric pass also measures or lists, each output as long as its input.
Metric_Request :: struct {
    goals:[]Metric_Goal,
    residuals:[]Metric_Stat, // m for Reach, rad for Look
    limits:[]Metric_Limit,
    violations:[]Limit_Stat,
    contacts:[]Contact, // as many as fit; Clip_Metrics.contacts counts them all
}

// How a clip moves. travel is the velocity of the body over the ground:
// that of its root bone, or for a clip in place the one its feet push at
// (when no foot stands, the one the foot that touches the floor pushes at), which the
// game has to move the body by. Slide is the speed of a foot over
// the ground while it stands, penetration how far a foot or toe goes below
// its height at rest, and jerk the change of acceleration of the parts. The
// seam compares the last frame with the first relative to the root; its
// velocity is how much more the speed changes across it than a frame inside.
// limits holds knees bent backwards, elbows folded past 165° and the head
// turned more than 80° from its rest on the spine.
Clip_Metrics :: struct {
    duration,height:f32,
    root:i32,
    travel:math.Vec3,
    in_place:bool,
    contacts:int,
    foot_slide:[Foot]Metric_Stat,
    penetration:Metric_Stat,
    jerk:Metric_Stat,
    seam_position,seam_rotation,seam_velocity:f32,
    limits:[Body_Part]Limit_Stat,
}

// Transforms of scratch that metrics and edits need: the world pose of every
// frame and that of the rest.
frames_scratch_size :: proc "contextless" (f:Frames) -> int {return (frames_count(f)+1)*max(f.bones,0)}

@(private)
Ground :: struct {
    up:math.Vec3,
    velocity:math.Vec3, // of the ground in the space of the clip
    travel:math.Vec3,
    in_place:bool,
    root:i32,
    height:f32,
}

@(private)
foot_parts :: #force_inline proc "contextless" (foot:Foot) -> [2]Body_Part {return {.Foot_L,.Toe_L} if foot==.Left else {.Foot_R,.Toe_R}}

// A foot stands while its ankle or toe is this close to its floor, rises
// this slowly and moves this slowly over the ground, in body heights and body
// heights per second: a skating foot still stands, a swinging one does not.
CONTACT_HEIGHT :: .03
CONTACT_RISE :: .15
CONTACT_SPEED :: .6
// Side of a cell of the vote for the speed of the ground under an in-place
// clip, in body heights per second.
GROUND_CELL :: .08

// World poses of the frames in world, the rest after them, and how the
// ground moves under the clip.
@(private)
frames_ground :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform) -> (ground:Ground,ok:bool) {
    count:=frames_count(f)
    if !frames_valid(f) || !body_rig_valid(rig) || f.bones!=len(rig.parents) || len(world)<(count+1)*f.bones {return}
    if !frames_world(rig,f,world) {return}
    rest:=world[count*f.bones:][:f.bones]
    if !pose_world(rig.parents,rig.rest,rest) {return}
    ground.up=frames_up(rig)
    ground.height=body_height(rig.body,rest)
    ground.root=frames_root(rig,f)
    duration:=frames_duration(f)
    root:=int(ground.root)
    moved:=frames_horizontal(world[(count-1)*f.bones+root].position-world[root].position,ground.up)
    ground.travel=moved/duration
    if linalg.length(ground.travel)>.03*ground.height {return ground,true}
    // In place: the ground moves under the feet that stand. A foot also
    // passes low while it swings, faster: the ground is the velocity most low
    // frames share, the densest cell of a vote over horizontal velocities.
    ground.in_place,ground.travel=true,{}
    parts:=[4]Body_Part{.Foot_L,.Toe_L,.Foot_R,.Toe_R}
    floors:[4]f32
    for part,k in parts {if bone:=rig.body.bones[part];bone>=0 {floors[k]=frames_floor(world,f.bones,count,int(bone),ground.up)}}
    sample :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,parts:[4]Body_Part,floors:[4]f32,index:int) -> (v:math.Vec3,ok:bool) {
        count:=frames_count(f)
        k,frame:=index/count,index%count
        bone:=rig.body.bones[parts[k]]
        if bone<0 || linalg.dot(world[frame*f.bones+int(bone)].position,ground.up)>floors[k]+CONTACT_HEIGHT*ground.height {return}
        return frames_horizontal(frames_velocity(world,f.bones,count,int(bone),frame,f.rate),ground.up),true
    }
    across:=linalg.normalize0(linalg.cross(ground.up,math.Vec3{0,0,1}))
    if linalg.length(across)<.5 {across=linalg.normalize0(linalg.cross(ground.up,math.Vec3{1,0,0}))}
    along:=linalg.cross(across,ground.up)
    fastest:f32
    for index in 0..<4*count {if v,ok:=sample(rig,f,world,ground,parts,floors,index);ok {fastest=max(fastest,linalg.length(v))}}
    GRID :: 64
    cell:=max(GROUND_CELL*ground.height,fastest/(GRID/2-1))
    votes:[GRID][GRID]u16
    for index in 0..<4*count {
        v:=sample(rig,f,world,ground,parts,floors,index) or_continue
        x,y:=int(cmath.floor(linalg.dot(v,along)/cell))+GRID/2,int(cmath.floor(linalg.dot(v,across)/cell))+GRID/2
        if x>=0 && x<GRID && y>=0 && y<GRID {votes[x][y]+=1}
    }
    best:=[2]int{-1,-1};most:=0
    for x in 0..<GRID-1 {for y in 0..<GRID-1 {
        n:=int(votes[x][y])+int(votes[x+1][y])+int(votes[x][y+1])+int(votes[x+1][y+1])
        if n>most {most,best=n,{x,y}}
    }}
    if most>0 {
        estimate:=along*(f32(best.x-GRID/2+1)*cell)+across*(f32(best.y-GRID/2+1)*cell)
        for _ in 0..<2 {
            sum:math.Vec3;samples:int
            for index in 0..<4*count {
                v:=sample(rig,f,world,ground,parts,floors,index) or_continue
                if linalg.length(v-estimate)<=cell {sum+=v;samples+=1}
            }
            if samples>0 {estimate=sum/f32(samples)}
        }
        ground.velocity,ground.travel=estimate,-estimate
    }
    // No foot stands on that ground (a run whose feet touch the floor a frame or two between
    // flights): the travel is how fast the foot that touches pushes back under the hips, or
    // without one, how far the feet sweep under them.
    if frames_contacts(rig,f,world,ground,nil)==0 {
        touched:bool
        ground.travel,touched=frames_touch(rig,f,world,ground.up,ground.height,parts,floors)
        if !touched {ground.travel=frames_sweep(rig,f,world,ground.up,along,across)}
        ground.velocity=-ground.travel
    }
    return ground,true
}

// The travel of an in-place clip from the feet that touch the floor: at each frame the joint of a
// foot nearest its floor, while it is down, pushes back relative to the pelvis as fast as the body
// travels. The speed is the median of those pushes along their mean direction, each weighted by
// how far down its joint is, so a flight phase or a foot that only grazes the floor does not slow
// it. False when no foot comes down.
@(private)
frames_touch :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,up:math.Vec3,height:f32,parts:[4]Body_Part,floors:[4]f32) -> (travel:math.Vec3,ok:bool) {
    count:=frames_count(f)
    pelvis:=rig.body.bones[.Pelvis]
    if pelvis<0 || count<3 {return}
    frames:=count-1 if f.loop else count
    push :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,up:math.Vec3,height:f32,parts:[4]Body_Part,floors:[4]f32,pelvis:i32,frame:int) -> (velocity:math.Vec3,weight:f32) {
        count:=frames_count(f)
        lowest:=-1
        for part,k in parts {
            bone:=rig.body.bones[part]
            if bone<0 {continue}
            down:=frames_down(linalg.dot(world[frame*f.bones+int(bone)].position,up)-floors[k],height)
            if down>weight {weight,lowest=down,int(bone)}
        }
        if lowest<0 {return}
        v:=frames_velocity(world,f.bones,count,lowest,frame,f.rate)-frames_velocity(world,f.bones,count,int(pelvis),frame,f.rate)
        return frames_horizontal(v,up),weight
    }
    sum:math.Vec3;total:f32
    for frame in 0..<frames {v,w:=push(rig,f,world,up,height,parts,floors,pelvis,frame);sum+=v*w;total+=w}
    direction,moving:=anim_unit(-sum)
    if total<=0 || !moving {return}
    low,high:=max(f32),-max(f32)
    for frame in 0..<frames {
        v,w:=push(rig,f,world,up,height,parts,floors,pelvis,frame)
        if w>0 {speed:=-linalg.dot(v,direction);low,high=min(low,speed),max(high,speed)}
    }
    // The weighted median, by bisection over the speeds.
    for _ in 0..<40 {
        middle:=.5*(low+high)
        below:f32
        for frame in 0..<frames {
            v,w:=push(rig,f,world,up,height,parts,floors,pelvis,frame)
            if w>0 && -linalg.dot(v,direction)<=middle {below+=w}
        }
        if below>=.5*total {high=middle} else {low=middle}
    }
    return direction*max(high,0),true
}

// The travel of an in-place clip from the sweep of its feet relative to the pelvis: each foot
// goes back and forth along the direction of travel, back while it is low. Standing half of
// each cycle, a foot moves back over the ground as far as the body travels forward meanwhile,
// so the body travels as far as the foot sweeps both ways.
@(private)
frames_sweep :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,up,along,across:math.Vec3) -> math.Vec3 {
    count:=frames_count(f)
    pelvis:=rig.body.bones[.Pelvis]
    feet:=[2]i32{rig.body.bones[.Foot_L],rig.body.bones[.Foot_R]}
    if pelvis<0 || count<3 {return {}}
    relative :: proc "contextless" (world:[]math.Transform,bones,frame:int,foot,pelvis:i32,along,across:math.Vec3) -> [2]f32 {
        d:=world[frame*bones+int(foot)].position-world[frame*bones+int(pelvis)].position
        return {linalg.dot(d,along),linalg.dot(d,across)}
    }
    // The axis the feet sweep along: the principal axis of their positions around their means.
    xx,xy,yy:f32
    for foot in feet {
        if foot<0 {continue}
        mean:[2]f32
        for frame in 0..<count {mean+=relative(world,f.bones,frame,foot,pelvis,along,across)}
        mean/=f32(count)
        for frame in 0..<count {
            d:=relative(world,f.bones,frame,foot,pelvis,along,across)-mean
            xx+=d.x*d.x;xy+=d.x*d.y;yy+=d.y*d.y
        }
    }
    angle:=.5*cmath.atan2(2*xy,xx-yy)
    axis:=along*cmath.cos(angle)+across*cmath.sin(angle)
    path,back:f32
    feet_counted:=0
    for foot in feet {
        if foot<0 {continue}
        top:=-max(f32)
        for frame in 0..<count {top=max(top,linalg.dot(world[frame*f.bones+int(foot)].position,up))}
        previous:=relative(world,f.bones,0,foot,pelvis,along,across)
        for frame in 1..<count {
            here:=relative(world,f.bones,frame,foot,pelvis,along,across)
            step:=linalg.dot(here-previous,[2]f32{cmath.cos(angle),cmath.sin(angle)})
            path+=abs(step)
            back+=step*(top-linalg.dot(world[frame*f.bones+int(foot)].position,up))
            previous=here
        }
        feet_counted+=1
    }
    if feet_counted==0 {return {}}
    if back==0 {back=-linalg.dot(axis,math.FORWARD)}
    speed:=path/f32(feet_counted)/frames_duration(f)
    return -axis*speed if back>0 else axis*speed
}

// The floor under a foot joint in this clip, independent of its rest pose.
@(private)
frames_floor :: proc "contextless" (world:[]math.Transform,bones,count,bone:int,up:math.Vec3) -> f32 {
    floor:=max(f32)
    for frame in 0..<count {floor=min(floor,linalg.dot(world[frame*bones+bone].position,up))}
    return floor
}

// How much a joint this high over its floor is down: 1 on it, 0 from the
// height a standing foot reaches.
@(private)
frames_down :: #force_inline proc "contextless" (above,height:f32) -> f32 {return 1-math.smoothstep(0,CONTACT_HEIGHT*height,above)}

// Whether a foot stands at a frame: its ankle or its toe low over its floor
// and still over the ground.
@(private)
frames_standing :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,floors:[2]f32,foot:Foot,frame:int) -> (standing:bool,speed:f32) {
    count:=frames_count(f)
    speed=max(f32)
    for part,k in foot_parts(foot) {
        bone:=rig.body.bones[part]
        if bone<0 {continue}
        p:=world[frame*f.bones+int(bone)].position
        if linalg.dot(p,ground.up)>floors[k]+CONTACT_HEIGHT*ground.height {continue}
        v:=frames_velocity(world,f.bones,count,int(bone),frame,f.rate)-ground.velocity
        if abs(linalg.dot(v,ground.up))>CONTACT_RISE*ground.height {continue}
        horizontal:=linalg.length(frames_horizontal(v,ground.up))
        if horizontal>CONTACT_SPEED*ground.height {continue}
        standing=true;speed=min(speed,horizontal)
    }
    if !standing {speed=0}
    return
}

// The contacts of the feet, in time order per foot: runs of standing frames
// with gaps of up to two frames filled and runs shorter than three frames
// dropped. In a loop the runs that touch both ends share their anchor across
// the seam. Writes as many as fit and returns how many there are.
@(private)
frames_contacts :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,out:[]Contact) -> int {
    count:=frames_count(f)
    total:=0
    for foot in Foot {
        joints,floors,found:=contact_joints(rig,f,world,ground,foot)
        if !found {continue}
        first_of_foot:=total
        stands :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,floors:[2]f32,foot:Foot,frame:int) -> bool {
            standing,_:=frames_standing(rig,f,world,ground,floors,foot,frame)
            return standing
        }
        frame:=0
        for frame<count {
            if !stands(rig,f,world,ground,floors,foot,frame) {frame+=1;continue}
            start,last:=frame,frame
            next:=frame+1
            for next<count {
                if stands(rig,f,world,ground,floors,foot,next) {last=next;next+=1;continue}
                resume:=-1
                for gap in next+1..=min(next+2,count-1) {if stands(rig,f,world,ground,floors,foot,gap) {resume=gap;break}}
                if resume<0 {break}
                last,next=resume,resume+1
            }
            frame=last+1
            if last-start+1<3 && !(start==0 || last==count-1) {continue}
            if total<len(out) {out[total]={foot,i32(start),i32(last),contact_anchors(f,world,ground,joints,floors,start,last)}}
            total+=1
        }
        if total<=len(out) {contact_seam(f,ground,out[first_of_foot:total],foot)}
    }
    return total
}

// The anchors of contacts whose feet and frames come from elsewhere (the clip a retarget was made
// from), where the feet of this clip stand over those frames. False for a contact outside the
// frames or of a foot the body lacks.
@(private)
frames_contacts_place :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,contacts:[]Contact) -> bool {
    count:=frames_count(f)
    for &contact in contacts {
        if contact.foot>max(Foot) || contact.first<0 || contact.first>contact.last || int(contact.last)>=count {return false}
        joints,floors,found:=contact_joints(rig,f,world,ground,contact.foot)
        if !found {return false}
        contact.anchors=contact_anchors(f,world,ground,joints,floors,int(contact.first),int(contact.last))
    }
    for foot in Foot {contact_seam(f,ground,contacts,foot)}
    return true
}

// The ankle and toe joints of a foot, a foot without toe has the ankle twice, and the floor of each.
@(private="file")
contact_joints :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform,ground:Ground,foot:Foot) -> (joints:[2]int,floors:[2]f32,found:bool) {
    count:=frames_count(f)
    joints={-1,-1}
    for part,k in foot_parts(foot) {
        bone:=rig.body.bones[part]
        if bone<0 {continue}
        floors[k]=frames_floor(world,f.bones,count,int(bone),ground.up)
        joints[k]=int(bone)
    }
    if joints[0]<0 {joints[0],floors[0]=joints[1],floors[1]}
    if joints[1]<0 {joints[1],floors[1]=joints[0],floors[0]}
    return joints,floors,joints[0]>=0
}

// Where the joints of a foot stand over the ground from a frame to another, each frame weighted by
// how far down the joint is.
@(private="file")
contact_anchors :: proc "contextless" (f:Frames,world:[]math.Transform,ground:Ground,joints:[2]int,floors:[2]f32,start,last:int) -> (anchors:[2]math.Vec3) {
    for joint,k in joints {
        sum:math.Vec3;weight:f32
        for i in start..=last {
            p:=world[i*f.bones+joint].position
            w:=frames_down(linalg.dot(p,ground.up)-floors[k],ground.height)+1e-3
            sum+=(p-ground.velocity*(f32(i)/f.rate))*w;weight+=w
        }
        anchors[k]=sum/weight
    }
    return
}

// Across the seam of a loop the ground has moved by a pass of travel: the contacts of a foot that
// touch both ends share their anchor.
@(private="file")
contact_seam :: proc "contextless" (f:Frames,ground:Ground,contacts:[]Contact,foot:Foot) {
    count:=frames_count(f)
    if !f.loop {return}
    a,b:^Contact
    for &contact in contacts {
        if contact.foot!=foot {continue}
        if contact.first==0 {a=&contact}
        if int(contact.last)==count-1 {b=&contact}
    }
    if a==nil || b==nil || a==b {return}
    pass:=ground.travel*frames_duration(f)
    na,nb:=f32(a.last-a.first+1),f32(b.last-b.first+1)
    for k in 0..<2 {
        shared:=(a.anchors[k]*na+(b.anchors[k]-pass)*nb)/(na+nb)
        a.anchors[k],b.anchors[k]=shared,shared+pass
    }
}

// Measures a clip: see Clip_Metrics and Metric_Request. scratch holds
// frames_scratch_size transforms. False for frames or a rig that are not
// valid, outputs shorter than their inputs, or goals and limits on bones
// outside the rig.
clip_metrics :: proc "contextless" (rig:Body_Rig,f:Frames,request:Metric_Request,scratch:[]math.Transform) -> (metrics:Clip_Metrics,ok:bool) {
    if len(request.residuals)<len(request.goals) || len(request.violations)<len(request.limits) {return}
    for goal in request.goals {if goal.bone<0 || int(goal.bone)>=len(rig.parents) || !anim_vec3_valid(goal.target) || !anim_vec3_valid(goal.axis) || goal.kind>max(Goal_Kind) {return}}
    for limit in request.limits {if limit.bone<0 || int(limit.bone)>=len(rig.parents) || !anim_rotation_valid(limit.reference) {return}}
    ground:=frames_ground(rig,f,scratch) or_return
    for &value in request.residuals[:len(request.goals)] {value={}}
    for &value in request.violations[:len(request.limits)] {value={}}
    world:=scratch
    count,bones:=frames_count(f),f.bones
    rest:=world[count*bones:][:bones]
    metrics.duration,metrics.height,metrics.root=frames_duration(f),ground.height,ground.root
    metrics.travel,metrics.in_place=ground.travel,ground.in_place
    metrics.contacts=frames_contacts(rig,f,world,ground,request.contacts)

    // Slide and penetration of the feet.
    for foot in Foot {
        floors:[2]f32
        for part,k in foot_parts(foot) {if bone:=rig.body.bones[part];bone>=0 {floors[k]=frames_floor(world,bones,count,int(bone),ground.up)}}
        standing_frames:int
        for frame in 0..<count {
            standing,speed:=frames_standing(rig,f,world,ground,floors,foot,frame)
            if !standing {continue}
            standing_frames+=1
            metrics.foot_slide[foot].mean+=speed
            metrics.foot_slide[foot].max=max(metrics.foot_slide[foot].max,speed)
        }
        if standing_frames>0 {metrics.foot_slide[foot].mean/=f32(standing_frames)}
    }
    for frame in 0..<count {
        depth:f32
        for foot in Foot {
                parts:=foot_parts(foot)
            for part in parts {
                bone:=rig.body.bones[part]
                if bone<0 {continue}
                below:=linalg.dot(rest[bone].position,ground.up)-linalg.dot(world[frame*bones+int(bone)].position,ground.up)
                depth=max(depth,below-.005)
            }
        }
        metrics.penetration.mean+=depth/f32(count)
        metrics.penetration.max=max(metrics.penetration.max,depth)
    }

    // Jerk of the parts, by third differences.
    if count>=4 {
        samples:int
        rate3:=f.rate*f.rate*f.rate
        for bone in rig.body.bones {
            if bone<0 {continue}
            b:=int(bone)
            for frame in 1..<count-2 {
                p0,p1,p2,p3:=world[(frame-1)*bones+b].position,world[frame*bones+b].position,world[(frame+1)*bones+b].position,world[(frame+2)*bones+b].position
                jerk:=linalg.length(p3-3*p2+3*p1-p0)*rate3
                metrics.jerk.mean+=jerk;metrics.jerk.max=max(metrics.jerk.max,jerk);samples+=1
            }
        }
        if samples>0 {metrics.jerk.mean/=f32(samples)}
    }

    // Seam: the last frame against the first, relative to the root.
    root:=int(ground.root)
    relative :: proc "contextless" (world:[]math.Transform,bones,frame,root,bone:int) -> math.Vec3 {
        return math.transform_inverse_point(world[frame*bones+root],world[frame*bones+bone].position)
    }
    last:=count-1
    for bone in rig.body.bones {
        if bone<0 {continue}
        b:=int(bone)
        metrics.seam_position=max(metrics.seam_position,linalg.length(relative(world,bones,last,root,b)-relative(world,bones,0,root,b)))
        if count<4 {continue}
        change :: proc "contextless" (world:[]math.Transform,bones,root,b,before,at,after:int) -> f32 {
            return linalg.length(relative(world,bones,after,root,b)-2*relative(world,bones,at,root,b)+relative(world,bones,before,root,b))
        }
        inside:=max(change(world,bones,root,b,0,1,2),change(world,bones,root,b,last-2,last-1,last))
        metrics.seam_velocity=max(metrics.seam_velocity,(change(world,bones,root,b,last-1,0,1)-inside)*f.rate)
    }
    for bone in 0..<bones {
        if bone==root {continue}
        metrics.seam_rotation=max(metrics.seam_rotation,math.quat_angle(frames_pose(f,0)[bone].rotation,frames_pose(f,last)[bone].rotation))
    }

    // Limits a human body keeps, half a degree of tolerance.
    violate :: proc "contextless" (stat:^Limit_Stat,amount:f32) {
        if amount<=.0087 {return}
        stat.frames+=1;stat.worst=max(stat.worst,amount)
    }
    for frame in 0..<count {
        pose:=world[frame*bones:][:bones]
        for side in 0..<2 {
            hip,knee,foot:=rig.body.bones[.Hip_L if side==0 else .Hip_R],rig.body.bones[.Knee_L if side==0 else .Knee_R],rig.body.bones[.Foot_L if side==0 else .Foot_R]
            if hip>=0 && knee>=0 && foot>=0 {
                h,k,a:=pose[hip].position,pose[knee].position,pose[foot].position
                axis,valid:=anim_unit(a-h)
                d:=k-h
                if valid {d-=axis*linalg.dot(d,axis)}
                facing:=math.quat_rotate(pose[foot].rotation*conj(rest[foot].rotation),math.FORWARD)
                if valid {facing-=axis*linalg.dot(facing,axis)}
                if valid && linalg.length(d)>1e-3*ground.height && linalg.dot(d,facing)<0 {
                    violate(&metrics.limits[.Knee_L if side==0 else .Knee_R],cmath.PI-anim_angle(h-k,a-k))
                }
            }
            shoulder,elbow,hand:=rig.body.bones[.Shoulder_L if side==0 else .Shoulder_R],rig.body.bones[.Elbow_L if side==0 else .Elbow_R],rig.body.bones[.Hand_L if side==0 else .Hand_R]
            if shoulder>=0 && elbow>=0 && hand>=0 {
                inner:=anim_angle(pose[shoulder].position-pose[elbow].position,pose[hand].position-pose[elbow].position)
                violate(&metrics.limits[.Elbow_L if side==0 else .Elbow_R],15*math.RAD_PER_DEG-inner)
            }
        }
        head:=rig.body.bones[.Head]
        if head>=0 {
            base:=rig.body.bones[.Neck]
            base=rig.parents[base] if base>=0 else rig.parents[head]
            if base>=0 {
                now:=conj(pose[base].rotation)*pose[head].rotation
                at_rest:=conj(rest[base].rotation)*rest[head].rotation
                violate(&metrics.limits[.Head],math.quat_angle(at_rest,now)-80*math.RAD_PER_DEG)
            }
        }
        local:=frames_pose(f,frame)
        for limit,i in request.limits {
            limited,valid:=rotation_limit(local[limit.bone].rotation,limit.reference,limit.limit)
            if !valid {continue}
            violate(&request.violations[i],math.quat_angle(limited,local[limit.bone].rotation))
        }
        for goal,i in request.goals {
            residual:f32
            switch goal.kind {
            case .Reach: residual=linalg.length(pose[goal.bone].position-goal.target)
            case .Look: residual=anim_angle(math.quat_rotate(pose[goal.bone].rotation,goal.axis),goal.target-pose[goal.bone].position)
            }
            request.residuals[i].mean+=residual/f32(count)
            request.residuals[i].max=max(request.residuals[i].max,residual)
        }
    }
    return metrics,true
}

// The angle between two directions; 0 when one of them is zero.
@(private)
anim_angle :: proc "contextless" (a,b:math.Vec3) -> f32 {
    ua,oka:=anim_unit(a)
    ub,okb:=anim_unit(b)
    if !oka || !okb {return 0}
    return cmath.atan2(linalg.length(linalg.cross(ua,ub)),linalg.dot(ua,ub))
}
