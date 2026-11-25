package behavior

import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import "mirai:engine/volume"
import nav "plugins:navigation/runtime"

Patrol_Mode :: enum u8 {Loop,Back_And_Forth,Once}

@(component,shared,description="Follows the points of the Spline on path. Enable automatic for navigation to walk it, or advance the patrol in game code.")
Patrol :: struct {
    path:core.Entity,
    mode:Patrol_Mode,
    automatic:bool,
    next:u16 `mirai:"transient,readonly"`,
    back:bool `mirai:"transient,readonly"`,
}

// Starts at the waypoint after the nearest part of the path, in the patrol's direction.
patrol_begin :: proc(patrol:^Patrol,spline:^volume.Spline,pose:mm.Transform,position:mm.Vec3) -> bool {
    if patrol==nil || spline==nil || spline.count==0 || spline.count>volume.SPLINE_POINTS {return false}
    next:=0
    if spline.count>1 {
        key,near:=volume.spline_nearest(spline,pose,position)
        if !near {return false}
        next=min(int(key)+(0 if patrol.back else 1),int(spline.count)-1)
    }
    if at:=mm.transform_point(pose,spline.points[next].position);at-at!={} {return false}
    patrol.next=u16(next)
    return true
}

// The patrol's current waypoint in world space.
patrol_waypoint :: proc "contextless" (
    patrol:^Patrol,spline:^volume.Spline,pose:mm.Transform,
) -> (position:mm.Vec3,ok:bool) {
    if patrol==nil || spline==nil || spline.count>volume.SPLINE_POINTS || patrol.next>=spline.count {
        return
    }
    position=mm.transform_point(pose,spline.points[patrol.next].position)
    return position,position-position=={}
}

// Advances after arriving at or skipping a waypoint. False at the end of a Once patrol.
patrol_advance :: proc "contextless" (patrol:^Patrol,spline:^volume.Spline) -> bool {
    if patrol==nil || spline==nil || spline.count>volume.SPLINE_POINTS || patrol.next>=spline.count {
        return false
    }
    count:=int(spline.count)
    next:=int(patrol.next)+(-1 if patrol.back else 1)
    if next<0 || next>=count {
        switch patrol.mode {
        case .Once: return false
        case .Loop: next=(next+count)%count
        case .Back_And_Forth:
            patrol.back=!patrol.back
            next=clamp(int(patrol.next)+(-1 if patrol.back else 1),0,count-1)
        }
    }
    patrol.next=u16(next)
    return true
}

patrol_act :: proc(a:^ai.Act($A)) -> ai.Status {
    w,e:=world_of(a),agent(a)
    p,walking:=agent_path(a)
    if a.phase==.Exit {
        if a.cause==.Aborted && !(walking && p.state==.Crossing) {nav.nav_stop(w.requests,e)}
        return .Success
    }
    if a.phase==.Update && !walking {return .Running}
    far:=far_of(w.fars,e)
    row:=behavior_row(w.patrols,e,far)
    if row<0 {return .Failure}
    walked:=w.patrols.values[row]
    if walked.automatic {return .Failure}
    status:=patrol_walk(&walked,e,a.phase==.Enter,p,w.splines,w.worlds,w.requests,w.problems,far)
    if walked!=w.patrols.values[row] {core.edit_at(w.patrols,row)^=walked}
    return status
}

@(step="fixed",server)
patrols_walk :: proc(
    patrols:^core.Table(Patrol),paths:^core.Table(nav.Nav_Path,.Read),
    splines:^core.Table(volume.Spline,.Read),worlds:^core.Table(core.World_Transform,.Read),
    requests:^nav.Nav_Requests,problems:^core.Problems,time:core.Time,
) {
    if !time.playing {return}
    for row in 0..<core.count(patrols) {
        walked:=patrols.values[row]
        if !walked.automatic {continue}
        e:=core.entity_at(patrols,row)
        p,_:=core.get(paths,e)
        patrol_walk(&walked,e,false,p,splines,worlds,requests,problems,false)
        if walked!=patrols.values[row] {core.edit_at(patrols,row)^=walked}
    }
}

@(private)
patrol_walk :: proc(
    patrol:^Patrol,e:core.Entity,start:bool,p:nav.Nav_Path,
    splines:^core.Table(volume.Spline,$A),worlds:^core.Table(core.World_Transform,$B),
    requests:^nav.Nav_Requests,problems:^core.Problems,far:bool,
) -> ai.Status {
    spline,has_spline:=read_row(splines,patrol.path,far)
    place,placed:=read_row(worlds,patrol.path,far)
    goal,on:=patrol_waypoint(patrol,&spline,place.transform)
    if has_spline && placed && on && !start {
        #partial switch p.state {
        case .Moving,.Waiting,.Crossing:
            if p.state==.Moving && p.goal!=goal {nav.nav_move_to(requests,e,goal)}
            return .Running
        case .Arrived,.Arrived_Partial,.Failed:
            prior:=patrol.next
            if !patrol_advance(patrol,&spline) {return .Success}
            if patrol.next==prior {return .Running}
        }
    }
    if !on || start || p.state==.Idle {
        pose,_:=read_row(worlds,e,far)
        if !patrol_begin(patrol,&spline,place.transform,pose.position) {has_spline=false}
    }
    goal,on=patrol_waypoint(patrol,&spline,place.transform)
    if !has_spline || !placed || !on {
        core.report(problems,e,"behavior.patrol","Its Patrol has no path to walk: name in path an entity with a Spline of finite points, each with a width (or of one point to stand at)")
        return .Failure
    }
    nav.nav_move_to(requests,e,goal)
    return .Running
}
