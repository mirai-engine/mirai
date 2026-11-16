package ai

import "core:math/linalg"
import math "mirai:std/math"

// What an agent knows of the others: observations of fixed capacity, each of
// a subject (a handle the caller gives, an entity), where it was perceived,
// by which senses, when, and how sure the agent still is. Perceiving sets the
// confidence; it falls to zero over the time to forget, and a forgotten
// subject leaves the memory. Plain data: it copies with the agent.

PERCEPTION_CAPACITY :: 16

Sense :: enum u8 {Sight,Hearing}
Senses :: bit_set[Sense;u8]

Observation :: struct {
    subject:u64,
    position:math.Vec3, // where it was last perceived
    senses:Senses,      // by which it was perceived at the last time
    confidence:f32,     // 1 when just perceived, 0 when forgotten
    first,last:u64,     // the ticks it was first and last perceived at
}

Perception_Memory :: struct {
    items:[PERCEPTION_CAPACITY]Observation,
    count:i32,
    replaced:u32, // observations that gave their place to a new subject
}

Memory_Change :: enum u8 {
    None,
    New,     // a subject it did not know
    Again,   // known, perceived again
}

// Perceives a subject as it was at the tick `at`: a report older than what
// is known of it changes nothing, and one of a past tick is forgotten as much
// sooner. Full, a new subject takes the place of the observation it is least
// sure of, when that is less sure than `confidence`.
memory_perceive :: proc "contextless" (m:^Perception_Memory,subject:u64,position:math.Vec3,sense:Sense,confidence:f32,at:u64) -> Memory_Change {
    if !(confidence>0) || !(abs(position.x)<=1e9 && abs(position.y)<=1e9 && abs(position.z)<=1e9) {return .None}
    sure:=min(confidence,1)
    count:=int(clamp(m.count,0,PERCEPTION_CAPACITY))
    for &o in m.items[:count] {
        if o.subject!=subject {continue}
        if at<o.last {return .None}
        if o.last!=at {o.senses={}}
        o.senses+={sense}
        o.position,o.last=position,at
        o.confidence=max(o.confidence,sure)
        return .Again
    }
    slot:=count
    if count>=PERCEPTION_CAPACITY {
        slot=0
        for o,i in m.items {if o.confidence<m.items[slot].confidence {slot=i}}
        if m.items[slot].confidence>=sure {return .None}
        m.replaced+=1
    } else {m.count=i32(count+1)}
    m.items[slot]={subject=subject,position=position,senses={sense},confidence=sure,first=at,last=at}
    return .New
}

// Lowers the confidence of what was not perceived at the tick now, of dt
// seconds, so it reaches zero `forget` seconds after it was, and removes what
// reached it: those go to `forgotten` (as many as fit), and their count is
// returned.
memory_forget :: proc "contextless" (m:^Perception_Memory,now:u64,dt,forget:f32,forgotten:[]u64) -> (count:int) {
    total:=int(clamp(m.count,0,PERCEPTION_CAPACITY))
    for i:=total-1;i>=0;i-=1 {
        o:=&m.items[i]
        if o.last==now {continue}
        o.senses={}
        left:=f32(1)
        if forget>0 {left=1-f32(now-min(o.last,now))*dt/forget} else {left=0}
        o.confidence=min(o.confidence,left)
        if o.confidence>0 {continue}
        if count<len(forgotten) {forgotten[count]=o.subject}
        count+=1
        total-=1
        m.items[i]=m.items[total]
        m.items[total]={}
    }
    m.count=i32(total)
    return
}

memory_find :: proc "contextless" (m:^Perception_Memory,subject:u64) -> ^Observation {
    for &o in m.items[:clamp(m.count,0,PERCEPTION_CAPACITY)] {if o.subject==subject {return &o}}
    return nil
}

// Forgets a subject at once (one that no longer exists); false when it was not remembered.
memory_remove :: proc "contextless" (m:^Perception_Memory,subject:u64) -> bool {
    total:=int(clamp(m.count,0,PERCEPTION_CAPACITY))
    for i in 0..<total {
        if m.items[i].subject!=subject {continue}
        m.items[i]=m.items[total-1]
        m.items[total-1]={}
        m.count=i32(total-1)
        return true
    }
    return false
}

// The observation it is surest of, the nearest to `from` among equals.
memory_best :: proc "contextless" (m:^Perception_Memory,from:math.Vec3) -> (best:Observation,ok:bool) {
    distance:=f32(max(f32))
    for o in m.items[:clamp(m.count,0,PERCEPTION_CAPACITY)] {
        d:=linalg.length2(o.position-from)
        if !ok || o.confidence>best.confidence || o.confidence==best.confidence && d<distance {best,distance,ok=o,d,true}
    }
    return
}

// Whether a point lies in a cone of sight: within range of the eye and less
// than `half_angle` from where it looks (radians; π or more: all around).
sight_in_cone :: proc "contextless" (eye,forward,point:math.Vec3,range,half_angle:f32) -> bool {
    to:=point-eye
    d2:=linalg.length2(to)
    if !(d2<=range*range) {return false}
    if half_angle>=math.PI {return true}
    length:=linalg.length(forward)
    if !(length>0) || d2==0 {return d2==0}
    cosine:=linalg.dot(to,forward)/(length*linalg.sqrt(d2))
    _,limit:=math.sincos_det(half_angle)
    return cosine>=limit
}
