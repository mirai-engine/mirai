package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// How far an offset turns or moves a part: turns in radians, the swing of
// an elbow or knee around its limb in radians, and moves in body heights.
OFFSET_TURNS :: [Body_Amount]f32{.Slight=6*math.RAD_PER_DEG,.Medium=15*math.RAD_PER_DEG,.Strong=30*math.RAD_PER_DEG}
OFFSET_SWINGS :: [Body_Amount]f32{.Slight=10*math.RAD_PER_DEG,.Medium=20*math.RAD_PER_DEG,.Strong=35*math.RAD_PER_DEG}
OFFSET_MOVES :: [Body_Amount]f32{.Slight=.02,.Medium=.05,.Strong=.10}

@(private)
Offset_Kind :: enum u8 {Face,Aim,Swing,Reach,Hips}

// Sets the world rotation of a bone and composes the pose again.
@(private)
edit_set_rotation :: proc "contextless" (parents:[]i32,local,world:[]math.Transform,bone:i32,rotation:math.Quat) -> bool {
    parent:=parents[bone]
    local[bone].rotation=linalg.normalize0(conj(world[parent].rotation)*rotation if parent>=0 else rotation)
    return pose_world(parents,local,world)
}
// Moves a bone by a world offset and composes the pose again.
@(private)
edit_move :: proc "contextless" (parents:[]i32,local,world:[]math.Transform,bone:i32,offset:math.Vec3) -> bool {
    parent:=parents[bone]
    if parent>=0 {local[bone].position+=math.quat_rotate(conj(world[parent].rotation),offset)/world[parent].scale} else {local[bone].position+=offset}
    return pose_world(parents,local,world)
}

// Turns a limb so that its end reaches the target, keeping the world
// rotation of the end and the side the limb bends to. The bones need not be
// parent and child: what lies between them follows.
@(private)
edit_limb_ik :: proc "contextless" (parents:[]i32,local,world:[]math.Transform,root,joint,end:i32,target:math.Vec3) -> bool {
    pole,pole_ok:=two_bone_pole_from_pose(world[root],world[joint],world[end],target)
    if !pole_ok {return false}
    solved,ok:=two_bone_ik(world[root],world[joint],world[end],target,pole)
    if !ok {return false}
    end_rotation:=world[end].rotation
    edit_set_rotation(parents,local,world,root,solved.root.rotation) or_return
    edit_set_rotation(parents,local,world,joint,solved.joint.rotation) or_return
    return edit_set_rotation(parents,local,world,end,end_rotation)
}

// The part an offset acts on and how, with the bones it needs.
@(private)
edit_offset_plan :: proc "contextless" (rig:Body_Rig,target:Offset_Target) -> (kind:Offset_Kind,bones:[3]i32,missing:Body_Part,ok:bool) {
    b:=rig.body.bones
    need :: proc "contextless" (b:[Body_Part]i32,parts:[]Body_Part,bones:^[3]i32) -> (Body_Part,bool) {
        for part,i in parts {
            if b[part]<0 {return part,false}
            bones[i]=b[part]
        }
        return .Pelvis,true
    }
    switch t in target {
    case Body_Region:
        if t!=.Spine {return}
        if b[.Pelvis]<0 {return .Face,{},.Pelvis,false}
        if b[.Neck]<0 && b[.Head]<0 {return .Face,{},.Neck,false}
        return .Face,{-1,-1,-1},.Pelvis,true
    case Body_Part:
        #partial switch t {
        case .Head,.Neck: missing,ok=need(b,{t},&bones);return .Face,bones,missing,ok
        case .Pelvis: missing,ok=need(b,{.Pelvis},&bones);return .Hips,bones,missing,ok
        case .Clavicle_L: missing,ok=need(b,{.Clavicle_L,.Shoulder_L},&bones);return .Aim,bones,missing,ok
        case .Clavicle_R: missing,ok=need(b,{.Clavicle_R,.Shoulder_R},&bones);return .Aim,bones,missing,ok
        case .Shoulder_L: missing,ok=need(b,{.Shoulder_L,.Elbow_L},&bones);return .Aim,bones,missing,ok
        case .Shoulder_R: missing,ok=need(b,{.Shoulder_R,.Elbow_R},&bones);return .Aim,bones,missing,ok
        case .Hip_L: missing,ok=need(b,{.Hip_L,.Knee_L},&bones);return .Aim,bones,missing,ok
        case .Hip_R: missing,ok=need(b,{.Hip_R,.Knee_R},&bones);return .Aim,bones,missing,ok
        case .Toe_L: missing,ok=need(b,{.Toe_L,.Foot_L},&bones);return .Aim,bones,missing,ok
        case .Toe_R: missing,ok=need(b,{.Toe_R,.Foot_R},&bones);return .Aim,bones,missing,ok
        case .Elbow_L: missing,ok=need(b,{.Shoulder_L,.Elbow_L,.Hand_L},&bones);return .Swing,bones,missing,ok
        case .Elbow_R: missing,ok=need(b,{.Shoulder_R,.Elbow_R,.Hand_R},&bones);return .Swing,bones,missing,ok
        case .Knee_L: missing,ok=need(b,{.Hip_L,.Knee_L,.Foot_L},&bones);return .Swing,bones,missing,ok
        case .Knee_R: missing,ok=need(b,{.Hip_R,.Knee_R,.Foot_R},&bones);return .Swing,bones,missing,ok
        case .Hand_L: missing,ok=need(b,{.Shoulder_L,.Elbow_L,.Hand_L},&bones);return .Reach,bones,missing,ok
        case .Hand_R: missing,ok=need(b,{.Shoulder_R,.Elbow_R,.Hand_R},&bones);return .Reach,bones,missing,ok
        case .Foot_L: missing,ok=need(b,{.Hip_L,.Knee_L,.Foot_L},&bones);return .Reach,bones,missing,ok
        case .Foot_R: missing,ok=need(b,{.Hip_R,.Knee_R,.Foot_R},&bones);return .Reach,bones,missing,ok
        }
    }
    return
}

@(private)
edit_offset :: proc "contextless" (rig:Body_Rig,e:Offset,input,output:Frames,scratch:[]math.Transform) -> Edit_Result {
    if e.direction>max(Body_Direction) || e.amount>max(Body_Amount) || e.target==nil {return {error=.Invalid_Amount}}
    if region,is_region:=e.target.(Body_Region);is_region && region!=.Spine {return {error=.Invalid_Amount}}
    if part,is_part:=e.target.(Body_Part);is_part && part>max(Body_Part) {return {error=.Invalid_Amount}}
    kind,bones,missing,planned:=edit_offset_plan(rig,e.target)
    if !planned {return {error=.Missing_Part,part=missing}}
    duration:=frames_duration(input)
    a,b,error:=edit_range(e.range,duration,input.rate)
    if error!=.None {return {error=error}}
    fade:=e.fade
    if fade==0 && e.range!={} {fade=min(f32(.2),(b-a)/4)}
    if !anim_finite(fade) || fade<0 || fade>(b-a)/2+1e-5 {return {error=.Invalid_Amount}}
    n:=input.bones
    world,rest:=scratch[:n],scratch[n:2*n]
    if !pose_world(rig.parents,rig.rest,rest) {return {error=.Numeric}}
    height:=body_height(rig.body,rest)
    spine:[64]i32
    spine_count:int
    if kind==.Face && bones[0]<0 {
        spine_ok:bool
        spine_count,spine_ok=body_spine(rig.parents,rig.body,spine[:])
        if !spine_ok || spine_count==0 {return {error=.Missing_Part,part=.Neck}}
    }
    forward,up_ok:=anim_unit(rig.body.forward)
    up,_:=anim_unit(rig.body.up)
    if !up_ok || up=={} {forward,up=math.FORWARD,{0,1,0}}
    axes:=rig.body;axes.forward,axes.up=forward,up
    turns,swings,moves:=OFFSET_TURNS,OFFSET_SWINGS,OFFSET_MOVES
    turn,swing,move:=turns[e.amount],swings[e.amount],moves[e.amount]*height
    root:=frames_root(rig,input)
    copy(output.local,input.local);copy(output.values,input.values)
    for frame in 0..<frames_count(input) {
        w:=edit_weight(a,b,duration,fade,f32(frame)/input.rate)
        if w<=0 {continue}
        pose:=frames_pose(output,frame)
        if !pose_world(rig.parents,pose,world) {return {error=.Numeric}}
        // Directions follow the root as it turns.
        facing:=world[root].rotation*conj(rest[root].rotation)
        direction:=math.quat_rotate(facing,body_direction_vector(axes,e.direction))
        switch kind {
        case .Face:
            face:=math.quat_rotate(facing,forward)
            if e.direction==.Forward || e.direction==.Back {face=math.quat_rotate(facing,up)}
            axis,valid:=anim_unit(linalg.cross(face,direction))
            if !valid {return {error=.Along_Part}}
            angle:=turn*w
            if bones[0]>=0 {
                if !edit_set_rotation(rig.parents,pose,world,bones[0],math.quat_axis_angle(axis,angle)*world[bones[0]].rotation) {return {error=.Numeric}}
            } else {
                for bone in spine[:spine_count] {
                    if !edit_set_rotation(rig.parents,pose,world,bone,math.quat_axis_angle(axis,angle/f32(spine_count))*world[bone].rotation) {return {error=.Numeric}}
                }
            }
        case .Aim:
            aim:=world[bones[1]].position-world[bones[0]].position
            // A toe points away from its foot.
            if e.target==Offset_Target(Body_Part.Toe_L) || e.target==Offset_Target(Body_Part.Toe_R) {aim=-aim}
            // A part turns toward a direction at most until it points there.
            left:=anim_angle(aim,direction)
            axis,valid:=anim_unit(linalg.cross(aim,direction))
            if !valid || left<turn*.5 {return {error=.Along_Part}}
            if !edit_set_rotation(rig.parents,pose,world,bones[0],math.quat_axis_angle(axis,min(turn,left)*w)*world[bones[0]].rotation) {return {error=.Numeric}}
        case .Swing:
            limb,valid:=anim_unit(world[bones[2]].position-world[bones[0]].position)
            if !valid {return {error=.Numeric}}
            bend:=world[bones[1]].position-world[bones[0]].position
            bend-=limb*linalg.dot(bend,limb)
            toward:=direction-limb*linalg.dot(direction,limb)
            if linalg.length(toward)<1e-3 {return {error=.Along_Part}}
            if linalg.length(bend)<1e-4*height {continue}
            angle:f32=min(swing,anim_angle(bend,toward))*w
            if linalg.dot(linalg.cross(bend,toward),limb)<0 {angle=-angle}
            end_rotation:=world[bones[2]].rotation
            if !edit_set_rotation(rig.parents,pose,world,bones[0],math.quat_axis_angle(limb,angle)*world[bones[0]].rotation) {return {error=.Numeric}}
            if !edit_set_rotation(rig.parents,pose,world,bones[2],end_rotation) {return {error=.Numeric}}
        case .Reach:
            target:=world[bones[2]].position+direction*(move*w)
            if !edit_limb_ik(rig.parents,pose,world,bones[0],bones[1],bones[2],target) {return {error=.Numeric}}
        case .Hips:
            // The feet stay where they were.
            feet:[2]math.Vec3
            legs:=[2][3]Body_Part{{.Hip_L,.Knee_L,.Foot_L},{.Hip_R,.Knee_R,.Foot_R}}
            for leg,i in legs {if b:=rig.body.bones[leg[2]];b>=0 {feet[i]=world[b].position}}
            if !edit_move(rig.parents,pose,world,bones[0],direction*(move*w)) {return {error=.Numeric}}
            for leg,i in legs {
                hip,knee,foot:=rig.body.bones[leg[0]],rig.body.bones[leg[1]],rig.body.bones[leg[2]]
                if hip<0 || knee<0 || foot<0 {continue}
                if !edit_limb_ik(rig.parents,pose,world,hip,knee,foot,feet[i]) {return {error=.Numeric}}
            }
        }
        if !anim_pose_valid(pose) {return {error=.Numeric}}
    }
    return {}
}

// A target farther than start from the root of a limb comes closer smoothly,
// never past its length, so the middle joint does not snap straight.
@(private)
edit_soft_reach :: proc "contextless" (root,target:math.Vec3,length,start:f32) -> math.Vec3 {
    soft:=length-start
    delta:=target-root
    distance:=linalg.length(delta)
    if !(distance>start) || !(soft>0) {return target}
    return root+delta*((length-soft*cmath.exp(-(distance-start)/soft))/distance)
}
// The reach of a limb that softens: what the pose already reaches, or this
// much of its length when that is more.
EDIT_SOFT_REACH :: .95
@(private)
edit_reach :: proc "contextless" (root,end:math.Vec3,length:f32) -> f32 {return min(max(linalg.length(end-root),EDIT_SOFT_REACH*length),length)}

@(private)
edit_lock_feet :: proc "contextless" (rig:Body_Rig,e:Lock_Feet,input,output:Frames,buffers:Edit_Buffers) -> Edit_Result {
    blend:=e.blend if e.blend!=0 else .1
    if !anim_finite(blend) || blend<0 || blend>1 {return {error=.Invalid_Amount}}
    legs:=[Foot][3]Body_Part{.Left={.Hip_L,.Knee_L,.Foot_L},.Right={.Hip_R,.Knee_R,.Foot_R}}
    usable:=false
    missing:=Body_Part.Foot_L
    for leg in legs {
        whole:=true
        for part in leg {if rig.body.bones[part]<0 {whole=false;missing=part;break}}
        usable||=whole
    }
    if !usable {return {error=.Missing_Part,part=missing}}
    ground,ok:=frames_ground(rig,input,buffers.world)
    if !ok {return {error=.Numeric}}
    contacts:=buffers.contacts[:frames_contacts(rig,input,buffers.world,ground,buffers.contacts)]
    copy(output.local,input.local);copy(output.values,input.values)
    count,n:=frames_count(input),input.bones
    rest:=buffers.world[count*n:][:n]
    lengths:[Foot]f32
    for leg,foot in legs {
        hip,knee,ankle:=rig.body.bones[leg[0]],rig.body.bones[leg[1]],rig.body.bones[leg[2]]
        if hip<0 || knee<0 || ankle<0 {continue}
        lengths[foot]=linalg.length(rest[knee].position-rest[hip].position)+linalg.length(rest[ankle].position-rest[knee].position)
    }
    ramp:=max(int(blend*input.rate+.5),1)
    duration:=frames_duration(input)
    pelvis:=rig.body.bones[.Pelvis]
    floors:[Foot][2]f32
    for foot in Foot {for part,k in foot_parts(foot) {if bone:=rig.body.bones[part];bone>=0 {floors[foot][k]=frames_floor(buffers.world,n,count,int(bone),ground.up)}}}
    // Where the feet go at a frame and how much: locked over the ground while
    // they stand, easing in before and out after; in a loop also from the
    // contacts of the passes around this one. The ankle stays over its anchor
    // while the heel is down and turns about the toe as it lifts. A foot keeps
    // its own height.
    targets :: proc "contextless" (rig:Body_Rig,contacts:[]Contact,lengths:[Foot]f32,floors:[Foot][2]f32,ground:Ground,input:Frames,world:[]math.Transform,ramp,frame:int,duration:f32) -> (weights:[Foot]f32,places:[Foot]math.Vec3) {
        count:=frames_count(input)
        anchors:[Foot][2]math.Vec3
        time:=f32(frame)/input.rate
        for contact in contacts {
            if lengths[contact.foot]<=0 {continue}
            for pass in -1..=1 {
                if pass!=0 && !input.loop {continue}
                first,last:=int(contact.first)+pass*(count-1),int(contact.last)+pass*(count-1)
                w:f32
                switch {
                case frame>=first && frame<=last: w=1
                case frame<first && frame>=first-ramp: w=math.smoothstep(f32(first-ramp-1),f32(first),f32(frame))
                case frame>last && frame<=last+ramp: w=1-math.smoothstep(f32(last),f32(last+ramp+1),f32(frame))
                }
                if w<=weights[contact.foot] {continue}
                weights[contact.foot]=w
                shift:=ground.travel*(f32(pass)*duration)+ground.velocity*time
                anchors[contact.foot]={contact.anchors[0]+shift,contact.anchors[1]+shift}
            }
        }
        for foot in Foot {
            if weights[foot]<=0 {continue}
            parts:=foot_parts(foot)
            animated:=world[rig.body.bones[parts[0]]].position
            pinned:=anchors[foot][0]
            if toe:=rig.body.bones[parts[1]];toe>=0 {
                lift:=1-frames_down(linalg.dot(animated,ground.up)-floors[foot][0],ground.height)
                pinned+=(anchors[foot][1]+animated-world[toe].position-pinned)*lift
            }
            places[foot]=animated+frames_horizontal(pinned-animated,ground.up)*weights[foot]
        }
        return
    }
    // How far the hips must go for the standing feet to reach: as little as
    // lets every one reach, halfway when they ask opposite ways.
    heights,need:=buffers.heights[:count],buffers.heights[count:][:count]
    for frame in 0..<count {
        heights[frame]=0
        if pelvis<0 {continue}
        world:=buffers.world[frame*n:][:n]
        if !pose_world(rig.parents,frames_pose(output,frame),world) {return {error=.Numeric}}
        weights,places:=targets(rig,contacts,lengths,floors,ground,input,world,ramp,frame,duration)
        low,high:=-max(f32),max(f32)
        for leg,foot in legs {
            if weights[foot]<=0 {continue}
            hip:=world[rig.body.bones[leg[0]]].position
            reach:=edit_reach(hip,world[rig.body.bones[leg[2]]].position,lengths[foot])
            minimum,maximum,reachable:=limb_height_range(hip,places[foot],ground.up,reach)
            if reachable {low,high=max(low,minimum),min(high,maximum)}
        }
        switch {
        case low>high: heights[frame]=(low+high)/2
        case low>0 || high<0: heights[frame]=clamp(0,low,high)
        }
    }
    // The hips move smoothly: the largest need around each frame, eased over the ramp.
    at :: proc "contextless" (values:[]f32,index:int,loop:bool) -> f32 {
        period:=len(values)-1
        if loop && period>0 {return values[((index%period)+period)%period]}
        return values[clamp(index,0,len(values)-1)]
    }
    for frame in 0..<count {
        largest:f32
        for k in -ramp..=ramp {if value:=at(heights,frame+k,input.loop);abs(value)>abs(largest) {largest=value}}
        need[frame]=largest
    }
    for frame in 0..<count {
        sum,total:f32
        for k in -ramp..=ramp {w:=f32(ramp+1-abs(k));sum+=at(need,frame+k,input.loop)*w;total+=w}
        heights[frame]=sum/total
    }
    for frame in 0..<count {
        pose:=frames_pose(output,frame)
        world:=buffers.world[frame*n:][:n]
        if !pose_world(rig.parents,pose,world) {return {error=.Numeric}}
        weights,places:=targets(rig,contacts,lengths,floors,ground,input,world,ramp,frame,duration)
        if weights==({}) && heights[frame]==0 {continue}
        reaches:[Foot]f32
        for leg,foot in legs {if lengths[foot]>0 {reaches[foot]=edit_reach(world[rig.body.bones[leg[0]]].position,world[rig.body.bones[leg[2]]].position,lengths[foot])}}
        moved:=pelvis>=0 && heights[frame]!=0
        if moved {
            // A foot in the air stays where it was while the hips move.
            for leg,foot in legs {if weights[foot]<=0 {places[foot]=world[rig.body.bones[leg[2]]].position}}
            if !edit_move(rig.parents,pose,world,pelvis,ground.up*heights[frame]) {return {error=.Numeric}}
        }
        for leg,foot in legs {
            if lengths[foot]<=0 || weights[foot]<=0 && !moved {continue}
            places[foot]=edit_soft_reach(world[rig.body.bones[leg[0]]].position,places[foot],lengths[foot],reaches[foot])
            if !edit_limb_ik(rig.parents,pose,world,rig.body.bones[leg[0]],rig.body.bones[leg[1]],rig.body.bones[leg[2]],places[foot]) {return {error=.Numeric}}
        }
        if !anim_pose_valid(pose) {return {error=.Numeric}}
    }
    return {}
}

@(private)
edit_mirror :: proc "contextless" (rig:Body_Rig,input,output:Frames,scratch:[]math.Transform) -> Edit_Result {
    mirror:=rig.mirror
    n:=input.bones
    if len(mirror.pairs)!=n || len(mirror.corrections)!=n {return {error=.Missing_Mirror}}
    copy(output.values,input.values)
    for frame in 0..<frames_count(input) {
        local,out:=frames_pose(input,frame),frames_pose(output,frame)
        if !pose_mirror(rig.parents,mirror.pairs,mirror.corrections,mirror.plane,local,out,scratch[:2*n]) {return {error=.Numeric}}
        // A root moves across the plane too, from where it rests.
        for parent,bone in rig.parents {
            if parent>=0 {continue}
            relative,ok:=math.transform_relative(local[bone],rig.rest[bone])
            if !ok {return {error=.Numeric}}
            reflected:=math.Transform{mirror_vector(mirror.plane,relative.position),mirror_rotation(mirror.plane,relative.rotation),relative.scale}
            out[bone]=math.transform_compose(rig.rest[bone],reflected)
        }
    }
    return {}
}

// A joint turned about up this far from its rest faces elsewhere; less is a sway of the body.
FACE_REST_TURN :: math.PI/4

@(private)
edit_face_rest :: proc "contextless" (rig:Body_Rig,input,output:Frames,scratch:[]math.Transform) -> Edit_Result {
    n:=input.bones
    count:=frames_count(input)
    copy(output.local,input.local);copy(output.values,input.values)
    rest,world:=scratch[:n],scratch[n:2*n]
    if !pose_world(rig.parents,rig.rest,rest) {return {error=.Numeric}}
    up:=frames_up(rig)
    // The turn about up of a bone from its rest, in the space of the clip.
    heading :: proc "contextless" (world,rest:math.Transform,up:math.Vec3) -> math.Quat {
        _,twist:=math.quat_swing_twist(world.rotation*conj(rest.rotation),up)
        return twist
    }
    // The joints that carry the body: from the pelvis (or the root of the rig) up to the root of
    // the skeleton. The highest that faces elsewhere is the one that turns it.
    start:=rig.body.bones[.Pelvis]
    if start<0 {start=rig.root}
    if start<0 {return {error=.Missing_Part,part=.Pelvis}}
    chain:[64]i32
    depth:=0
    for at:=start;at>=0 && depth<len(chain);at=rig.parents[at] {chain[depth]=at;depth+=1}
    turned:=-1
    for frame in 0..<count {
        if !pose_world(rig.parents,frames_pose(input,frame),world) {return {error=.Numeric}}
        for i in turned+1..<depth {
            if math.quat_angle(heading(world[chain[i]],rest[chain[i]],up),1)>FACE_REST_TURN {turned=i}
        }
    }
    if turned<0 {return {}}
    joint:=chain[turned]
    // The body faces where the joint that carries the pelvis does: a turn split between it and
    // those above it (the clip's side and a turn toward a camera on top) is undone whole at the
    // highest, and the pelvis keeps its own sway.
    carrier:=chain[min(turned,1)]
    for frame in 0..<count {
        local:=frames_pose(output,frame)
        if !pose_world(rig.parents,local,world) {return {error=.Numeric}}
        turn:=heading(world[carrier],rest[carrier],up)
        if !edit_set_rotation(rig.parents,local,world,joint,conj(turn)*world[joint].rotation) || !anim_pose_valid(local) {return {error=.Numeric}}
    }
    return {}
}
