package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

// The parts of a body that edits, metrics and constraints name. Arms and legs
// go from the body outwards: Shoulder is the upper arm and Hip the thigh.
Body_Part :: enum u8 {
    Pelvis,Neck,Head,
    Clavicle_L,Shoulder_L,Elbow_L,Hand_L,
    Clavicle_R,Shoulder_R,Elbow_R,Hand_R,
    Hip_L,Knee_L,Foot_L,Toe_L,
    Hip_R,Knee_R,Foot_R,Toe_R,
}
Body_Parts :: bit_set[Body_Part]

BODY_PART_NAMES :: [Body_Part]string{
    .Pelvis="pelvis",.Neck="neck",.Head="head",
    .Clavicle_L="clavicle_l",.Shoulder_L="shoulder_l",.Elbow_L="elbow_l",.Hand_L="hand_l",
    .Clavicle_R="clavicle_r",.Shoulder_R="shoulder_r",.Elbow_R="elbow_r",.Hand_R="hand_r",
    .Hip_L="hip_l",.Knee_L="knee_l",.Foot_L="foot_l",.Toe_L="toe_l",
    .Hip_R="hip_r",.Knee_R="knee_r",.Foot_R="foot_r",.Toe_R="toe_r",
}

// Where the parts of a body are in a skeleton. bones holds the bone of each
// part, -1 when it has none; the spine is the chain between the pelvis and the
// neck. forward and up are where the body faces and its up at rest, in the
// space of the roots. A confidence goes from 0 (a guess) to 1 (certain);
// manual marks what a person set, which detection keeps.
Body_Map :: struct {
    bones:[Body_Part]i32,
    confidence:[Body_Part]f32,
    forward,up:math.Vec3,
    axes_confidence:f32,
    manual:Body_Parts,
    manual_axes:bool,
}

// What a mask covers: each region is the branch of its first bone, the spine
// holds the chain and what hangs from it outside the arms and the head, and
// the hips hold the pelvis and the bones above it.
Body_Region :: enum u8 {Hips,Spine,Head,Arm_L,Arm_R,Leg_L,Leg_R}
Body_Regions :: bit_set[Body_Region]
BODY_REGIONS_ALL :: Body_Regions{.Hips,.Spine,.Head,.Arm_L,.Arm_R,.Leg_L,.Leg_R}

Body_Region_Name :: struct {name:string,regions:Body_Regions}
BODY_REGION_NAMES :: [?]Body_Region_Name{
    {"body",BODY_REGIONS_ALL},
    {"upper_body",{.Spine,.Head,.Arm_L,.Arm_R}},
    {"lower_body",{.Hips,.Leg_L,.Leg_R}},
    {"arms",{.Arm_L,.Arm_R}},
    {"legs",{.Leg_L,.Leg_R}},
    {"hips",{.Hips}},{"spine",{.Spine}},{"head",{.Head}},
    {"arm_l",{.Arm_L}},{"arm_r",{.Arm_R}},{"leg_l",{.Leg_L}},{"leg_r",{.Leg_R}},
}

// Directions in the space of the body: where it faces, its left and its up.
Body_Direction :: enum u8 {Forward,Back,Left,Right,Up,Down}
BODY_DIRECTION_NAMES :: [Body_Direction]string{.Forward="forward",.Back="back",.Left="left",.Right="right",.Up="up",.Down="down"}
Body_Amount :: enum u8 {Slight,Medium,Strong}
BODY_AMOUNT_NAMES :: [Body_Amount]string{.Slight="slight",.Medium="medium",.Strong="strong"}

body_part_parse :: proc "contextless" (name:string) -> (Body_Part,bool) {
    for value,part in BODY_PART_NAMES {if value==name {return part,true}}
    return .Pelvis,false
}
body_regions_parse :: proc "contextless" (name:string) -> (Body_Regions,bool) {
    for value in BODY_REGION_NAMES {if value.name==name {return value.regions,true}}
    return {},false
}
body_direction_parse :: proc "contextless" (name:string) -> (Body_Direction,bool) {
    for value,direction in BODY_DIRECTION_NAMES {if value==name {return direction,true}}
    return .Forward,false
}
body_amount_parse :: proc "contextless" (name:string) -> (Body_Amount,bool) {
    for value,amount in BODY_AMOUNT_NAMES {if value==name {return amount,true}}
    return .Slight,false
}

// The other side of a part, or the part itself.
body_part_mirror :: proc "contextless" (part:Body_Part) -> Body_Part {
    #partial switch part {
    case .Clavicle_L..=.Hand_L: return Body_Part(u8(part)+4)
    case .Clavicle_R..=.Hand_R: return Body_Part(u8(part)-4)
    case .Hip_L..=.Toe_L: return Body_Part(u8(part)+4)
    case .Hip_R..=.Toe_R: return Body_Part(u8(part)-4)
    }
    return part
}

body_map_empty :: proc "contextless" () -> Body_Map {
    map_:Body_Map
    for &bone in map_.bones {bone=-1}
    return map_
}

// Bones inside the skeleton and each one in a single part, confidences
// between 0 and 1, and the axes unit and perpendicular, or zero without parts.
body_map_valid :: proc "contextless" (map_:Body_Map,bone_count:int) -> bool {
    any:=false
    for bone,part in map_.bones {
        confidence:=map_.confidence[part]
        if !anim_finite(confidence) || confidence<0 || confidence>1 || bone< -1 || int(bone)>=bone_count {return false}
        if bone<0 {continue}
        any=true
        for other,other_part in map_.bones {if other_part!=part && other==bone {return false}}
    }
    if !anim_finite(map_.axes_confidence) || map_.axes_confidence<0 || map_.axes_confidence>1 {return false}
    if !any && map_.forward=={} && map_.up=={} {return true}
    return body_axes_valid(map_.forward,map_.up)
}
body_axes_valid :: proc "contextless" (forward,up:math.Vec3) -> bool {
    if !anim_vec3_valid(forward) || !anim_vec3_valid(up) {return false}
    return abs(linalg.dot(forward,forward)-1)<1e-3 && abs(linalg.dot(up,up)-1)<1e-3 && abs(linalg.dot(forward,up))<1e-3
}
// The left of the body: with Y up and -Z forward it is -X.
body_left :: #force_inline proc "contextless" (map_:Body_Map) -> math.Vec3 {return linalg.cross(map_.up,map_.forward)}
body_direction_vector :: proc "contextless" (map_:Body_Map,direction:Body_Direction) -> math.Vec3 {
    switch direction {
    case .Forward: return map_.forward
    case .Back: return -map_.forward
    case .Left: return body_left(map_)
    case .Right: return -body_left(map_)
    case .Up: return map_.up
    case .Down: return -map_.up
    }
    return {}
}

@(private)
body_is_ancestor :: proc "contextless" (parents:[]i32,ancestor,bone:i32) -> bool {
    if ancestor<0 || bone<0 || int(bone)>=len(parents) {return false}
    at:=bone
    for at>=0 {
        if at==ancestor {return true}
        if int(at)>=len(parents) {return false}
        at=parents[at]
    }
    return false
}
@(private)
body_common_ancestor :: proc "contextless" (parents:[]i32,a,b:i32) -> i32 {
    if a<0 || b<0 {return -1}
    at:=a
    for at>=0 {
        if body_is_ancestor(parents,at,b) {return at}
        at=parents[at]
    }
    return -1
}

// The chain between the pelvis and the neck (the head without neck), from the
// pelvis up and without either. False when the neck does not hang from the
// pelvis or out is too short.
body_spine :: proc "contextless" (parents:[]i32,map_:Body_Map,out:[]i32) -> (count:int,ok:bool) {
    pelvis,neck:=map_.bones[.Pelvis],map_.bones[.Neck]
    if neck<0 {neck=map_.bones[.Head]}
    if pelvis<0 || neck<0 || int(neck)>=len(parents) || pelvis==neck || !body_is_ancestor(parents,pelvis,neck) {return}
    at:=parents[neck]
    for at!=pelvis {count+=1;at=parents[at]}
    if count>len(out) {return 0,false}
    at=parents[neck]
    for i:=count-1;i>=0;i-=1 {out[i]=at;at=parents[at]}
    return count,true
}

// The region of every bone, -1 for those of none: the bones above the
// pelvis belong to the hips, and what hangs from them outside the pelvis, as
// the targets of IK rigs, to none.
body_regions :: proc "contextless" (parents:[]i32,map_:Body_Map,out:[]i8) -> bool {
    if len(out)!=len(parents) || len(parents)==0 || !body_map_valid(map_,len(parents)) {return false}
    for parent,i in parents {if parent< -1 || int(parent)>=i {return false}}
    for &value in out {value=-2}
    pelvis:=map_.bones[.Pelvis]
    neck:=map_.bones[.Neck] if map_.bones[.Neck]>=0 else map_.bones[.Head]
    if pelvis>=0 {
        at:=pelvis
        for at>=0 {out[at]=i8(Body_Region.Hips);at=parents[at]}
        if neck>=0 && body_is_ancestor(parents,pelvis,neck) {
            at=parents[neck]
            for at!=pelvis {out[at]=i8(Body_Region.Spine);at=parents[at]}
        }
    }
    starts:=[?]struct {parts:[2]Body_Part,region:Body_Region}{
        {{.Neck,.Head},.Head},
        {{.Clavicle_L,.Shoulder_L},.Arm_L},{{.Clavicle_R,.Shoulder_R},.Arm_R},
        {{.Hip_L,.Hip_L},.Leg_L},{{.Hip_R,.Hip_R},.Leg_R},
    }
    for start in starts {
        bone:=map_.bones[start.parts[0]]
        if bone<0 {bone=map_.bones[start.parts[1]]}
        if bone>=0 && out[bone]==-2 {out[bone]=i8(start.region)}
    }
    for parent,i in parents {
        if out[i]!=-2 {continue}
        out[i]=-1
        if parent<0 {continue}
        inherited:=out[parent]
        // Below a bone above the pelvis there is only the pelvis branch.
        if inherited==i8(Body_Region.Hips) && parent!=pelvis {continue}
        out[i]=inherited
    }
    return true
}

// The weight of every bone for the regions given: 1 inside, 0 outside. Bones
// of no region count only for the whole body.
body_mask :: proc "contextless" (parents:[]i32,map_:Body_Map,regions:Body_Regions,scratch:[]i8,out:[]f32) -> bool {
    if len(out)!=len(parents) || len(scratch)!=len(parents) || !body_regions(parents,map_,scratch) {return false}
    for region,i in scratch {out[i]=1 if body_region_inside(region,regions) else 0}
    return true
}

// Whether a bone of this region (body_regions) is inside the regions given.
body_region_inside :: #force_inline proc "contextless" (region:i8,regions:Body_Regions) -> bool {
    return region<0 && regions==BODY_REGIONS_ALL || region>=0 && Body_Region(region) in regions
}

// Bones in no region, as helpers outside the body.
body_unassigned :: proc "contextless" (parents:[]i32,map_:Body_Map,scratch:[]i8,out:[]i32) -> (count:int,ok:bool) {
    if !body_regions(parents,map_,scratch) {return 0,false}
    for region,i in scratch {
        if region>=0 {continue}
        if count<len(out) {out[count]=i32(i)}
        count+=1
    }
    return count,count<=len(out)
}

// The height of the body at rest: from its lowest foot or toe to its head, or
// the extent of the skeleton along up without them.
body_height :: proc "contextless" (map_:Body_Map,world:[]math.Transform) -> f32 {
    up,ok:=anim_unit(map_.up)
    if !ok {up={0,1,0}}
    high,low:=min(f32),max(f32)
    head:=map_.bones[.Head]
    if head>=0 && int(head)<len(world) {high=linalg.dot(world[head].position,up)}
    for part in ([4]Body_Part{.Foot_L,.Foot_R,.Toe_L,.Toe_R}) {
        bone:=map_.bones[part]
        if bone>=0 && int(bone)<len(world) {low=min(low,linalg.dot(world[bone].position,up))}
    }
    if high==min(f32) || low==max(f32) {
        high,low=min(f32),max(f32)
        for value in world {h:=linalg.dot(value.position,up);high=max(high,h);low=min(low,h)}
    }
    height:=high-low
    return height if anim_finite(height) && height>1e-4 else 1
}

@(private="file")
Body_Kind :: enum u8 {None,Pelvis,Spine,Neck,Head,Clavicle,Shoulder,Elbow,Hand,Hip,Knee,Foot,Toe}
@(private="file")
Body_Side :: enum u8 {None,Left,Right}
@(private="file")
Body_Name :: struct {kind:Body_Kind,side:Body_Side,score:f32}

@(private="file")
BODY_EXCLUDED :: [?]string{
    "twist","roll","ik","fk","mch","org","ctrl","ctl","pole","target","tgt","helper","corrective",
    "correctiveroot","end","nub","top","tip","vb","socket","weapon","prop","attach","bend","jiggle",
    "dyn","index","middle","ring","pinky","little","thumb","finger","fingers","metacarpal","jaw",
    "eye","eyes","brow","lid","lip","lips","tongue","ear","teeth","cheek","nose","breast","cloth",
    "hair","tail","wing","gun","muscle","bulge","pivot","aim","lookat","null","dummy","adjust",
}
@(private="file")
BODY_KEYWORDS :: [?]string{
    "pelvis","hips","hip","hipjoint","thigh","femur","upleg","upperleg","calf","shin","tibia","knee",
    "lowerleg","lowleg","leg","foot","ankle","toe","toes","ball","toebase","clavicle","collar",
    "collarbone","clav","shoulder","upperarm","humerus","uparm","arm","forearm","lowerarm","lowarm",
    "elbow","radius","ulna","hand","wrist","neck","head","spine","chest","torso","abdomen","waist",
    "upperchest",
}

// What a bone name says it is: its words come from separators, case changes
// and digits (LeftUpLeg, thigh_l, Bip01 L Calf, DEF-upper_arm.L), and a side
// may be glued to the front of a known word (lfemur, rhand).
@(private="file")
body_name :: proc "contextless" (name:string) -> Body_Name {
    text:[128]u8
    starts,ends:[16]u8
    count:=0
    n:=min(len(name),len(text))
    upper :: proc "contextless" (c:u8) -> bool {return c>='A' && c<='Z'}
    lower :: proc "contextless" (c:u8) -> bool {return c>='a' && c<='z'}
    digit :: proc "contextless" (c:u8) -> bool {return c>='0' && c<='9'}
    start:=-1
    for i in 0..<n {
        c:=name[i]
        text[i]=c+32 if upper(c) else c
        if !upper(c) && !lower(c) && !digit(c) {
            if start>=0 && count<len(starts) {starts[count],ends[count]=u8(start),u8(i);count+=1}
            start=-1;continue
        }
        if start<0 {start=i;continue}
        p:=name[i-1]
        if lower(p) && upper(c) || digit(p)!=digit(c) || upper(p) && upper(c) && i+1<n && lower(name[i+1]) {
            if count<len(starts) {starts[count],ends[count]=u8(start),u8(i);count+=1}
            start=i
        }
    }
    if start>=0 && count<len(starts) {starts[count],ends[count]=u8(start),u8(n);count+=1}

    result:Body_Name
    words:[16]string
    for i in 0..<count {
        word:=string(text[starts[i]:ends[i]])
        for excluded in BODY_EXCLUDED {if word==excluded {return {}}}
        switch word {
        case "l","left": result.side=.Left;continue
        case "r","right": result.side=.Right;continue
        }
        known:=false
        for keyword in BODY_KEYWORDS {if word==keyword {known=true;break}}
        if !known {
            for prefix in ([4]string{"left","right","l","r"}) {
                if len(word)<=len(prefix) || word[:len(prefix)]!=prefix {continue}
                rest:=word[len(prefix):]
                glued:=false
                for keyword in BODY_KEYWORDS {if rest==keyword {glued=true;break}}
                if !glued {continue}
                result.side=.Left if prefix[0]=='l' else .Right
                word=rest
                break
            }
        }
        words[i]=word
    }
    has :: proc "contextless" (words:[]string,word:string) -> bool {
        for value in words {if value==word {return true}}
        return false
    }
    w:=words[:count]
    sided:=result.side!=.None
    set :: proc "contextless" (result:^Body_Name,kind:Body_Kind,score:f32) -> Body_Name {
        result.kind,result.score=kind,score
        return result^
    }
    switch {
    case has(w,"pelvis") || has(w,"hips"): return set(&result,.Pelvis,1)
    case has(w,"hipjoint"): return set(&result,.Hip,.6)
    case has(w,"hip"): return set(&result,.Hip,.8) if sided else set(&result,.Pelvis,.8)
    case has(w,"thigh") || has(w,"femur") || has(w,"upleg") || has(w,"upperleg") || (has(w,"up") || has(w,"upper")) && has(w,"leg"): return set(&result,.Hip,1)
    case has(w,"calf") || has(w,"shin") || has(w,"tibia") || has(w,"knee") || has(w,"lowerleg") || has(w,"lowleg") || (has(w,"lower") || has(w,"low")) && has(w,"leg"): return set(&result,.Knee,1)
    case has(w,"leg") && sided: return set(&result,.Knee,.8)
    case has(w,"foot") || has(w,"ankle"): return set(&result,.Foot,1)
    case has(w,"toe") || has(w,"toes") || has(w,"ball") || has(w,"toebase"): return set(&result,.Toe,1)
    case has(w,"clavicle") || has(w,"collar") || has(w,"collarbone") || has(w,"clav"): return set(&result,.Clavicle,1)
    case has(w,"forearm") || has(w,"lowerarm") || has(w,"lowarm") || has(w,"elbow") || has(w,"radius") || has(w,"ulna") || (has(w,"fore") || has(w,"lower") || has(w,"low")) && has(w,"arm"): return set(&result,.Elbow,1)
    case has(w,"upperarm") || has(w,"humerus") || has(w,"uparm") || (has(w,"upper") || has(w,"up")) && has(w,"arm"): return set(&result,.Shoulder,1)
    case has(w,"arm") && sided: return set(&result,.Shoulder,.8)
    // Mixamo and Rigify call the clavicle shoulder; a rig whose upper arm is
    // called so has no other upper arm, which the chain search resolves.
    case has(w,"shoulder"): return set(&result,.Clavicle,.7)
    case has(w,"hand"): return set(&result,.Hand,1)
    case has(w,"wrist"): return set(&result,.Hand,.9)
    case has(w,"neck"): return set(&result,.Neck,1)
    case has(w,"head"): return set(&result,.Head,1)
    case has(w,"spine") || has(w,"chest") || has(w,"torso") || has(w,"abdomen") || has(w,"waist") || has(w,"upperchest"): return set(&result,.Spine,1)
    }
    return {}
}

@(private="file")
Body_Limb :: struct {bones:[4]i32,score:[4]f32,side:Body_Side}

// The best chain of a limb ending at bones of kind `kinds[2]`: walking up from
// each candidate end, the nearest ancestor of each kind before it. kinds[3]
// is the extra bone of the limb: the toe, below the foot, or the clavicle,
// above the upper arm. A missing middle bone takes the ancestor in between
// that bends most.
@(private="file")
body_limb :: proc "contextless" (parents:[]i32,names:[]string,world:[]math.Transform,kinds:[4]Body_Kind,side:Body_Side,exclude:i32) -> (best:Body_Limb) {
    for &bone in best.bones {bone=-1}
    best_score:f32
    n:=i32(len(parents))
    for end in 0..<n {
        name:=body_name(names[end])
        if name.kind!=kinds[2] || name.side!=side {continue}
        // An end inside the branch of another candidate end is a part of it, as lhand below lwrist.
        nested:=false
        at:=parents[end]
        for at>=0 {
            other:=body_name(names[at])
            if other.kind==kinds[2] && other.side==side {nested=true;break}
            at=parents[at]
        }
        if nested || end==exclude {continue}
        limb:=Body_Limb{bones={-1,-1,end,-1},score={0,0,name.score,0},side=side}
        // The joint and the root above the end, the root possibly called as the extra bone (shoulder).
        at=parents[end]
        for at>=0 {
            other:=body_name(names[at])
            if other.side==side || other.side==.None {
                if limb.bones[1]<0 && limb.bones[0]<0 && other.kind==kinds[1] {limb.bones[1]=at;limb.score[1]=other.score}
                else if limb.bones[0]<0 && other.kind==kinds[0] {limb.bones[0]=at;limb.score[0]=other.score}
                else if limb.bones[0]>=0 && kinds[3]==.Clavicle && other.kind==.Clavicle {limb.bones[3]=at;limb.score[3]=other.score;break}
            }
            if other.kind==.Spine || other.kind==.Pelvis || other.kind==.Neck || other.kind==.Head {break}
            at=parents[at]
        }
        if limb.bones[0]<0 && kinds[3]==.Clavicle && limb.bones[1]>=0 {
            // The upper arm called shoulder: the nearest clavicle-named ancestor of the elbow.
            at=parents[limb.bones[1]]
            for at>=0 {
                other:=body_name(names[at])
                if other.kind==.Clavicle && (other.side==side || other.side==.None) {limb.bones[0]=at;limb.score[0]=other.score*.9;break}
                if other.kind==.Spine || other.kind==.Pelvis || other.kind==.Neck {break}
                at=parents[at]
            }
            limb.bones[3]=-1
        }
        if limb.bones[0]<0 {continue}
        if limb.bones[1]<0 {
            // The ancestor between root and end farthest from the line between them.
            farthest:f32=-1
            at=parents[end]
            for at>=0 && at!=limb.bones[0] {
                a,b,p:=world[limb.bones[0]].position,world[end].position,world[at].position
                axis,ok:=anim_unit(b-a)
                d:=p-a
                if ok {d-=axis*linalg.dot(d,axis)}
                if distance:=linalg.length(d);distance>farthest {farthest=distance;limb.bones[1]=at}
                at=parents[at]
            }
            if limb.bones[1]<0 {continue}
            limb.score[1]=.5
        }
        if kinds[3]==.Toe {
            best_toe:f32
            for bone in end+1..<n {
                other:=body_name(names[bone])
                if other.kind!=.Toe || other.side!=side && other.side!=.None || !body_is_ancestor(parents,end,bone) {continue}
                if other.score>best_toe {best_toe=other.score;limb.bones[3]=bone;limb.score[3]=other.score}
            }
        }
        score:=limb.score[0]*limb.score[1]*limb.score[2]
        if score>best_score {best,best_score=limb,score}
    }
    return
}

// Finds the parts of a body in a skeleton from the names of its bones, their
// hierarchy and where they are at rest. A part keeps its bone when the map
// marks it manual, and so do the axes. world receives the rest pose. False,
// with the map unchanged, for buffers of other sizes or an invalid skeleton;
// parts that are not found stay at -1.
body_detect :: proc "contextless" (parents:[]i32,names:[]string,rest:[]math.Transform,world:[]math.Transform,map_:^Body_Map) -> bool {
    n:=len(parents)
    if n==0 || len(names)!=n || len(rest)!=n || len(world)!=n || n>int(max(i32)) || !pose_world(parents,rest,world) {return false}
    previous:=map_^
    if !body_map_valid(previous,n) {previous=body_map_empty()}
    result:=body_map_empty()

    // Chains with a side in their names first; then those without, sided by where they are.
    legs:[2]Body_Limb
    arms:[2]Body_Limb
    leg_kinds:=[4]Body_Kind{.Hip,.Knee,.Foot,.Toe}
    arm_kinds:=[4]Body_Kind{.Shoulder,.Elbow,.Hand,.Clavicle}
    for side,i in ([2]Body_Side{.Left,.Right}) {
        legs[i]=body_limb(parents,names,world,leg_kinds,side,-1)
        arms[i]=body_limb(parents,names,world,arm_kinds,side,-1)
    }
    unsided_legs,unsided_arms:[2]Body_Limb
    if legs[0].bones[2]<0 && legs[1].bones[2]<0 {
        unsided_legs[0]=body_limb(parents,names,world,leg_kinds,.None,-1)
        unsided_legs[1]=body_limb(parents,names,world,leg_kinds,.None,unsided_legs[0].bones[2])
    }
    if arms[0].bones[2]<0 && arms[1].bones[2]<0 {
        unsided_arms[0]=body_limb(parents,names,world,arm_kinds,.None,-1)
        unsided_arms[1]=body_limb(parents,names,world,arm_kinds,.None,unsided_arms[0].bones[2])
    }

    // The head: the candidate nearest the roots; the neck: its ancestor nearest the roots.
    head,neck:i32=-1,-1
    head_score,neck_score:f32
    for bone in 0..<i32(n) {
        name:=body_name(names[bone])
        if name.kind!=.Head || head>=0 && body_is_ancestor(parents,head,bone) {continue}
        if name.score>head_score {head,head_score=bone,name.score}
    }
    if head>=0 {
        at:=parents[head]
        for at>=0 {
            name:=body_name(names[at])
            if name.kind==.Neck {neck,neck_score=at,name.score}
            at=parents[at]
        }
    }

    // The pelvis: the one named so nearest above where the legs meet, or that meeting point.
    hip_a:=legs[0].bones[0] if legs[0].bones[0]>=0 else unsided_legs[0].bones[0]
    hip_b:=legs[1].bones[0] if legs[1].bones[0]>=0 else unsided_legs[1].bones[0]
    meet:=body_common_ancestor(parents,hip_a,hip_b)
    if meet<0 {meet=parents[hip_a] if hip_a>=0 else parents[hip_b] if hip_b>=0 else -1}
    pelvis:i32=-1
    pelvis_score:f32
    for bone in 0..<i32(n) {
        name:=body_name(names[bone])
        if name.kind!=.Pelvis {continue}
        if meet>=0 && !body_is_ancestor(parents,bone,meet) {continue}
        if neck>=0 && !body_is_ancestor(parents,bone,neck) || head>=0 && !body_is_ancestor(parents,bone,head) {continue}
        if pelvis<0 || body_is_ancestor(parents,pelvis,bone) {pelvis,pelvis_score=bone,name.score}
    }
    if pelvis<0 && meet>=0 {pelvis,pelvis_score=meet,.6}

    // Axes: up from the feet (or the pelvis) to the head; left from the sides.
    position :: proc "contextless" (world:[]math.Transform,bone:i32) -> math.Vec3 {return world[bone].position}
    up:=math.Vec3{0,1,0}
    axes_confidence:f32=.3
    low:math.Vec3;lows:int
    for limb in ([4]Body_Limb{legs[0],legs[1],unsided_legs[0],unsided_legs[1]}) {if limb.bones[2]>=0 {low+=position(world,limb.bones[2]);lows+=1}}
    if lows==0 && pelvis>=0 {low=position(world,pelvis);lows=1}
    if head>=0 && lows>0 {
        if direction,ok:=anim_unit(position(world,head)-low/f32(lows));ok {up=body_snap(direction);axes_confidence=.8}
    }
    left:math.Vec3
    pairs:=0
    for i in 0..<4 {
        for limbs in ([2][2]Body_Limb{legs,arms}) {
            if limbs[0].bones[i]>=0 && limbs[1].bones[i]>=0 {left+=position(world,limbs[0].bones[i])-position(world,limbs[1].bones[i]);pairs+=1}
        }
    }
    left-=up*linalg.dot(left,up)
    forward:math.Vec3
    toes:math.Vec3
    for limb in ([4]Body_Limb{legs[0],legs[1],unsided_legs[0],unsided_legs[1]}) {
        if limb.bones[2]>=0 && limb.bones[3]>=0 {toes+=position(world,limb.bones[3])-position(world,limb.bones[2])}
    }
    toes-=up*linalg.dot(toes,up)
    if direction,ok:=anim_unit(left);ok && pairs>0 {
        forward,_=anim_unit(linalg.cross(direction,up))
        if toes!={} && linalg.dot(toes,forward)<0 {axes_confidence*=.5} else {axes_confidence=min(axes_confidence+.2,1)}
    } else if direction,ok=anim_unit(toes);ok {
        forward=direction
    } else {
        forward=math.FORWARD if abs(up.z)<.9 else math.Vec3{1,0,0}
        axes_confidence=.1
    }
    forward=body_snap(forward)
    forward-=up*linalg.dot(forward,up)
    forward,_=anim_unit(forward)
    side_axis:=linalg.cross(up,forward)

    // Chains without a side in their names take the side they are on.
    origin:=position(world,pelvis) if pelvis>=0 else low/f32(max(lows,1))
    for limbs,which in ([2][2]Body_Limb{unsided_legs,unsided_arms}) {
        for limb in limbs {
            if limb.bones[2]<0 {continue}
            side:=0 if linalg.dot(position(world,limb.bones[2])-origin,side_axis)>=0 else 1
            limb:=limb
            for &score in limb.score {score*=.8}
            if which==0 && legs[side].bones[2]<0 {legs[side]=limb}
            if which==1 && arms[side].bones[2]<0 {arms[side]=limb}
        }
    }

    // A leg that ends at its knee, without foot, still has hip and knee.
    for side,i in ([2]Body_Side{.Left,.Right}) {
        if legs[i].bones[0]>=0 {continue}
        for knee in 0..<i32(n) {
            name:=body_name(names[knee])
            if name.kind!=.Knee || name.side!=side {continue}
            at:=parents[knee]
            for at>=0 {
                other:=body_name(names[at])
                if other.kind==.Hip && (other.side==side || other.side==.None) {legs[i]={bones={at,knee,-1,-1},score={other.score,name.score,0,0},side=side};break}
                if other.kind==.Spine || other.kind==.Pelvis {break}
                at=parents[at]
            }
            if legs[i].bones[0]>=0 {break}
        }
    }

    // Parts and confidences, lowered when a part is not where a body has it.
    height:=body_height_between(world,up,head,legs)
    set :: proc "contextless" (result:^Body_Map,part:Body_Part,bone:i32,score:f32) {
        if bone<0 {return}
        for value in result.bones {if value==bone {return}}
        result.bones[part]=bone;result.confidence[part]=clamp(score,0,1)
    }
    set(&result,.Pelvis,pelvis,pelvis_score)
    set(&result,.Head,head,head_score)
    set(&result,.Neck,neck,neck_score)
    if head>=0 && pelvis>=0 && linalg.dot(position(world,head)-position(world,pelvis),up)<=0 {result.confidence[.Head]*=.6}
    for side in 0..<2 {
        leg,arm:=legs[side],arms[side]
        base_leg:=Body_Part.Hip_L if side==0 else .Hip_R
        base_arm:=Body_Part.Clavicle_L if side==0 else .Clavicle_R
        for k in 0..<4 {set(&result,Body_Part(u8(base_leg)+u8(k)),leg.bones[k],leg.score[k])}
        set(&result,base_arm,arm.bones[3],arm.score[3])
        for k in 0..<3 {set(&result,Body_Part(u8(base_arm)+1+u8(k)),arm.bones[k],arm.score[k])}
        if leg.bones[0]>=0 && leg.bones[2]>=0 {
            hip,knee,foot:=linalg.dot(position(world,leg.bones[0]),up),linalg.dot(position(world,leg.bones[1]),up),linalg.dot(position(world,leg.bones[2]),up)
            if !(knee<hip && foot<knee) {for k in 0..<3 {result.confidence[Body_Part(u8(base_leg)+u8(k))]*=.6}}
        }
        if arm.bones[0]>=0 && pelvis>=0 {
            center:=position(world,pelvis)
            distance :: proc "contextless" (p,center,up:math.Vec3) -> f32 {d:=p-center;return linalg.length(d-up*linalg.dot(d,up))}
            if !(distance(position(world,arm.bones[2]),center,up)>distance(position(world,arm.bones[1]),center,up)) {for k in 1..=3 {result.confidence[Body_Part(u8(base_arm)+u8(k))]*=.7}}
        }
    }
    // Both sides of a pair mirror each other across the middle of the body.
    if pelvis>=0 {
        plane:=Mirror_Plane{side_axis,linalg.dot(side_axis,position(world,pelvis))}
        for part in Body_Part {
            other:=body_part_mirror(part)
            if other==part || result.bones[part]<0 || result.bones[other]<0 {continue}
            if linalg.length(mirror_point(plane,position(world,result.bones[other]))-position(world,result.bones[part]))>.05*height {result.confidence[part]*=.8}
        }
    }

    result.forward,result.up,result.axes_confidence=forward,up,axes_confidence
    for part in previous.manual {
        bone:=previous.bones[part]
        for &value,other in result.bones {if value==bone && other!=part {value=-1;result.confidence[other]=0}}
        result.bones[part],result.confidence[part]=bone,previous.confidence[part]
        result.manual+={part}
    }
    if previous.manual_axes {result.forward,result.up,result.axes_confidence,result.manual_axes=previous.forward,previous.up,previous.axes_confidence,true}
    if !body_map_valid(result,n) {return false}
    map_^=result
    return true
}

// A direction within 15° of an axis becomes the axis.
@(private="file")
body_snap :: proc "contextless" (direction:math.Vec3) -> math.Vec3 {
    for axis in 0..<3 {
        if abs(direction[axis])>.966 {
            snapped:math.Vec3
            snapped[axis]=1 if direction[axis]>0 else -1
            return snapped
        }
    }
    return direction
}
@(private="file")
body_height_between :: proc "contextless" (world:[]math.Transform,up:math.Vec3,head:i32,legs:[2]Body_Limb) -> f32 {
    high,low:=min(f32),max(f32)
    if head>=0 {high=linalg.dot(world[head].position,up)}
    for leg in legs {for k in 2..<4 {if leg.bones[k]>=0 {low=min(low,linalg.dot(world[leg.bones[k]].position,up))}}}
    if high==min(f32) || low==max(f32) || high<=low {return 1}
    return high-low
}
